# winoc2api

Free **OpenCode Zen** models behind a local OpenAI-compatible gateway, packaged so the whole thing
lives in one folder — binary, config, launcher, and a live model lister included.

Built on [`opencode2api`](https://github.com/MidasStore/opencode2api) v1.3.5, a Go gateway that
bridges the OpenCode Zen upstream using the native SDK protocol (session-affinity headers included),
so free-tier models work without falling back to anything else.

> **Gateway reference:** [`MidasStore/opencode2api`](https://github.com/MidasStore/opencode2api) is
> our fork of the upstream project
> [`jasonxu114514/opencode2api`](https://github.com/jasonxu114514/opencode2api) (418★). Questions
> about protocols, config fields, routing, or upstream behaviour should be answered from that README
> first. **This README only documents what *this skill* adds on top**: the Windows launcher, the
> live model lister, the local wiring, and how to drive the three inference protocols against the
> running gateway.

```
Client (Hermes) ──► 9router :20128 ──► opencode2api :20132 ──► opencode.ai/zen ──► upstream
                    prefix "opec"       this gateway            Bearer public
```

## Capabilities

Everything below was verified against the gateway running on this machine, not copied from upstream
docs:

- **Three inference protocols** on one listener — Chat Completions, Responses, and Anthropic
  Messages — each returning its own native response shape.
- **JSON and SSE** responses; streaming returns `text/event-stream; charset=utf-8` and terminates
  with `data: [DONE]`.
- **Two auth headers, one key** — `x-api-key: <YOUR_SERVER_KEY>` and
  `Authorization: Bearer <YOUR_SERVER_KEY>` are interchangeable.
- **Anonymous free-tier access** — `anonymous: true` with empty `zen_keys`/`go_keys` drives upstream
  with the OpenCode `public` credential. `/healthz` reports `keys.anonymous: true, keys.total: 0`.
- **Dynamic model discovery** with disk caches refreshed every `models.refresh_seconds`.
- **Loopback only** — binds `127.0.0.1:20132`, so the local key is defence-in-depth, not the only
  barrier.
- **Reasoning passthrough** — thinking blocks survive conversion in both directions
  (`content[].type: "thinking"` on Anthropic, `output[].type: "reasoning"` on Responses).
- **No Node.js, no database, no WebUI** — this config ships `webui.enabled: false`; upstream's
  management port is deliberately off.

## Quick start

```bash
# 0. FIRST RUN ONLY - create your config from the tracked template,
#    then put your own value in server_keys
cp opencode-zen-adapter/bin/config/config.example.json \
   opencode-zen-adapter/bin/config/config-oc2api.json

# 1. start the gateway (resolves every path relative to itself - any CWD works)
powershell -NoProfile -ExecutionPolicy Bypass -File opencode-zen-adapter\scripts\adapter.ps1 start
#    or drive it through the single launcher in this folder:
#        LAUNCHER.bat start      (or just double-click LAUNCHER.bat for the status panel)

# 2. is it alive?
curl.exe http://127.0.0.1:20132/healthz

# 3. what models are there? (always ask at runtime - never from a doc)
powershell -File opencode-zen-adapter/scripts/list-models.ps1 -Probe -Timeout 150 -Retries 2

# 4. first completion (use your own server_keys[0])
curl.exe http://127.0.0.1:20132/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-api-key: <YOUR_SERVER_KEY>" \
  -d '{"model":"mimo-v2.6-flash-free","messages":[{"role":"user","content":"hi"}],"max_tokens":100}'
```

> **Use `curl.exe`, not `curl`.** PowerShell 5.1 aliases `curl` to `Invoke-WebRequest`, so the line
> above fails with `Cannot bind parameter 'Headers'` if you drop the `.exe`. `curl.exe` ships with
> Windows 10+ (`curl 8.9.1` here) and works in both `cmd` and PowerShell.

> **`opencode-zen-adapter/bin/opencode2api.exe` is gitignored** (it is an 8 MB binary). Drop the
> gateway binary into `opencode-zen-adapter\bin\` before the first start — the launcher fails loudly
> with `exe not found` if it is missing. Grab it from
> [upstream Releases](https://github.com/jasonxu114514/opencode2api/releases)
> (`opencode2api_v1.3.5_windows_amd64.zip`).

Full walkthrough → [`opencode-zen-adapter/docs/quickstart.md`](opencode-zen-adapter/docs/quickstart.md)

## API usage

`server_keys` authenticate clients **to this gateway**. They are separate from any upstream
credential and are never sent upstream as-is.

Send `x-api-key: <YOUR_SERVER_KEY>` or `Authorization: Bearer <YOUR_SERVER_KEY>` on every `/v1/*`
route. Health checks require no authentication.

| Method | Path | Auth | Verified behaviour |
| --- | --- | --- | --- |
| `GET` | `/healthz` | none | `200` + readiness/resource JSON |
| `GET` | `/v1/models` | key required | `200` + `{"data":[...]}`; `401` without or with a wrong key |
| `POST` | `/v1/chat/completions` | key required | OpenAI shape: `choices[0].message.content` |
| `POST` | `/v1/responses` | key required | Responses shape: `object: "response"`, `output[]` |
| `POST` | `/v1/messages` | key required | Anthropic shape: `type: "message"`, `content[]` |

Missing or wrong key returns `401` with:

```json
{"error":{"code":null,"message":"invalid local API key","param":null,"type":"authentication_error"}}
```

Discover an available model first, then substitute `MODEL_ID` from that response:

```bash
curl.exe http://127.0.0.1:20132/v1/models -H "x-api-key: <YOUR_SERVER_KEY>"
```

The model id in the examples below is an **example only** — always confirm against a live query.

**Chat Completions**

```bash
curl.exe http://127.0.0.1:20132/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-api-key: <YOUR_SERVER_KEY>" \
  -d '{"model":"MODEL_ID","messages":[{"role":"user","content":"Hello"}],"max_tokens":512}'
```

**Responses**

```bash
curl.exe http://127.0.0.1:20132/v1/responses \
  -H "Content-Type: application/json" \
  -H "x-api-key: <YOUR_SERVER_KEY>" \
  -d '{"model":"MODEL_ID","input":"Hello"}'
```

**Anthropic Messages** (this is the protocol that carries thinking blocks)

```bash
curl.exe http://127.0.0.1:20132/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: <YOUR_SERVER_KEY>" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"MODEL_ID","max_tokens":512,"messages":[{"role":"user","content":"Hello"}]}'
```

For streaming, add `"stream": true` and use `curl.exe -N`; the gateway answers with
`text/event-stream` and ends the stream with `data: [DONE]`.

### Compatibility boundaries

- **No embeddings.** `POST /v1/embeddings` returns `404 page not found` — the route does not exist
  on this build. Same for file uploads, image generation, and Responses retrieval/cancellation
  (per upstream).
- **Cross-protocol requests are lossy.** Not every option has an equivalent when a request crosses
  from one protocol to another; unsupported content or tool types may be rejected.
- **`max_tokens` must be ≥ 16.** The provider rejects lower values with
  `max_output_tokens The number must be >= 16`.
- **Reasoning models burn budget before text.** A small `max_tokens` yields HTTP `200` with empty
  `content` — that is a budget problem, not a dead model. Use `512` when probing.
- **The `opec/` prefix is 9router-only.** Sending `opec/MODEL_ID` straight to `:20132` returns
  `400` (`the model uses an upstream protocol that opencode2api does not expose`). Send the bare id.

Errors surface as `upstream_error` / `invalid_request` types rather than bare 5xx, so read the
`error.message` body — the HTTP status alone does not tell you which hop failed.

## Why the model list is never written down here

The free-model roster changes without notice. An earlier revision of this project kept a hardcoded
table of supported models; it drifted within hours — it listed 10 models while the gateway served 11,
and it labelled a model "SLOW ~60s" when that model responded in ~1s.

So this repo has **one source of truth**: `opencode-zen-adapter/scripts/list-models.ps1`, which reads
the live model list from the gateway and optionally sends a real completion to each entry. There is
deliberately no static "N/M models work" number anywhere in the docs.

Details and the list of probing gotchas → [`opencode-zen-adapter/docs/models.md`](opencode-zen-adapter/docs/models.md)

## Tools in this skill

Three files do all the work. Every path is resolved from the script's own location (`%~dp0` /
`$PSScriptRoot`), so all of them are CWD-independent.

### `LAUNCHER.bat` — the one launcher

Double-click for the interactive status panel and menu, or pass a command:

```bash
LAUNCHER.bat start | stop | restart | status | models | probe | logs
LAUNCHER.bat open-config | open-docs
```

| Command | Does |
| --- | --- |
| `start` | start, wait until healthy (idempotent — already running is a no-op) |
| `stop` | force stop the gateway process |
| `restart` | stop, then start |
| `status` | print the status panel and exit |
| `models` | live model list from `GET /v1/models` |
| `probe` | live list **plus** a real completion to every exposed model |
| `logs` | tail the runtime logs |
| `open-config` / `open-docs` | open `bin\config` / `docs` in Explorer |

There is exactly **one** `.bat` in the whole tree.

### `opencode-zen-adapter/scripts/adapter.ps1` — the engine

The launcher is a 32-line trampoline over this script; drive it directly if you prefer:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File opencode-zen-adapter\scripts\adapter.ps1 start
```

It verifies the exe and config exist (naming the exact missing path), creates `logs\` if absent,
starts the exe with an absolute `-config` and `WorkingDirectory = bin\`, redirects stdout/stderr to
`logs\winoc2api.out.log` / `logs\winoc2api.err.log`, then polls `/healthz` up to 30 times at 600 ms
apart (≈18 s plus probe time) and prints `OK`, or `TIMEOUT` plus the last 8 lines of each log.

### `opencode-zen-adapter/scripts/list-models.ps1` — the model lister

Reads `listen` + `server_keys` from `bin\config\config-oc2api.json` (no hardcoded host or key), calls
`GET /v1/models`, and with `-Probe` sends a real completion to each model.

```bash
powershell -File opencode-zen-adapter/scripts/list-models.ps1                    # who's exposed?
powershell -File opencode-zen-adapter/scripts/list-models.ps1 -Probe             # which respond?
powershell -File opencode-zen-adapter/scripts/list-models.ps1 -Probe -Timeout 150 -Retries 2
powershell -File opencode-zen-adapter/scripts/list-models.ps1 -Json              # machine-readable
powershell -File opencode-zen-adapter/scripts/list-models.ps1 -Prefix opec       # 9router routes
```

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-Probe` | off | send a real completion to every exposed model |
| `-Json` | off | machine-readable output |
| `-Timeout` | `45` | per-request seconds (slow reasoning models need `150`) |
| `-Retries` | `2` | retries for **transient** failures only |
| `-Prefix` | `''` | add a routing-prefix column (e.g. `opec`) |
| `-ConfigPath` | auto | override the config location |

Probe semantics — `4xx` is deterministic and never retried, `5xx`/timeout is transient and retried,
HTTP `200` with empty text is reported as `empty` rather than `ok`. Full reasoning in
[`opencode-zen-adapter/docs/models.md`](opencode-zen-adapter/docs/models.md).

## Configuration

The tracked template is
[`opencode-zen-adapter/bin/config/config.example.json`](opencode-zen-adapter/bin/config/config.example.json);
copy it to `config-oc2api.json` and set `server_keys`. The fields that define this deployment:

| Field | Value here | Why |
| --- | --- | --- |
| `listen` | `127.0.0.1:20132` | loopback only — nothing off-machine reaches it |
| `server_keys` | your own value | local auth; documented as `<YOUR_SERVER_KEY>` |
| `zen_keys`, `go_keys` | `[]` | empty by design |
| `anonymous` | `true` | drives upstream with `Bearer public` |
| `proxies` | `["direct"]` | no egress proxy |
| `prefer` | `zen` | single viable upstream |
| `retry` | `2` attempts / `120` s | bounded, so a dead model fails fast |
| `models.refresh_seconds` | `300` | model directory cache TTL |
| `reasoning.effort` | `high` | default thinking level when a request omits one |
| `webui.enabled` | `false` | management port disabled |
| `logging.dump_request_bodies` | `false` | keeps prompt content out of the logs |

Full field-by-field reference → [`opencode-zen-adapter/docs/architecture.md`](opencode-zen-adapter/docs/architecture.md)
Upstream semantics (routing, retries, proxies, health codes) → [`MidasStore/opencode2api`](https://github.com/MidasStore/opencode2api)

### Health checks

`GET /healthz` needs no auth and reports resources without leaking keys or proxy addresses:

| Path | Meaning |
| --- | --- |
| `status` / `ready` / `version` | process alive / able to serve / gateway build |
| `models.total` | models known upstream |
| `models.exposed` | models **this** gateway serves ← the number you care about |
| `models.last_refresh`, `stale`, `stale_after_seconds` | cache freshness |
| `keys.anonymous`, `keys.total` | whether `Bearer public` mode is active, and how many upstream keys exist |
| `proxies.healthy` / `total` | egress proxy health |

Readiness is a discovery and resource check — it does **not** guarantee the next inference
succeeds. For current values, run `LAUNCHER.bat status`.

## 9router (optional)

Wire the gateway behind a 9router node with prefix `opec` so every Hermes profile can use
`opec/<model>`. Provider node/connection management, the CLI token trick, and the
`POST /api/providers/{conn}/test` check → [`opencode-zen-adapter/docs/9router.md`](opencode-zen-adapter/docs/9router.md)

## Documentation

| Doc | What's in it |
|---|---|
| [`opencode-zen-adapter/docs/quickstart.md`](opencode-zen-adapter/docs/quickstart.md) | Install layout, first run, health check, first completion |
| [`opencode-zen-adapter/docs/architecture.md`](opencode-zen-adapter/docs/architecture.md) | Request flow, auth chain, full config reference |
| [`opencode-zen-adapter/docs/models.md`](opencode-zen-adapter/docs/models.md) | Dynamic model discovery, probe semantics, why naive probes lie |
| [`opencode-zen-adapter/docs/9router.md`](opencode-zen-adapter/docs/9router.md) | Wiring into 9router, provider node/connection management |
| [`opencode-zen-adapter/docs/operations.md`](opencode-zen-adapter/docs/operations.md) | Start/stop, the launcher, logs, caches, reboot behaviour |
| [`opencode-zen-adapter/docs/troubleshooting.md`](opencode-zen-adapter/docs/troubleshooting.md) | Symptom → cause → fix tables |

The Hermes skill manifest lives alongside at [`SKILL.md`](SKILL.md) — the gateway runtime itself is
nested one level down in `opencode-zen-adapter/`, and it is this skill's only runtime.

## Layout

```
winoc2api/                          ← repo root = the Hermes skill folder
├── SKILL.md
├── LAUNCHER.bat                      ← THE one launcher: status panel + menu
├── README.md   LICENSE   .gitattributes   .gitignore
└── opencode-zen-adapter/             ← the gateway runtime (binary, config, scripts, docs, logs)
    ├── bin/
    │   ├── opencode2api.exe          # gateway v1.3.5 (Windows x64)     [gitignored]
    │   └── config/
    │       ├── config.example.json   # tracked template - copy me
    │       ├── config-oc2api.json    # your real config                 [gitignored]
    │       └── *.models.*.json       # model caches, rebuilt each boot  [gitignored]
    ├── scripts/
    │   ├── adapter.ps1               # launcher engine: status panel, menu, start/stop
    │   └── list-models.ps1           # live model lister / prober  ← source of truth
    ├── logs/                         # runtime output, truncated on start [gitignored]
    └── docs/                         # the documentation above
```

## What git ignores (and why)

`.gitignore` keeps runtime artifacts permanently out of history. Patterns containing `/` are anchored
to this folder (the repo root), so the `bin/` entries carry the runtime prefix:

| Ignored path | Why |
|---|---|
| `opencode-zen-adapter/bin/opencode2api.exe` | 8 MB binary — release artifacts belong in releases, not git history |
| `opencode-zen-adapter/bin/config/config-oc2api.json` | holds `server_keys` — a credential. Copy the tracked template instead |
| `opencode-zen-adapter/bin/config/*.models.*.json` | regenerable model caches (~70 KB), rebuilt automatically on boot |
| `logs/` | runtime output, grows continuously (30 KB+ after minutes) — matched at any depth |

Tracked and safe: `opencode-zen-adapter/bin/config/config.example.json`,
`opencode-zen-adapter/scripts/*`, `opencode-zen-adapter/docs/*`, plus `SKILL.md`, `README.md`,
`LICENSE`, `.gitignore` and `.gitattributes` at the root.

The gateway binds `127.0.0.1` only, so `server_keys` has no value off this machine — but generate
your own rather than reusing one you found in a public repo.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `[FAIL] exe not found` | `bin/opencode2api.exe` is gitignored and absent | Drop the gateway binary into `bin\` |
| Window flashes and closes | Ran the `.exe` directly → config not resolved → exit 1 | Use `LAUNCHER.bat start` |
| `401 invalid local API key` | Wrong or missing `server_keys` value | Send `x-api-key` / `Bearer` with `server_keys[0]` |
| `400 max_output_tokens ... >= 16` | `max_tokens` too low | Raise it (use `512` when probing) |
| `200` but empty `content` | Reasoning tokens ate the budget | Raise `max_tokens` |
| `400 ... upstream protocol ... does not expose` | Sent `opec/MODEL_ID` directly to `:20132` | Strip the prefix — it is 9router-only |
| `address already in use` | A stale process still holds `:20132` | `LAUNCHER.bat stop`, then relaunch |

Full tables → [`opencode-zen-adapter/docs/troubleshooting.md`](opencode-zen-adapter/docs/troubleshooting.md)

`opencode2api` is **not** a Windows service: it does not survive reboot. After a reboot, run
`LAUNCHER.bat start` before using any `opec/` model.

## Requirements

- Windows x64 (the bundled gateway is a Windows build; `curl.exe` ships with Windows 10+)
- PowerShell 5.1 or newer (`list-models.ps1` declares `#Requires -Version 5.1`; `adapter.ps1` runs
  on whatever PowerShell `LAUNCHER.bat` finds)
- Network egress to `opencode.ai`
- Optional: a 9router instance on `127.0.0.1:20128` if you want the `opec/` model prefix

## License

MIT © 2026 MidasStore — see [`LICENSE`](LICENSE).
The bundled `opencode2api` binary is third-party software under its own upstream license.
Gateway project: [`MidasStore/opencode2api`](https://github.com/MidasStore/opencode2api),
forked from [`jasonxu114514/opencode2api`](https://github.com/jasonxu114514/opencode2api).
