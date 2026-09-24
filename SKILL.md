---
name: winoc2api
description: OpenCode Zen free models via opencode2api, fully self-contained in this skill folder. Live model discovery via list-models.ps1 — never hardcoded. No fallback.
---

# OpenCode Zen Free Models (opencode2api)

Free OpenCode Zen models through a local OpenAI-compatible endpoint. **No fallback routing.**

> **This skill folder is the only copy.** Everything it needs lives inside it — binary, config,
> launchers, model lister, docs. The two legacy folders (`%localappdata%/hermes/opencode2api/` and
> `%localappdata%/hermes/backup_opencode-zen-adapter_*`) were **deleted on 2026-09-24**.
> Do not add references back to them.

## Layout

All runtime assets live in the nested repo `opencode-zen-adapter/` — this file (`SKILL.md`) is the
only thing at the skill root besides that folder.

```
winoc2api/                                ← this skill folder
├── SKILL.md                                ← this file
├── LAUNCHER.bat                            ← THE one launcher: status panel + menu
└── opencode-zen-adapter/                   ← git repo = the actual runtime
    ├── bin/
    │   ├── opencode2api.exe                # gateway v1.3.5        [gitignored]
    │   └── config/
    │       ├── config.example.json         # tracked template
    │       ├── config-oc2api.json          # real config + key     [gitignored]
    │       └── *.models.*.json             # model caches          [gitignored]
    ├── scripts/
    │   ├── adapter.ps1                     # panel/status engine (LAUNCHER.bat runs this)
    │   └── list-models.ps1                 # dynamic model lister  ← source of truth
    ├── logs/                               # runtime logs          [gitignored]
    ├── docs/                               # quickstart, architecture, models, 9router, ops, troubleshooting
    ├── README.md  LICENSE  .gitignore  .gitattributes
```

`LAUNCHER.bat` resolves every path from its own location (`%~dp0`), so it works from any working
directory. Double-click it for the status panel and menu; pass a command for scripted use.

**opencode2api** = Go gateway v1.3.5 (`github.com/jasonxu114514/opencode2api`). Native protocol
bridge with session affinity (`x-opencode-session` derived from conversation, `x-opencode-project`),
retry, key pool, SSE bridging, reasoning/tool passthrough. `anonymous: true` = `Bearer public` upstream.

**History:** the old Python adapter (`adapter.py`, `:20131`) was removed 2026-09-24. Its backup was
deleted the same day along with the redundant parent `opencode2api/` folder. Later the same day the
runtime was reorganised out of flat files into `bin/`, `scripts/`, `logs/` inside the repo, and the
duplicate copy that had lived at the skill root was removed — **one exe, one config, one log set.**
The three `.bat` wrappers then collapsed into a single `LAUNCHER.bat` at the skill root —
**one launcher**, with a live status panel instead of silent scripts.

## Quick Commands

```bash
# Start  (double-click LAUNCHER.bat for the interactive panel)
%localappdata%/hermes/skills/devops/winoc2api/LAUNCHER.bat start

# The one launcher takes a command:
#   start | stop | restart | status | models | probe | logs

# Console mode (logs stream live) - keep CWD at the repo root for a relative -config
cd %localappdata%/hermes/skills/devops/winoc2api/opencode-zen-adapter
bin/opencode2api.exe -config bin/config/config-oc2api.json

# Health check
curl http://127.0.0.1:20132/healthz

# List models (dynamic — do NOT paste results into this file)
curl http://127.0.0.1:20132/v1/models -H "x-api-key: oc2api...026"

# Chat completion (direct)
curl http://127.0.0.1:20132/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-api-key: oc2api...026" \
  -d '{"model":"mimo-v2.6-flash-free","messages":[{"role":"user","content":"hi"}],"max_tokens":100}'
```

> Model IDs go to `:20132` **bare** (`mimo-v2.6-flash-free`). The `opec/` prefix is a 9router-only
> alias; sending `opec/...` straight to `:20132` returns 400 unknown model.
> The model id above is an *example only* — always confirm against a live query.

