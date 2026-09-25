# Doom bridge

`bridge.py` runs ViZDoom's `defend_the_center` scenario and speaks one JSON line
per decision over stdio: it prints a Jev request describing the structured game
state (health, ammo, kills, enemies with bearing and distance) and reads back one
action (`turn_left`, `turn_right` or `fire`). All model calls happen in
`examples/native/doom.bend`; the bridge never talks to the network.

```bash
uv venv .venv-doom && uv pip install -p .venv-doom/bin/python vizdoom
export JEV_PROVIDER=typesafe TYPESAFE_API_KEY=...   # or JEV_CREDENTIAL_COMMAND
DOOM_PYTHON=.venv-doom/bin/python DOOM_DECISIONS=60 \
  jev-fabric -- run examples/native/doom.bend
```

`DOOM_VISIBLE=1` opens the game window, `DOOM_TICS` sets game tics per decision
(default 4) and `DOOM_DECISIONS` caps the episode (default 150).
