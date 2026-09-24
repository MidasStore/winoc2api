# Troubleshooting

Work top to bottom — each section assumes the one above it passed.

## 1. Process

| Symptom | Cause | Fix |
|---|---|---|
| Window flashes and closes instantly | Ran the `.exe` directly, or wrong working directory → config not found → exit 1 | Use `LAUNCHER.bat start` (standalone: `powershell -File scripts\adapter.ps1 start`), or from `<repo-root>` run `bin\opencode2api.exe -config bin\config\config-oc2api.json` |
| `read config.json: ... cannot find the file specified` | Same as above — it looks for `config.json`, yours is `bin\config\config-oc2api.json` | Pass `-config bin\config\config-oc2api.json` explicitly |
| Launcher prints `[FAIL] exe not found` | `bin/opencode2api.exe` is gitignored and absent | Drop the gateway binary into `bin\` |
| Launcher prints `[FAIL] config not found` | Fresh clone — no config created yet | Copy `bin\config\config.example.json` → `bin\config\config-oc2api.json` |
| `address already in use` | A previous instance still holds `:20132` | `Stop-Process -Name opencode2api -Force`, wait ~2 s, relaunch |
| Launcher prints `[OK] already running (pid N)` | Expected — it is already up | Nothing to do |
| Launcher prints `[FAIL]` + log tail | Startup error; the launcher dumps `logs\winoc2api.err.log` | Fix what the log names |

```powershell
# is it running, and from where?
Get-Process opencode2api -ErrorAction SilentlyContinue | Select-Object Id,Path
```

## 2. Connectivity

| Symptom | Cause | Fix |
|---|---|---|
| `ECONNREFUSED` / `502` | Nothing listening on `:20132` — gateway not started (typical after reboot) | Run `LAUNCHER.bat start` |
| `connection refused` from 9router only | Gateway up but 9router points at the wrong base URL | Node `baseUrl` must be `http://127.0.0.1:20132/v1` |
| `503` from 9router | Gateway down, **or** 9router backoff after repeated failures | Check `:20132/healthz`; wait for backoff to reset |
| Everything slow / unreachable | Egress problem | Check `healthz.proxies.healthy` vs `total` |

> The gateway is **not** a Windows service — after a reboot it is simply gone until you start it.
> That single fact explains most `502 ECONNREFUSED` reports.

## 3. Authentication

| Symptom | Cause | Fix |
|---|---|---|
| `401 invalid local API key` | Caller presented the wrong `x-api-key` | Use `server_keys[0]` from `bin\config\config-oc2api.json` |
| `401` **only through 9router** | 9router still holds an old key — its `PUT` ignores `apiKey` | DELETE the connection, POST a new one with the current key |
| `403 FreeTierError` | Traffic isn't passing through `:20132`, so `x-opencode-session` is missing | Route via this gateway (`:20132`), not `:20131` and not OpenCode directly |

## 4. Requests

| Symptom | Cause | Fix |
|---|---|---|
| `400 unknown model` | Sent `opec/...` straight to `:20132` | Strip the prefix — `opec/` is 9router-only |
| `400 — max_output_tokens The number must be >= 16` | `max_tokens` too low | Use ≥ 16; **512** for reasoning models |
| `200` but `content` is empty | Reasoning tokens consumed the budget (~190 burnt before visible text) | Raise `max_tokens` |
| `400 "Model is unavailable"` | Dead on OpenCode's upstream side | `scripts\list-models.ps1 -Probe` to confirm; it recovers on its own |
| `400 "Bad Request"` | Same — upstream rejection | As above |
| `500 Internal error` | Transient upstream crash | Retry; let 9router apply model cooldown |
| One-off `502 unsupported upstream response` | Transient blip | Retry — **do not** mark the model dead from a single 502 |
| Streaming response stalls | Upstream hiccup | Retry; gateway supports SSE passthrough normally |

## 5. Model-list confusion

| Symptom | Cause | Fix |
|---|---|---|
| A model listed in some doc doesn't exist | That doc is stale | Trust `scripts\list-models.ps1`, never a table |
| `-Probe` says a model is dead but it works | Probe bug or transient failure | Use `-Retries`; check `max_tokens` ≥ 16; 4xx is real, 5xx may not be |
| Counts differ from documentation | Docs deliberately carry no counts | Re-run `-Probe` for current truth |
| `healthz.models.stale` is `true` | Refresh missed | Wait for the next `models.refresh_seconds` cycle |

## 6. Interpreting `-Probe` correctly

| Status | Trust it? | Action |
|---|---|---|
| `ok` | Yes | Use it |
| `4xx` | Yes — deterministic | Model is genuinely rejected upstream |
| `5xx` | Not from one attempt | Re-run with `-Retries` |
| `timeout` | Not from one attempt | Raise `-Timeout` (some models need 100 s+), re-run |
| `empty` | Yes — it's a budget issue | Raise `max_tokens`, re-run |
| `untested` | N/A | You didn't pass `-Probe` |

## Reading the logs

```powershell
Get-Content logs\winoc2api.err.log -Tail 50     # errors first
Get-Content logs\winoc2api.out.log -Tail 100    # then request flow
```

If both are empty and health returns 200, the gateway is fine — look downstream at 9router.

## Collecting a report

Include:

1. `curl http://127.0.0.1:20132/healthz` output
2. `powershell -File scripts\list-models.ps1 -Probe -Timeout 150 -Retries 2` output
3. The exact request (model id, `max_tokens`, which port you called)
4. Last ~50 lines of `logs\winoc2api.err.log`

Steps 1–2 separate *gateway down* / *model dead* / *your request wrong*, which covers nearly every
report.

See also: [`quickstart.md`](quickstart.md) · [`models.md`](models.md) ·
[`9router.md`](9router.md) · [`operations.md`](operations.md)
