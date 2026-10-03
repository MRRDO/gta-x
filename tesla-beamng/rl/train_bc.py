"""Behaviour cloning of Quentin's pedal use (numpy only, runs on any CPU in about a minute).

    python rl/train_bc.py [--logs DIR] [--out policy.json] [--epochs 200]

Reads the human-driving rows from the relay's log (features.human_rows), fits a small MLP
(7 -> 16 -> 16 -> 1, tanh) with Adam, and writes policy.json in the format policy.lua loads:
    {"names": [...], "scale": [...], "layers": [{"w": [[...]], "b": [...], "act": "tanh"}, ...]}
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import features  # noqa: E402


def init(sizes, rng):
    layers = []
    for a, b in zip(sizes[:-1], sizes[1:]):
        layers.append({"w": rng.normal(0, 1 / np.sqrt(a), (b, a)), "b": np.zeros(b)})
    return layers


def forward(layers, X):
    acts = [X]
    h = X
    for i, L in enumerate(layers):
        z = h @ L["w"].T + L["b"]
        h = np.tanh(z)  # every layer tanh: the output is a -1..1 pedal command
        acts.append(h)
    return acts


def train(X, Y, epochs=200, lr=0.01, seed=1):
    rng = np.random.default_rng(seed)
    layers = init([X.shape[1], 16, 16, 1], rng)
    m = [{k: np.zeros_like(v) for k, v in L.items()} for L in layers]
    v2 = [{k: np.zeros_like(v) for k, v in L.items()} for L in layers]
    n = len(X)
    t = 0
    for ep in range(epochs):
        idx = rng.permutation(n)
        for s in range(0, n, 256):
            b = idx[s : s + 256]
            acts = forward(layers, X[b])
            err = (acts[-1] - Y[b][:, None])
            g = err * (1 - acts[-1] ** 2) * (2.0 / len(b))
            t += 1
            for i in reversed(range(len(layers))):
                gw = g.T @ acts[i]
                gb = g.sum(0)
                if i > 0:
                    g = (g @ layers[i]["w"]) * (1 - acts[i] ** 2)
                for k, gr in (("w", gw), ("b", gb)):
                    m[i][k] = 0.9 * m[i][k] + 0.1 * gr
                    v2[i][k] = 0.999 * v2[i][k] + 0.001 * gr * gr
                    layers[i][k] -= lr * (m[i][k] / (1 - 0.9 ** t)) / (np.sqrt(v2[i][k] / (1 - 0.999 ** t)) + 1e-8)
    return layers


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--logs")
    ap.add_argument("--out", default="policy.json")
    ap.add_argument("--epochs", type=int, default=200)
    a = ap.parse_args()
    X, Y = features.human_rows(features.log_files(a.logs))
    if len(X) < 2000:
        print(f"only {len(X)} human-driving rows: drive a few more minutes with --record on (need about 2000, ~3 minutes)")
        return 1
    X, Y = np.array(X), np.array(Y)
    layers = train(X, Y, a.epochs)
    pred = forward(layers, X)[-1][:, 0]
    print(f"{len(X)} rows, mean abs error {np.abs(pred - Y).mean():.3f} (baseline {np.abs(Y - Y.mean()).mean():.3f})")
    out = {"names": features.OBS_NAMES, "scale": features.OBS_SCALE,
           "layers": [{"w": L["w"].tolist(), "b": L["b"].tolist(), "act": "tanh"} for L in layers]}
    with open(a.out, "w") as f:
        json.dump(out, f)
    print("wrote", a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
