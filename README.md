# winoc2api

Free **OpenCode Zen** models behind a local OpenAI-compatible gateway, packaged so the whole thing
lives in one folder — binary, config, launchers, and a live model lister included.

Built on [`opencode2api`](https://github.com/jasonxu114514/opencode2api) v1.3.5, a Go gateway that
bridges the OpenCode Zen upstream using the native SDK protocol (session-affinity headers included),
so free-tier models work without falling back to anything else.

```
Client (Hermes) ──► 9router :20128 ──► opencode2api :20132 ──► opencode.ai/zen ──► upstream
                    prefix "opec"       this gateway            Bearer public
```

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
curl http://127.0.0.1:20132/healthz

# 3. what models are there? (always ask at runtime - never from a doc)
powershell -File opencode-zen-adapter/scripts/list-models.ps1 -Probe -Timeout 150 -Retries 2

# 4. first completion (use your own server_keys[0])
curl http://127.0.0.1:20132/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-api-key: <YOUR_SERVER_KEY>" \
  -d '{"model":"mimo-v2.6-flash-free","messages":[{"role":"user","content":"hi"}],"max_tokens":100}'
```

> **`opencode-zen-adapter/bin/opencode2api.exe` is gitignored** (it is an 8 MB binary). Drop the
> gateway binary into `opencode-zen-adapter\bin\` before the first start — the launcher fails loudly
> with `exe not found` if it is missing.

Full walkthrough → [`opencode-zen-adapter/docs/quickstart.md`](opencode-zen-adapter/docs/quickstart.md)

## Why the model list is never written down here

The free-model roster changes without notice. An earlier revision of this project kept a hardcoded
table of supported models; it drifted within hours — it listed 10 models while the gateway served 11,
and it labelled a model "SLOW ~60s" when that model responded in ~1s.

So this repo has **one source of truth**: `opencode-zen-adapter/scripts/list-models.ps1`, which reads
the live model list from the gateway and optionally sends a real completion to each entry. There is
deliberately no static "N/M models work" number anywhere in the docs.

Details and the list of probing gotchas → [`opencode-zen-adapter/docs/models.md`](opencode-zen-adapter/docs/models.md)

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

There is exactly **one** `.bat` in the whole tree. `LAUNCHER.bat` sits at this folder's root —
double-click it for the status panel, or pass a command:

```bash
LAUNCHER.bat start | stop | restart | status | models | probe | logs
```

It resolves every path from its own location (`%~dp0`), so it works from any working directory.
The same engine can be driven directly, bypassing the launcher:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File opencode-zen-adapter\scripts\adapter.ps1 start
```

`adapter.ps1` derives its paths from `$PSScriptRoot`, so it is equally CWD-independent.

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

## Requirements

- Windows x64 (the bundled gateway is a Windows build)
- Network egress to `opencode.ai`
- Optional: a 9router instance on `127.0.0.1:20128` if you want the `opec/` model prefix

## License

MIT © 2026 MidasStore — see [`LICENSE`](LICENSE).
The bundled `opencode2api` binary is third-party software under its own upstream license.
