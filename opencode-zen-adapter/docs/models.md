# Models — ask, don't read

**There is no model table in this repository. On purpose.**

The free-model roster changes without notice. This project previously kept a hardcoded table of
supported models, and it drifted immediately:

| What the table said | What the gateway actually did |
|---|---|
| 10 models | served **11** — `big-pickle` wasn't listed at all |
| `nemotron-3.5-lightning-free` = "SLOW ~60s" | responded in **~1.3 s** |
| `8/10 models work` | live probe showed **9/11** |

Three different stale numbers lived in the same file at different times. So the rule became:

> **The model list is dynamic. Never copy it into a doc, `.json`, or table — it drifts.**

The single source of truth is `scripts/list-models.ps1`.

## Usage

```bash
# via the one launcher (menu items [4] list / [5] probe)
LAUNCHER.bat models
LAUNCHER.bat probe

# what is exposed right now?
powershell -File scripts/list-models.ps1

# which of them actually respond?
powershell -File scripts/list-models.ps1 -Probe

# slow models need a longer budget; retry transient failures
powershell -File scripts/list-models.ps1 -Probe -Timeout 150 -Retries 2

# machine-readable
powershell -File scripts/list-models.ps1 -Json

# show the 9router route for each model
powershell -File scripts/list-models.ps1 -Prefix opec
```

### Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-Probe` | off | Send a real completion to every model |
| `-Json` | off | Emit JSON instead of a table |
| `-Timeout` | `45` | Per-request timeout in seconds |
| `-Retries` | `2` | Extra attempts for *transient* failures only |
| `-Prefix` | `""` | Prefix each route (e.g. `opec`) |
| `-ConfigPath` | auto | Override which config to read |

### Nothing in it is hardcoded

The script reads `listen` and `server_keys` from `bin/config/config-oc2api.json`, then calls
`GET /v1/models` at runtime. Change the port or the key in config and the script follows — there is
no host, key, or model name baked into the script.

## Output

Plain listing:

```
Gateway : http://127.0.0.1:20132   (up=ok, upstream=80, exposed=11)
Config  : <repo>\bin\config\config-oc2api.json
Refresh : 2026-09-24T08:44:23.8008346Z  stale=False

  big-pickle
  deepseek-v4-flash-free
  ...

RESULT: 11 models exposed. Add -Probe to test each one.
```

With `-Probe`:

```
MODEL                                  STATUS     MS       NOTE
----------------------------------------------------------------------------------------------------
big-pickle                             ok         983      OK.
deepseek-v4-flash-free                 400        444      ... Model is unavailable.
jev-1.13-free                          400        469      Bad Request
ling-3.0-flash-fin-free                ok         1322     OK
...

RESULT: 9 OK / 0 empty / 2 failed   (of 11 exposed)
  400        x2   deepseek-v4-flash-free, jev-1.13-free
```

`-Json` emits `gateway`, `base`, `config`, `refreshed`, `stale`, `upstream`, `exposed`, `probed`,
`ok`, `empty`, `failed`, and a `models[]` array of `{model, route, status, ms, note}`.

## `-Probe` semantics — why a naive probe lies

| Status | Meaning | Retried? |
|---|---|---|
| `ok` | Real completion returned visible text | — |
| `4xx` | Deterministic rejection → genuinely dead | **No** |
| `5xx` | Transient upstream blip | Yes |
| `timeout` | Slow / cold start | Yes |
| `empty` | HTTP 200 but no visible content | Reported, not retried |
| `untested` | Listed but `-Probe` wasn't used | — |

The retry split is the important part: **a single 502 is not proof that a model is dead.**
`nemotron-3-ultra-free` returned `502 unsupported upstream response` on one attempt and answered
normally on the next. A one-shot probe would have written it off permanently.

4xx is never retried because it is a client/upstream contract failure — repeating it just burns time.

## The four gotchas (each one produced a false "dead" verdict)

1. **`max_tokens` must be ≥ 16.** The provider rejects lower with
   `400 — max_output_tokens The number must be >= 16`. A probe using `max_tokens: 8` manufactures
   its own failures and then blames the model.

2. **Reasoning models burn ~190 tokens before emitting visible text.** With a tight budget you get
   HTTP `200` with an **empty** `content` field — which looks like a broken model but is just
   arithmetic. The probe uses `max_tokens: 512` to leave room.

3. **Read error bodies from `Position = 0`.** In PowerShell, `GetResponseStream()` hands you a
   stream already at the end. Reading it without rewinding yields an empty body, so you lose the
   actual upstream error message and are left guessing. (This one hid the real cause of gotcha #1.)

4. **Distinguish transient from persistent.** One `502` ≠ dead. Use `-Retries`, and trust `4xx`
   over `5xx` when they disagree.

## Historical snapshot

> **Informational only — not a supported-model list. Re-run `-Probe` for current truth.**
>
> As of 2026-09-24: 11 exposed, 9 OK, 2 persistent `400` — `deepseek-v4-flash-free`
> ("Model is unavailable") and `jev-1.13-free` ("Bad Request"). Both fail on OpenCode's upstream
> side and recover on their own with zero changes here.

Next: [`9router.md`](9router.md) for putting these models behind the `opec/` prefix.