## Free Models — LIVE, do not hardcode

**The model list is dynamic. Never copy it into a doc, `.json`, or table — it drifts.**
Query it at runtime:

```bash
# via the launcher (double-click LAUNCHER.bat, then choose [4] or [5])
LAUNCHER.bat models
LAUNCHER.bat probe

# or direct
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\list-models.ps1            # who's exposed?
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\list-models.ps1 -Probe     # which actually work?
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\list-models.ps1 -Probe -Timeout 150 -Retries 2
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\list-models.ps1 -Json      # machine-readable
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\list-models.ps1 -Prefix opec  # show 9router route
```

`list-models.ps1` reads `listen` + `server_keys` from `bin\config\config-oc2api.json` (no hardcoded
host/key — it auto-locates that path relative to itself), calls `GET /v1/models` for the live list,
and with `-Probe` sends a real completion to each model.

**`-Probe` semantics** (why a naive probe lies):

| Observation | Meaning | Retried? |
|---|---|---|
| `4xx` | Deterministic rejection → genuinely dead | No |
| `5xx` | Transient upstream blip | Yes (`-Retries`) |
| `timeout` | Slow/cold start | Yes (`-Retries`) |
| `200` + empty text | Reasoning tokens ate the budget | Reported as `empty` |

Gotchas discovered the hard way — all of these produced **false** "dead" verdicts before:

1. `max_tokens` **must be ≥ 16** — the provider 400s on lower
   (`max_output_tokens The number must be >= 16`).
2. Reasoning models burn ~190 tokens **before** emitting visible text, so a small budget
   returns HTTP 200 with empty content. Probe uses `max_tokens: 512`.
3. The error stream must be read from `Position = 0`, otherwise the body reads as empty
   and you lose the actual upstream error message.
4. A **single** 502 is not death — `nemotron-3-ultra-free` returned 502 then OK on retry.

**Stale-doc proof:** a hardcoded 10-row table sat here while the gateway served 11 models
(`big-pickle` missing), and it labelled `nemotron-3.5-lightning-free` as "SLOW ~60s" when it
responds in ~1s. Run `-Probe` for truth.

> Historical note: a 2026-09-24 snapshot claimed "8/10 work". Live probe at that time showed
> **9/11** (`deepseek-v4-flash-free` and `jev-1.13-free` were the only persistent failures).
> Both are upstream-side on OpenCode — they recover automatically, zero changes needed.

## 9router Integration

- Provider prefix: `opec`
- Provider node: `openai-compatible-chat-ed8bd2c8-ffc7-468d-bc5d-c9bae084ad15`
- Base URL: `http://127.0.0.1:20132/v1`
- Connection ids: `8cdee9cd-aa69-4e90-a536-8a25779fa66a` (Key 1 | oc2api-local-key-2026),
  `f9e37d44-7c45-434b-92a9-99dbd3c83ab5` (oc2api-key) — both authType apikey
- **API key: `oc2api-local-key-2026`** (read it from `bin\config\config-oc2api.json` → `server_keys[0]`)
- Usage: `opec/<model>` in any Hermes profile

### Usage

```
# Through 9router (any Hermes profile)
POST http://127.0.0.1:20128/v1/chat/completions
Authorization: Bearer {HERME...KEY}
{"model": "opec/mimo-v2.6-flash-free", "messages": [{"role": "user", "content": "hi"}]}
```

## How It Works

```
Client (Hermes) → 9router :20128 (prefix opec)
  → opencode2api :20132 (x-api-key: oc2api-local-key-2026)
    → opencode.ai/zen (Bearer public + native session headers)
      → upstream (Xiaomi / NVIDIA / DeepSeek / ...)
```

**Auth chain:**
1. Hermes → 9router: `Authorization: Bearer {HERMES_..._API_KEY}`
2. 9router → opencode2api: `x-api-key: oc2api-local-key-2026`
3. opencode2api → OpenCode Zen: `Bearer public` + `x-opencode-session` + `x-opencode-project`

