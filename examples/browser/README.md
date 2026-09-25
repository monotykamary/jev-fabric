# Browser bridge

`bridge.ts` drives one Chrome tab through
[browser-harness-js](https://github.com/monotykamary/browser-harness-js)'s guarded
`InteractionController` with trusted input (SDK 0.15.0 or later). Each step it
observes the page's candidates and prints one Jev request, in the style of
[jev-ultrafast](https://github.com/browser-use/jev-ultrafast):

- `operation`: click, type, press_enter, scroll_down/up, done or blocked (only what the page allows)
- `click_target` / `type_target` / `scroll_target`: speculative targets among observed candidates,
  each described with its role, name, state and named context (for example `in dialog: Departure`)
- `type_text`: which word span of the goal to type, so no text model is needed

All heads are answered in one round trip; `examples/native/browse.bend` makes the
call and sends the validated answers back. Model output only ever selects an
observed candidate or a span copied from the goal: never selectors, coordinates or
scripts. The guarded layer rechecks origin, identity and occlusion before acting.

```bash
git clone https://github.com/monotykamary/browser-harness-js ../browser-harness-js
export JEV_PROVIDER=typesafe TYPESAFE_API_KEY=...     # or JEV_CREDENTIAL_COMMAND
jev-fabric -- run examples/native/browse.bend          # Wikipedia: Gödel's incompleteness theorems

BROWSE_URL='https://www.google.com/travel/flights?hl=en' \
BROWSE_GOAL='Find one-way flights from Zurich to London on October 20, 2026, for one adult in economy.' \
BROWSE_STEPS=25 jev-fabric -- run examples/native/browse.bend
```

| Variable | Default |
| --- | --- |
| `BROWSE_URL` / `BROWSE_GOAL` | Wikipedia main page / open the Gödel article |
| `BROWSE_ORIGINS` | extra allowed origins, comma separated (the start URL's origin is always allowed) |
| `BROWSE_STEPS` | 15 decisions |
| `BROWSE_VISIBLE=1` | show the Chrome window |
| `BROWSE_TRACE` | append every request and answer as JSONL |
| `BROWSER_HARNESS_SDK` | `../browser-harness-js/skills/cdp/sdk` |
| `CHROME_PATH`, `BROWSE_NODE` | Chrome and Node (24+) executables |

The bridge launches its own headless Chrome with a throwaway profile. `done` is
the model's judgment, not verification: check the final URL and page yourself.
