# tesla-beamng

A BeamNG.drive mod plus a Node relay that lets the Tesla UI ATV app (on an
iPad) show and drive a car in BeamNG. It includes our own autopilot, which
drives through the player's inputs so the in-car steering wheel turns.

Setup, testing and how it works: [docs/BEAMNG_BRIDGE.md](docs/BEAMNG_BRIDGE.md).

```
npm install
npm run mod      # -> beamng/dist/tesla_bridge.zip, copy into BeamNG's mods/ folder
npm run bridge   # relay + test page on http://localhost:8765
```

This folder is laid out to drop into the `tesla-ui-atv` repo as-is: its
`beamng/`, `bridge/` and `docs/` folders plus the npm scripts.