The `x-opencode-session` header is what bypasses the "free tier can only be used from within OpenCode" 403 — opencode2api derives it from the conversation fingerprint, same as the real SDK.

## 9router Provider Management

```python
import urllib.request, json, hashlib, os

# CLI token
machine_id = open(os.path.expanduser("~/AppData/Roaming/9router/machine-id")).read().strip()
cli_secret = open(os.path.expanduser("~/AppData/Roaming/9router/auth/cli-secret")).read().strip()
token = hashlib.sha256((machine_id + "9r-cli-auth" + cli_secret).encode()).hexdigest()[:16]
H = {"x-9r-cli-token": token, "Content-Type": "application/json"}

# List providers
urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:20128/api/providers", headers=H))

# List provider nodes
urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:20128/api/provider-nodes", headers=H))

# Update opec node (baseUrl, name, etc.)
node_id = "openai-compatible-chat-ed8bd2c8-ffc7-468d-bc5d-c9bae084ad15"
body = json.dumps({"name":"OpenCode Zen (oc2api)","prefix":"opec","baseUrl":"http://127.0.0.1:20132/v1","type":"openai-compatible","apiType":"chat"}).encode()
urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:20128/api/provider-nodes/{node_id}", data=body, headers=H, method="PUT"))

# Set API key on connection (PUT does NOT accept apiKey — use POST)
conn_id = "8cdee9cd-aa69-4e90-a536-8a25779fa66a"
# First delete old, then create new:
urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:20128/api/providers/{conn_id}", headers=H, method="DELETE"))
body2 = json.dumps({"provider": node_id, "name": "oc2api-key", "apiKey": "oc2api-local-key-2026"}).encode()
urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:20128/api/providers", data=body2, headers=H, method="POST"))

# Test connection
urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:20128/api/providers/{conn_id}/test", headers=H, method="POST"))
```

## Start Manually (the single launcher)

> **Do NOT double-click `opencode2api.exe` directly.** It resolves the config file relative to its
> own working directory and expects a file literally named `config.json`; the real config is
> `bin\config\config-oc2api.json`. Result:
> `ERROR configuration error error="read config.json: open config.json: The system cannot find the file specified."`
> → exit code 1 → the window flashes and closes.

**Entry point:** `%localappdata%/hermes/skills/devops/winoc2api/LAUNCHER.bat`

One file for everything. Double-click it and you get a live status panel (Status, Health, Endpoint,
Models, Refresh, Upstream, Auth, 9router, Gateway, Config, Log) plus a 9-item menu; or pass a command:

| Command | Does |
|---|---|
| `LAUNCHER.bat start` | start, wait until ready |
| `LAUNCHER.bat stop` | force stop |
| `LAUNCHER.bat restart` | stop, then start |
| `LAUNCHER.bat status` | print the status panel, exit |
| `LAUNCHER.bat models` | live model list |
| `LAUNCHER.bat probe` | live model list + probe every model |
| `LAUNCHER.bat logs` | tail the runtime logs |
| `LAUNCHER.bat open-config` | open `bin\config` in Explorer |
| `LAUNCHER.bat open-docs` | open `docs` in Explorer |

It delegates to `opencode-zen-adapter\scripts\adapter.ps1`, which is idempotent and prints the
result instead of flashing:

1. If already running → prints `[OK] already running (pid N) - nothing to do.`
2. Verifies `bin\opencode2api.exe` + `bin\config\config-oc2api.json` exist, naming the exact missing
   path (and the `config.example.json` hint) if not.
3. Creates `logs\` if absent — it is gitignored, so a fresh clone will not have it.
4. Starts the exe with an explicit absolute `-config`, `WorkingDirectory` = `bin\`, and stdout/stderr
   redirected to `logs\winoc2api.out.log` / `logs\winoc2api.err.log`.
5. Polls health for up to ~18s → prints `OK`, or `TIMEOUT` plus the last log lines.

A standalone clone (no `LAUNCHER.bat`) uses the same engine directly:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\adapter.ps1 start
```

