# Jev requests

A request is one JSON object with a `state` and 1..128 named `questions`:

```json
{
  "state": "Build log: 12 tests passed, 0 failed, coverage 81%.",
  "questions": {
    "healthy": {
      "type": "noul",
      "instructions": "Do the tests in this observation appear healthy?"
    },
    "next": {
      "type": "choice",
      "instructions": "What should happen next?",
      "criteria": {
        "verify": "Verify the result independently.",
        "repair": "Investigate a failing test.",
        "ship": null
      }
    },
    "confidence": {
      "type": "score",
      "instructions": "Confidence that the observation says tests passed.",
      "criteria": ["Low", "Medium", "High"]
    }
  }
}
```

- `state` and every description may be a string, an array or an object. Put the
  structured observation there (JSON objects work well), not a prose essay.
- `choice` criteria: an object with 1..255 keys (1..256 characters each); a value
  is a description or `null`.
- `score` criteria: an ordered array of 2..10 level descriptions.
- `noul` criteria are optional: `{"true": ..., "false": ...}`.
- Optional top-level `model` (≤128 characters) overrides `JEV_MODEL`.
- Unknown fields, duplicate keys, malformed UTF-8 and requests over 1 MiB are
  rejected before any credential lookup or network access. `validate` runs the
  same checks offline.

## Answers

```json
{
  "model": "jev-1.13.0",
  "answers": {
    "healthy": {"type": "noul", "noul": 0.95},
    "next": {"type": "choice", "choice": "verify", "confidence": 1.0,
             "probabilities": {"verify": 1.0, "repair": 0.0, "ship": 0.0}},
    "confidence": {"type": "score", "score": 2.0, "confidence": 0.9,
                   "probabilities": {"0": 0.0, "1": 0.1, "2": 0.9},
                   "legend": {"0": "Low", "1": "Medium", "2": "High"}}
  },
  "usage": {"input_tokens": 380, "output_tokens": 61}
}
```

Every answer is validated completely: a `choice` is always one of your keys,
probabilities sum to 1 (±0.02), scores stay in range. Unrecognized response fields
are stripped. Map answers to branches you wrote; never execute answer text.

## Budgets

`jev <request.json> [max-tokens]` makes exactly one evaluation (default 100000
reported tokens). In Bend, `Jev.connect(max_evaluations, max_tokens)` bounds a
client: once calls or reported tokens are exhausted, later evaluations fail without
network access. Reported usage is accounted after each call, so the final request
may overshoot the token limit; always set a call limit too.

## Patterns

**Gate, don't narrate.** Run deterministic checks first; ask Jev one crisp question
about the ambiguous remainder ("is this failure flaky or real?") and branch on the
typed answer.

**More than 255 options.** Split the options into chunks of ≤255, ask one `choice`
per chunk, then ask a final `choice` among the chunk winners. A Wikipedia-race bot
choosing among 2,000 links uses this tournament: 9 chunk calls plus one final call.

**Game-speed loops.** Keep one process and one client alive (a Bend program or a
persistent `Session`), render the game state as structured JSON in `state`, and ask
one `choice` per tick with the legal actions as criteria. Pooled HTTPS keeps
latency to the service's warm round trip instead of a TLS handshake per call.

**Confidence is information, not authority.** A 0.99 `choice` still only selects
among actions you already permitted.
