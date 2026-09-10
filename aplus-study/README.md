# Bench Test — CompTIA A+ study tracker

A single-file study app for the **CompTIA A+ V15 exams** (220-1201 Core 1 and
220-1202 Core 2, the objectives that replaced 1101/1102 in September 2025).

Published as a private Claude Artifact so progress syncs across devices with no
login screen — the page is bound to the owner's Claude account.

## What's in it

| Tab | What it does |
| --- | --- |
| **Status** | Readiness dial (accuracy × coverage, weighted by the real exam domain percentages), rank label, lifetime right/wrong ratio, day streak, daily goal, exam countdown, per-domain readout, and weak-spot callouts that link straight into a drill |
| **Drill** | Smart mix (weights unseen questions, previous misses, and weak domains), redo-my-misses, per-domain sets, and 8 performance-based drag-and-drop sims |
| **Cards** | 60 flashcards on a Leitner spaced-repetition schedule (0 / 1 / 3 / 7 / 21 days) plus a 60-second ports-and-acronyms speed round |
| **Exam** | Timed simulation kept separate from daily practice — 30/45/90 questions, pausable mid-exam with the clock frozen so a session can be split across sittings, question navigator, flagging, estimated 100–900 scaled score against the real 675/700 cut scores, and a per-domain post-mortem |
| **Progress** | 12-week study heatmap, and semesters you open and close on demand, each with its own accuracy, W/L ratio, per-domain breakdown, and targeted recommendations |

## Content

210 questions across all 9 domains, distributed roughly by official exam
weighting. Every question carries an explanation, a concrete worked example, and
a topic-scoped video search link.

| Core | Domain | Questions | Exam weight |
| --- | --- | ---: | ---: |
| 1 | 1.0 Mobile Devices | 16 | 13% |
| 1 | 2.0 Networking | 26 | 23% |
| 1 | 3.0 Hardware | 32 | 25% |
| 1 | 4.0 Virtualization & Cloud | 12 | 11% |
| 1 | 5.0 Hardware & Network Troubleshooting | 30 | 28% |
| 2 | 1.0 Operating Systems | 28 | 28% |
| 2 | 2.0 Security | 26 | 28% |
| 2 | 3.0 Software Troubleshooting | 20 | 23% |
| 2 | 4.0 Operational Procedures | 20 | 21% |

## Files

- `artifact-source.html` — the source published as an Artifact. No
  `<!doctype>`/`<html>`/`<head>`/`<body>` wrapper; the Artifact host supplies it.
- `index.html` — the same content wrapped in a full HTML document so it can be
  opened from disk or served statically.

## Storage

State lives in one document at `state/main` in the artifact's database, mirrored
to `localStorage` so the app works offline and renders instantly on load. On
boot the two are merged field-wise rather than last-writer-wins, so studying on
a phone and then a laptop does not discard either side:

- per-question mastery keeps whichever record has more attempts
- per-day counts keep the higher value
- semesters union by id
- the longer streak and higher speed-round best win

Opened as a plain file with no Artifact host, `claude.use("db")` resolves null
and the app runs on `localStorage` alone.

## Design notes

Type is IBM Plex (Sans, Sans Condensed, Mono) — the PC lineage the A+ actually
certifies you on. Dark-first graphite ground with a gold contact-pad accent;
light theme, `prefers-color-scheme`, and explicit theme stamps are all handled
through the same token set.
