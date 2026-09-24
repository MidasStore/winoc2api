# Quickstart

Get from zero to a working completion.

## 1. Layout check

Everything the gateway needs sits in fixed places — nothing depends on your working directory:

```
<skill-folder>/                    # if installed as a Hermes skill
├── LAUNCHER.bat                   # THE one launcher: status panel + menu
└── <repo-root>/                   # this repository (also clones standalone)
    ├── bin/opencode2api.exe           # the gateway        [gitignored - you provide it]
    ├── bin/config/config.example.json # template           [tracked]
    ├── scripts/adapter.ps1            # launcher engine (LAUNCHER.bat runs this)
    └── scripts/list-models.ps1        # model lister
```

Missing pieces on a fresh clone? Do these two things:

```bash
cp bin/config/config.example.json bin/config/config-oc2api.json   # then edit server_keys
# and drop opencode2api.exe into bin\
```

## 2. Start it

**Easiest:** double-click `LAUNCHER.bat` at the skill folder root — it opens the live status panel
and a menu. To script it instead:

```bash
LAUNCHER.bat start                        # installed as the Hermes skill
powershell -File scripts\adapter.ps1 start  # standalone clone
```

The engine resolves exe, config and logs relative to its own location, so it works from any
directory. It is idempotent and reports instead of flashing:

```
  [*] starting gateway  OK
```

- Already running → prints `[OK] already running (pid N) - nothing to do.` and exits.
- Missing exe or config → prints `[FAIL]` naming the exact path, plus the template hint.
- Not ready within ~18 s → prints `TIMEOUT` plus the tail of `logs\winoc2api.err.log`.
- Creates `logs\` automatically if it does not exist (it is gitignored, so a fresh clone lacks it).

Confirm with `LAUNCHER.bat status` — the panel shows Status, Health, Endpoint, Models, Refresh,
Upstream, Auth, 9router, Gateway, Config and Log at a glance.

**From a shell (console mode, logs stream live):**

```bash
cd <repo-root>
bin\opencode2api.exe -config bin\config\config-oc2api.json
```

> Keep the working directory at `<repo-root>` when you pass a *relative* `-config`, because the
> config path resolves against your CWD. (Model caches are unaffected — they always land next to the
> config file, in `bin\config\`, regardless of CWD.)

**Background / no window:**

```powershell
$r = '<repo-root>'
powershell -NoProfile -Command "Start-Process -FilePath '$r\bin\opencode2api.exe' -ArgumentList '-config','$r\bin\config\config-oc2api.json' -WorkingDirectory '$r\bin' -WindowStyle Hidden"
```

### Do not double-click the .exe directly

`opencode2api.exe` looks for a file literally named `config.json` in its working directory. The
config here is `bin\config\config-oc2api.json`, so a bare double-click dies instantly:

```
ERROR configuration error error="read config.json: open config.json: The system cannot find the file specified."
```

Exit code 1, window flashes, gone. Always use the launcher or pass `-config` explicitly.

## 3. Health check

```bash
curl http://127.0.0.1:20132/healthz
```

Healthy response:

```json
{
  "status": "ok",
  "ready": true,
  "version": "v1.3.5",
  "models": {
    "status": "ready",
    "total": 80,
    "exposed": 11,
    "last_refresh": "2026-09-24T09:22:22.0290353Z",
    "stale_after_seconds": 600,
    "cache_source": "live",
    "stale": false
  },
  "keys": { "zen": 0, "go": 0, "total": 0, "anonymous": true },
  "proxies": { "total": 1, "healthy": 1, "unhealthy": 0 }
}
```

Read the two model numbers carefully:

- **`total`** — models the upstream directory knows about.
- **`exposed`** — models this gateway will actually serve. This is the number that matters to you.

If `stale` flips to `true`, the model cache is older than `stale_after_seconds`; refresh happens
automatically every `models.refresh_seconds` (default 300 s).

## 4. Get your server key

The gateway authenticates callers with a key from the config:

```powershell
(Get-Content bin\config\config-oc2api.json -Raw | ConvertFrom-Json).server_keys[0]
```

Set your own value in `bin\config\config-oc2api.json` → `server_keys` rather than copying anyone
else's.

## 5. Discover models (do not ask a doc)

```bash
powershell -File scripts/list-models.ps1              # what's exposed?
powershell -File scripts/list-models.ps1 -Probe       # what actually responds?
LAUNCHER.bat models                                 # same, via the one launcher
```

The lister locates `bin\config\config-oc2api.json` on its own — it works from any working directory.
Expected shape of the output:

```
Gateway : http://127.0.0.1:20132   (up=ok, upstream=80, exposed=11)
Config  : <repo>\bin\config\config-oc2api.json
Refresh : 2026-09-24T09:22:22.0290353Z  stale=False

  big-pickle
  deepseek-v4-flash-free
  ...

RESULT: 11 models exposed. Add -Probe to test each one.
```

Full semantics, including what each status means → [`models.md`](models.md)

## 6. First completion

```bash
curl http://127.0.0.1:20132/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-api-key: <YOUR_SERVER_KEY>" \
  -d '{"model":"mimo-v2.6-flash-free","messages":[{"role":"user","content":"reply with exactly: OK"}],"max_tokens":100}'
```

> **Model IDs go to `:20132` bare** (`mimo-v2.6-flash-free`). The `opec/` prefix is a 9router-only
> alias — sending `opec/...` straight to this gateway returns `400 unknown model`.

### Two request pitfalls

| Mistake | Symptom | Fix |
|---|---|---|
| `max_tokens` below 16 | `400` — ``max_output_tokens The number must be `>= 16` `` | Use ≥ 16; use **512** for reasoning models |
| `max_tokens` too small for reasoning models | `200` but `content` is empty | Reasoning burns ~190 tokens before any visible text; raise the budget |

## 7. Through 9router instead

Once 9router is wired up (see [`9router.md`](9router.md)), prefix the model:

```json
POST http://127.0.0.1:20128/v1/chat/completions
Authorization: Bearer <YOUR_9ROUTER_KEY>
{"model": "opec/mimo-v2.6-flash-free", "messages": [{"role": "user", "content": "hi"}]}
```

## 8. Stop

`LAUNCHER.bat stop`, or:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\adapter.ps1 stop
# equivalent one-liner:
powershell -NoProfile -Command "Stop-Process -Name opencode2api -Force"
```

> **The gateway is not a Windows service.** It does not survive a reboot — run
> `LAUNCHER.bat start` after logging back in, or `opec/` requests will fail with connection
> refused → `502`.

Next: [`architecture.md`](architecture.md) for how the pieces fit together.