### Console mode (watch logs live)

```bash
cd %localappdata%/hermes/skills/devops/winoc2api/opencode-zen-adapter
bin/opencode2api.exe -config bin/config/config-oc2api.json
```

Server blocks the terminal; Ctrl+C stops it. Keep the CWD at the repo root when passing a *relative*
`-config` — it resolves against your working directory. Model caches are unaffected: they always land
beside the config in `bin\config\`, regardless of CWD (verified).

### Fresh clone gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `[FAIL] exe not found` | `bin/opencode2api.exe` is gitignored | Drop the binary into `bin\` |
| `[FAIL] config not found` | no config created yet | Copy `bin\config\config.example.json` → `bin\config\config-oc2api.json`, set `server_keys` |

### Symptom → cause

| Symptom | Cause |
|---|---|
| Window flashes and closes instantly | Ran the `.exe` directly, or wrong CWD → config not found → exit 1 |
| `address already in use` in log | Stale process still holds `:20132` → run `LAUNCHER.bat stop`, relaunch |
| Launcher says `Already running` | Expected — service was already healthy |
| Process `Path` not under `bin\` | An older copy is still running → stop it, relaunch |

`opencode2api` is **not** a Windows service: it does not survive reboot. After a reboot, run
`LAUNCHER.bat start` before using any `opec/` model.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| 401 "invalid local API key" | Wrong key in 9router connection | `POST /api/providers` with correct `apiKey` |
| 403 FreeTierError | Not using opencode2api (missing session headers) | Use `:20132` not `:20131` |
| 400 unknown model | Sent `opec/...` directly to `:20132` | Strip the prefix; `opec/` is 9router-only |
| 400 "Model is unavailable" | Upstream dead on OpenCode's side | `scripts\list-models.ps1 -Probe` to confirm; wait for upstream |
| 400 `max_output_tokens ... >= 16` | Your `max_tokens` too low | Send `max_tokens >= 16` (use 512 for reasoning models) |
| 200 response but empty `content` | Reasoning tokens consumed the budget | Raise `max_tokens` (reasoning burns ~190 first) |
| One-off 502 "unsupported upstream response" | Transient upstream blip | Retry; do **not** mark the model dead from a single 502 |
| 500 Internal error | Upstream crash (transient) | Retry; model cooldown in 9router |
| 503 from 9router | oc2api down or 9router backoff | Check `:20132/healthz`; wait for backoff reset |
| Port 20132 bind error | Old process not killed | `LAUNCHER.bat stop` |
| EXE window flashes then closes | Ran `.exe` directly → config not found → exit 1 | Use `LAUNCHER.bat start` |

Full tables → `opencode-zen-adapter/docs/troubleshooting.md`

## Verification — run it, don't read it

There is deliberately **no static "N/M models work" number in this file.** That number goes stale
within hours; three different stale figures lived here before (10-row table, "8/10", "exposed 11").

Re-verify with:

```bash
LAUNCHER.bat status                                            # 1. gateway up?
powershell -File scripts\list-models.ps1 -Probe -Timeout 150 -Retries 2   # 2. which models work?
powershell -Command "Get-Process opencode2api | Select-Object Id,Path"    # 3. running from bin\ ?
```

Step 3 matters after any reorganisation: a healthy `Path` must end in
`opencode-zen-adapter\bin\opencode2api.exe`.

Then confirm the 9router leg (needs the CLI token):

```python
# POST http://127.0.0.1:20128/api/providers/{conn_id}/test  -> {"valid":true}
# conn ids: 8cdee9cd-aa69-4e90-a536-8a25779fa66a  (Key 1 | oc2api-local-key-2026)
#           f9e37d44-7c45-434b-92a9-99dbd3c83ab5  (oc2api-key)
```

**Last probe (2026-09-24, informational only — re-run for current truth):** 11 exposed, 9 OK,
2 persistent 400 (`deepseek-v4-flash-free`, `jev-1.13-free`, both upstream-side on OpenCode).
`big-pickle` was live but missing from the earlier table.
