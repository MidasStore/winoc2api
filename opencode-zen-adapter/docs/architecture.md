# Architecture

## Request flow

```
┌──────────────┐   Authorization:      ┌──────────────────┐   x-api-key:        ┌──────────────────┐
│    Hermes     │ ──── Bearer <key> ───►│   9router :20128 │ ─── <server_key> ──►│ opencode2api     │
│  (any profile)│                       │  prefix: opec    │                     │ :20132           │
└──────────────┘                       └──────────────────┘                     └────────┬─────────┘
                                                                                        │
                     x-opencode-session  +  x-opencode-project  +  Bearer public         │
                              ┌──────────────────────────────────────────────────────────▼─────────┐
                              │                     opencode.ai/zen                                │
                              └──────────────────────────────────┬─────────────────────────────────┘
                                                                 │
                                            ┌────────────────────┼────────────────────┐
                                            ▼                    ▼                    ▼
                                       Xiaomi /            NVIDIA /             DeepSeek /
                                       Muse / ...          nemotron / ...        ...
                                                        (the actual upstream)
```

Three hops, three different credentials:

| Hop | Credential | Why |
|---|---|---|
| Hermes → 9router | `Authorization: Bearer <9router key>` | 9router's own auth |
| 9router → opencode2api | `x-api-key: <server_keys[0]>` | local gateway key, from `bin/config/config-oc2api.json` |
| opencode2api → OpenCode Zen | `Bearer public` + native session headers | anonymous free-tier access |

### The session header is the whole trick

OpenCode Zen rejects free-tier calls made outside the OpenCode client with `403 FreeTierError`.
`opencode2api` derives `x-opencode-session` from a conversation fingerprint (and supplies
`x-opencode-project`) exactly the way the real SDK does, which is what makes the anonymous free tier
acceptable. Without those headers you get the 403.

Other bridge behaviours: session affinity across a conversation, bounded retry, key pool, SSE
streaming passthrough, reasoning and tool-call passthrough.

## Ports

| Port | Service | Bind |
|---|---|---|
| `20132` | **opencode2api** (this gateway) | `127.0.0.1` — localhost only |
| `20128` | 9router (optional, in front) | localhost |

Because `20132` binds loopback, nothing off-machine can reach it. The server key is therefore
defence-in-depth, not the only barrier.

## Config reference — `bin/config/config-oc2api.json`

```jsonc
{
  "listen": "127.0.0.1:20132",          // bind address — keep it loopback
  "server_keys": ["..."],               // keys callers must present via x-api-key
  "zen_keys": [],                       // optional real Zen keys; empty => anonymous
  "go_keys": [],
  "anonymous": true,                    // use Bearer public upstream
  "proxies": ["direct"],                // egress: direct, or a proxy URL
  "proxyfile": "",
  "upstream": {
    "zen": "https://opencode.ai/zen",   // primary upstream
    "go":  "https://opencode.ai/zen/go" // secondary ("go") upstream
  },
  "retry":    { "max_attempts": 2, "timeout_seconds": 120 },
  "models":   { "refresh_seconds": 300, "protocols": {} },
  "performance": {
    "max_idle_conns": 256,
    "max_idle_conns_per_host": 64,
    "max_conns_per_host": 0,            // 0 = unlimited
    "idle_conn_timeout_seconds": 120,
    "connect_timeout_seconds": 5,
    "failure_cooldown_seconds": 15,     // back off a failing upstream this long
    "attempt_timeout_seconds": 0        // 0 = no per-attempt cap
  },
  "logging": { "level": "info", "ring_size": 500, "dump_request_bodies": false },
  "webui":   { "enabled": false },
  "prefer":  "zen",                     // which upstream to prefer when both are viable
  "reasoning": { "effort": "high", "effort_by_model": {} }
}
```

Fields that matter most when tuning:

- **`models.refresh_seconds`** — how often the model directory cache refreshes (default 300 s).
  `healthz.models.stale` tells you when a refresh has been missed.
- **`performance.failure_cooldown_seconds`** — after an upstream failure the gateway stops hammering
  it for this long. If things look "stuck failing", this is why.
- **`prefer`** — with two upstreams available, which one wins.
- **`logging.dump_request_bodies`** — leave `false` in shared environments; enabling it writes
  prompt contents into the log.

## Health endpoint

`GET /healthz` → `200` with:

| Path | Meaning |
|---|---|
| `status` / `ready` | process alive / able to serve |
| `version` | gateway build (v1.3.5) |
| `models.total` | models known upstream |
| `models.exposed` | models this gateway serves ← the number you care about |
| `models.last_refresh`, `stale`, `stale_after_seconds` | cache freshness |
| `keys.anonymous` | whether `Bearer public` mode is active |
| `proxies.healthy` / `total` | egress proxy health |

## Endpoints exposed

| Method | Path | Auth |
|---|---|---|
| `GET` | `/healthz` | none |
| `GET` | `/v1/models` | key required |
| `POST` | `/v1/chat/completions` | key required |
| `POST` | `/v1/responses` | key required |
| `POST` | `/v1/messages` | key required |

**Key required** = present `server_keys[0]` as `x-api-key: <key>` *or*
`Authorization: Bearer <key>` — the two are interchangeable. Omitting or mistyping it returns
`401 authentication_error` (`invalid local API key`), on every `/v1/*` route including
`/v1/models`.

`/v1/responses` returns the OpenAI Responses shape (`object: "response"`, `output[]`);
`/v1/messages` returns the Anthropic shape (`type: "message"`, `content[]`, carrying
`thinking` blocks). Streaming (SSE, `text/event-stream`) and non-streaming responses are both
supported on all three inference routes.

Not implemented: `POST /v1/embeddings` returns `404 page not found`, as do file upload and
image-generation routes.

## Runtime-generated files

These are caches the gateway rebuilds itself — never edit, never commit. **They are written as
siblings of the config file** (`bin/config/`), not beside the exe and not into your working
directory; the gateway exposes no flag or config key to relocate them:

| File | Contents | Refresh |
|---|---|---|
| `bin/config/config-oc2api.json.models.catalog.json` | model directory (~55 KB) | every `refresh_seconds` |
| `bin/config/config-oc2api.json.models.dev.json` | price / deprecation metadata (~15 KB) | ~24 h |

Note they are named after the **config file**, so renaming the config renames the caches.

Next: [`models.md`](models.md) — how to ask for the live model list instead of trusting a doc.
