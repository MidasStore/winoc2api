# 9router integration

9router sits in front of this gateway and gives its models the `opec/` prefix, so any Hermes profile
can use them as `opec/<model>`.

## Wiring

| Setting | Value |
|---|---|
| Provider prefix | `opec` |
| Provider node id | `openai-compatible-chat-ed8bd2c8-ffc7-468d-bc5d-c9bae084ad15` |
| Node name | `OpenCode Zen (oc2api)` |
| Type / apiType | `openai-compatible` / `chat` |
| Base URL | `http://127.0.0.1:20132/v1` |
| Connection ids | `8cdee9cd-aa69-4e90-a536-8a25779fa66a` — *Key 1* |
|  | `f9e37d44-7c45-434b-92a9-99dbd3c83ab5` — *oc2api-key* |
| Connection auth | `authType: apikey`, key = `server_keys[0]` from this gateway's config |
| 9router API | `http://127.0.0.1:20128` |

The node's `baseUrl` must point at `http://127.0.0.1:20132/v1` — **this gateway**, not the public
OpenCode endpoint. Point it elsewhere and you lose the session headers, which means
`403 FreeTierError`.

## Calling through 9router

```json
POST http://127.0.0.1:20128/v1/chat/completions
Authorization: Bearer <YOUR_9ROUTER_KEY>
Content-Type: application/json

{"model": "opec/mimo-v2.6-flash-free", "messages": [{"role": "user", "content": "hi"}]}
```

> The `opec/` prefix exists **only** at 9router. This gateway wants bare IDs
> (`mimo-v2.6-flash-free`); passing `opec/...` directly to `:20132` returns `400 unknown model`.

## Managing the provider from a script

9router exposes a local API guarded by a CLI token:

```python
import urllib.request, json, hashlib, os

machine_id = open(os.path.expanduser("~/AppData/Roaming/9router/machine-id")).read().strip()
cli_secret = open(os.path.expanduser("~/AppData/Roaming/9router/auth/cli-secret")).read().strip()
token = hashlib.sha256((machine_id + "9r-cli-auth" + cli_secret).encode()).hexdigest()[:16]
H = {"x-9r-cli-token": token, "Content-Type": "application/json"}

NODE = "openai-compatible-chat-ed8bd2c8-ffc7-468d-bc5d-c9bae084ad15"
BASE = "http://127.0.0.1:20128"

# inspect
urllib.request.urlopen(urllib.request.Request(f"{BASE}/api/provider-nodes", headers=H))
urllib.request.urlopen(urllib.request.Request(f"{BASE}/api/providers", headers=H))

# point the node at this gateway
body = json.dumps({
    "name": "OpenCode Zen (oc2api)", "prefix": "opec",
    "baseUrl": "http://127.0.0.1:20132/v1",
    "type": "openai-compatible", "apiType": "chat",
}).encode()
urllib.request.urlopen(urllib.request.Request(f"{BASE}/api/provider-nodes/{NODE}",
                                             data=body, headers=H, method="PUT"))

# set the key — PUT does NOT accept apiKey, so recreate the connection instead
conn = "8cdee9cd-aa69-4e90-a536-8a25779fa66a"
urllib.request.urlopen(urllib.request.Request(f"{BASE}/api/providers/{conn}",
                                             headers=H, method="DELETE"))
key_body = json.dumps({
    "provider": NODE, "name": "oc2api-key",
    "apiKey": "<YOUR_SERVER_KEY>",
}).encode()
urllib.request.urlopen(urllib.request.Request(f"{BASE}/api/providers",
                                             data=key_body, headers=H, method="POST"))

# verify
urllib.request.urlopen(urllib.request.Request(f"{BASE}/api/providers/{conn}/test",
                                             headers=H, method="POST"))
```

> **`PUT` on a connection silently ignores `apiKey`.** If you change the gateway key, DELETE the old
> connection and POST a new one — otherwise 9router keeps the stale key and you get `401 invalid
> local API key` with no obvious cause.

## Verifying the whole chain

Three independent checks; run them in order so you know which hop is broken:

```bash
# 1. gateway alive?
curl http://127.0.0.1:20132/healthz

# 2. models really respond?
powershell -File scripts/list-models.ps1 -Probe -Timeout 150 -Retries 2

# 3. 9router can reach it with the key?
#    POST /api/providers/{conn}/test  ->  {"valid":true,"error":null}
```

Then an end-to-end call through 9router with an `opec/` model.

If step 1 passes but step 3 fails, the problem is the key or the node's `baseUrl` — not the gateway.

## Symptom → hop

| Symptom | Broken hop |
|---|---|
| `connection refused` / `502 ECONNREFUSED` | gateway not running → start it |
| `401 invalid local API key` | 9router holds a stale key → recreate the connection |
| `403 FreeTierError` | traffic isn't passing through `:20132`, so session headers are missing |
| `400 unknown model` | `opec/` prefix sent straight to `:20132` |
| `503` from 9router | gateway down, or 9router backoff — check `:20132/healthz`, wait it out |

Full table → [`troubleshooting.md`](troubleshooting.md)
