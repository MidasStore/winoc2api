# Operations

Running the gateway day to day.

## Start

There is exactly **one launcher**: `LAUNCHER.bat`, at the **skill folder root** (one level above
this repo). Double-click it for the live status panel and menu; pass a command for scripting. A
standalone clone uses the same engine directly — `scripts\adapter.ps1`.

| Method | When |
|---|---|
| Double-click `..\LAUNCHER.bat` | Normal — status panel + menu, idempotent |
| `..\LAUNCHER.bat start` | Same engine, scripted (no menu) |
| `powershell -File scripts\adapter.ps1 start` | Standalone clone (no `LAUNCHER.bat` exists) |
| `bin\opencode2api.exe -config bin\config\config-oc2api.json` | You want logs streaming in the terminal |
| `Start-Process ... -WindowStyle Hidden` | Scripted / no window |

### What `start` does

1. If already running → prints `[OK] already running (pid N) - nothing to do.` and exits.
2. Verifies `bin\opencode2api.exe` and `bin\config\config-oc2api.json` exist; if not, prints the
   exact missing path plus the `config.example.json` hint.
3. Creates `logs\` if absent (it is gitignored, so a fresh clone will not have it).
4. Starts the exe with an **absolute** `-config` path, `WorkingDirectory` set to `bin\`, stdout/stderr
   redirected to `logs\winoc2api.out.log` / `logs\winoc2api.err.log`.
5. Polls health for up to ~18 s, then prints `OK` — or `TIMEOUT` plus the last log lines.

### The status panel

Double-clicking `LAUNCHER.bat` (or running it with no argument) prints a live panel — Status,
Health, Endpoint, Models, Refresh, Upstream, Auth, 9router, Gateway, Config, Log — followed by a
9-item menu: start, stop, restart, list models, probe models, tail logs, open config, open docs, exit.

`LAUNCHER.bat` derives every path from `%~dp0`, and `adapter.ps1` from `$PSScriptRoot`, so both work
when double-clicked, run from a shortcut, or invoked with an unrelated working directory —
**verified by launching it from `%TEMP%`.**

### Why the .exe can't be double-clicked

It resolves the config file relative to its working directory and expects `config.json`. The config
here is `bin\config\config-oc2api.json`, so a bare double-click produces:

```
ERROR configuration error error="read config.json: open config.json: The system cannot find the file specified."
```

Exit code 1 — window flashes and closes. Always use the launcher, or pass `-config` explicitly.

## Stop

`LAUNCHER.bat stop`, or:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\adapter.ps1 stop
# equivalent one-liner:
powershell -NoProfile -Command "Stop-Process -Name opencode2api -Force"
```

Graceful shutdown isn't exposed by the gateway; force-stop is the supported path. Check afterwards:

```powershell
Get-Process opencode2api -ErrorAction SilentlyContinue   # should be empty
```

## Restart

```bash
LAUNCHER.bat restart
# standalone:  powershell -File scripts\adapter.ps1 restart
```

That stops, waits 1 s, then starts and polls health. Doing it by hand? Wait ~2 s between stop and
start, otherwise the new process hits `address already in use` on 20132.

## Logs

| File | Contents |
|---|---|
| `logs/winoc2api.out.log` | stdout — startup, request log, refresh notices |
| `logs/winoc2api.err.log` | stderr — errors (empty when healthy) |

Configured by `logging` in `bin/config/config-oc2api.json`: level `info`, `ring_size: 500`,
`dump_request_bodies: false`.

> Keep **`dump_request_bodies: false`** unless you are actively debugging — turning it on writes
> prompt contents into the log.

`logs/` is gitignored and the whole folder is truncated on each start (`-RedirectStandardOutput`
reopens the file). It is regenerated content, not state — truncate or delete freely.

## Runtime caches

| File | Size | Safe to delete? |
|---|---|---|
| `bin/config/config-oc2api.json.models.catalog.json` | ~55 KB | Yes — rebuilt on boot |
| `bin/config/config-oc2api.json.models.dev.json` | ~15 KB | Yes — rebuilt on boot |

**These live next to the config file, not next to the exe and not in your working directory.** That
was verified directly: with the config in one folder and CWD in another, the caches appeared beside
the config while the CWD received only the logs. The gateway has no flag or config key to move them.

They are named after the **config file**, so renaming `bin\config\config-oc2api.json` renames the caches and
leaves the old pair orphaned (delete those).

Catalog refreshes every `models.refresh_seconds` (300 s); price/deprecation metadata every ~24 h.
Both paths are gitignored.

## Reboot behaviour

**This is not a Windows service.** It does not survive a reboot. After logging back in:

```
LAUNCHER.bat start
```

or `opec/` requests fail with `connection refused` → `502`.

If you want it to survive reboots, the launcher is the hook to schedule (Task Scheduler → at logon).

## Health & verification

```bash
# process + endpoint
powershell -Command "Get-Process opencode2api | Select-Object Id,Path"
curl http://127.0.0.1:20132/healthz

# models
powershell -File scripts/list-models.ps1 -Probe -Timeout 150 -Retries 2

# 9router leg: POST /api/providers/{conn}/test -> {"valid":true}
```

A healthy process reports `Path` under `bin\` of this repository — if it points anywhere else, an
older copy is still running.

> Do not keep a stale "N/M models work" figure anywhere — see [`models.md`](models.md).

## Troubleshooting the *process*

| Symptom | Cause | Fix |
|---|---|---|
| Window flashes then closes | Ran `.exe` directly → config not found → exit 1 | Use `LAUNCHER.bat start` |
| `[FAIL] exe not found` | Binary not placed in `bin\` (it is gitignored) | Drop `opencode2api.exe` into `bin\` |
| `[FAIL] config not found` | Fresh clone, no config yet | Copy `bin\config\config.example.json` → `bin\config\config-oc2api.json` |
| `address already in use` | Old process still holds 20132 | `LAUNCHER.bat stop` |
| Launcher says `[OK] already running (pid N)` | Expected — it was already healthy | Nothing to do |
| Launcher prints `TIMEOUT` + log tail | Startup error — read the dumped lines | Fix what the log names |
| Health OK but calls fail | Stale 9router key | Recreate the connection ([`9router.md`](9router.md)) |

## Git hygiene

`.gitignore` already excludes the risky paths — verify rather than assume:

```bash
git check-ignore -v bin/opencode2api.exe bin/config/config-oc2api.json logs/winoc2api.out.log
git status --short
```

| Path | Why excluded |
|---|---|
| `bin/opencode2api.exe` | ~8 MB binary in history |
| `bin/config/config-oc2api.json` | holds `server_keys` (a credential) |
| `bin/config/*.models.*.json` | regenerable caches, ~70 KB |
| `logs/` | runtime output, grows continuously |

A clean `git status` after a normal run should show only `docs/`, `scripts/`, `bin/config/` (with the
example), `.gitignore` and `README.md` — never the exe, real config, caches or logs.

The gateway binds `127.0.0.1` only, so the key has no value off-machine — but generate your own
rather than reusing one you found in a public repo.
