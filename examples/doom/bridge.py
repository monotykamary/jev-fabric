"""ViZDoom adapter for a jev-fabric Session.

Protocol (JSONL over stdio):
  bridge -> orchestrator: {"tick":n,"request":{...Jev request...}} or {"done":{...}}
  orchestrator -> bridge: one action name per line (turn_left | turn_right | fire)
The orchestrator owns every model decision; this process only renders structured state.
"""
import json
import math
import os
import sys

import vizdoom as vzd

ACTIONS = {
    "turn_left": [1, 0, 0],
    "turn_right": [0, 1, 0],
    "fire": [0, 0, 1],
}
MONSTERS = {"Zombieman", "ShotgunGuy", "ChaingunGuy", "DoomImp", "Demon", "Spectre", "Cacodemon", "LostSoul", "MarineChainsawVzd"}
TICS = int(os.environ.get("DOOM_TICS", "4"))
MAX_DECISIONS = int(os.environ.get("DOOM_DECISIONS", "150"))


def emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def enemies(game, state):
    px = game.get_game_variable(vzd.GameVariable.POSITION_X)
    py = game.get_game_variable(vzd.GameVariable.POSITION_Y)
    facing = game.get_game_variable(vzd.GameVariable.ANGLE)
    visible = {label.object_id for label in state.labels}
    out = []
    for obj in state.objects:
        if obj.name not in MONSTERS:
            continue
        dx, dy = obj.position_x - px, obj.position_y - py
        # Positive bearing = enemy is to the player's left (counter-clockwise).
        bearing = (math.degrees(math.atan2(dy, dx)) - facing + 180) % 360 - 180
        out.append({
            "kind": obj.name,
            "direction": "in_crosshair" if abs(bearing) <= 5 else ("left" if bearing > 0 else "right"),
            "bearing_deg": round(bearing),
            "distance": round(math.hypot(dx, dy)),
            "on_screen": obj.id in visible,
        })
    # Nearest first: the closest monster is the most urgent threat.
    return sorted(out, key=lambda e: e["distance"])


def request(game, state):
    foes = enemies(game, state)
    return {
        "state": {
            "scenario": "Defend the center: you stand still in a circular arena; monsters approach from all sides.",
            "health": int(game.get_game_variable(vzd.GameVariable.HEALTH)),
            "ammo": int(game.get_game_variable(vzd.GameVariable.AMMO2)),
            "kills": int(game.get_game_variable(vzd.GameVariable.KILLCOUNT)),
            "enemies": foes[:12],
            "bearing_convention": "degrees relative to your aim; positive = to your left, negative = to your right; |bearing| <= 5 means the crosshair is on it",
            "turn_per_action_deg": 7 * TICS,
        },
        "questions": {
            "action": {
                "type": "choice",
                "instructions": "Kill the nearest enemy (the first in the list). If its direction is in_crosshair, fire. If it is to the left, turn left. If it is to the right, turn right.",
                "criteria": {
                    "turn_left": "The nearest enemy's direction is left.",
                    "turn_right": "The nearest enemy's direction is right.",
                    "fire": "The nearest enemy's direction is in_crosshair.",
                },
            }
        },
    }


def main():
    game = vzd.DoomGame()
    game.load_config(os.path.join(vzd.scenarios_path, "defend_the_center.cfg"))
    game.set_window_visible(os.environ.get("DOOM_VISIBLE") == "1")
    game.set_labels_buffer_enabled(True)
    game.set_objects_info_enabled(True)
    game.set_available_game_variables([
        vzd.GameVariable.AMMO2, vzd.GameVariable.HEALTH, vzd.GameVariable.KILLCOUNT,
        vzd.GameVariable.POSITION_X, vzd.GameVariable.POSITION_Y, vzd.GameVariable.ANGLE,
    ])
    game.set_seed(int(os.environ.get("DOOM_SEED", "7")))
    game.init()
    game.new_episode()
    decisions, counts = 0, {name: 0 for name in ACTIONS}
    while not game.is_episode_finished() and decisions < MAX_DECISIONS:
        state = game.get_state()
        emit({"tick": decisions, "request": request(game, state)})
        line = sys.stdin.readline()
        if not line:
            break
        action = line.strip()
        if action not in ACTIONS:
            emit({"error": f"unknown action {action!r}"})
            break
        counts[action] += 1
        game.make_action(ACTIONS[action], TICS)
        decisions += 1
    emit({"done": {
        "decisions": decisions,
        "kills": int(game.get_game_variable(vzd.GameVariable.KILLCOUNT)),
        "health": int(game.get_game_variable(vzd.GameVariable.HEALTH)),
        "ammo": int(game.get_game_variable(vzd.GameVariable.AMMO2)),
        "died": game.is_player_dead(),
        "reward": game.get_total_reward(),
        "actions": counts,
    }})
    game.close()


if __name__ == "__main__":
    main()
