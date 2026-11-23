# GPU Lend protocol (v1)

A **device** (a PC with a graphics card, running the GPU Lend app on Windows, Linux or macOS) lends its GPU to a **server** (any project that implements the
four endpoints below). The device always dials out over HTTPS, so no port is opened on the PC and it works behind NAT and proxies.

```
 designer ──► your server ──(job queue)◄── GET /worker/next ──── device ──► local model (127.0.0.1)
                                  ▲                                  │
                                  └──────── POST /worker/result ◄────┘
```

A **job** is "send this HTTP request to the local model and give me the answer". The server names the **backend** it needs
(`image`, `llm`, or any id the device offers), a path and a JSON body. The device starts that backend if it is not loaded (stopping its
other backend first: one model at a time on the card) and only forwards paths on that backend's own allow-list. Built-in backends:
`image` (stable-diffusion.cpp's sd-server: `/v1/images/generations`, `/sdapi/v1/img2img`) and `llm` (llama.cpp's llama-server:
`/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/completion`); a user can describe more in the app.

## Pairing text

The server's admin page shows a **pairing text** for a new device: `GLEND1.` followed by base64url (no padding) of

```json
{"u": "https://example.com", "ip": "", "fp": "", "c": "ABCDEFGH"}
```

| key | meaning |
|---|---|
| `u` | the server address devices call |
| `ip` | optional: connect to this IP directly (the app still uses `u` for TLS server name and `Host`) |
| `fp` | optional: sha256 (hex) of the certificate to trust; when set, only that certificate is accepted |
| `c` | the one-time pairing code (8 letters, valid for a short time) |

A bare code is accepted too; the user then types the server address.

## Endpoints

All bodies are JSON unless stated. Device endpoints (except `pair`) carry `Authorization: Bearer <token>`.
Tokens are a separate credential from user sessions: a server must never accept them anywhere else.

### `POST /worker/pair`
Request: `{"code": "ABCDEFGH", "name": "Amir's laptop", "version": "1.0.0"}` → `200 {"token": "<64 hex>", "worker_id": 7, "settings": {…}}`.
`401` when the code is wrong, expired or already used. The token is shown once; the device stores it encrypted (Windows DPAPI).

### `POST /worker/heartbeat`
Every ~10 s. Request:

```json
{"version": "1.1.0", "on_battery": false, "model_ready": true,
 "backends": ["image", "llm"], "usage": {"minutes": 12, "jobs": 3},
 "base_rev": 12, "edit": {"max_vram": 4.5}}
```

`model_ready` means "can take jobs now" (switched on, inside its hours and daily limits, at least one backend can run). `backends` lists the
backends this device offers (an older device that omits it offers `image` only). `usage` is what it lent today. `base_rev` and `edit` are present only when the user changed a setting on the device. Response: `{"settings": {…}, "latest_version": ""}`.
`401` means the device was revoked: it forgets its token.

**Settings** are owned by the server and versioned by `rev`:

```json
{"name": "…", "enabled": true, "max_vram": 5.4, "hour_from": 0, "hour_to": 24, "ac_only": false, "autostart": true,
 "daily_minutes": 0, "daily_jobs": 0, "rev": 12}
```

`hour_from` and `hour_to` are hours of the day on the device (its local time); `hour_from` greater than `hour_to` means a window over midnight.

An `edit` is applied only if `base_rev` equals the current `rev` (then `rev` increases by one); otherwise it is ignored and the
current settings are returned, so a change made in the admin panel is never silently overwritten. The device adopts whatever
settings come back.

### `GET /worker/next`
Held for up to ~20 s. `204` when there is nothing to do. Otherwise `200` with the request for the local model as the body and

| header | meaning |
|---|---|
| `x-lend-job` | job id |
| `x-lend-path` | the path to call on the local model |
| `x-lend-backend` | which backend the job is for (`image` when absent) |

A device receives a job only if it is enabled, ready (`model_ready`), recently seen, inside its hours, offers the job's backend and
(when `ac_only`) is not on battery. `daily_minutes` / `daily_jobs` (0 = no limit) are enforced by the device, which then reports
`model_ready: false` until the next day. One job per device at a time. A job whose device goes quiet goes back to the queue.

### `POST /worker/result/{job}`
Body: the local model's answer, untouched. Header `x-lend-status`: its HTTP status (a device that could not run the job sends
`503`). `204` on success; `403` if the job was not handed to this device.

## Sizes and time

Results can be several MB: raise the body limit for this route (and any proxy in front, e.g. nginx `client_max_body_size`).
Keep the hold time of `next` below every proxy and CDN timeout in front of the server.

## Reference implementation

[`reference-server/server.py`](reference-server/server.py) implements the four endpoints in about 150 lines of Python (standard
library only), plus `POST /submit` so a program can hand it work. `test/reference_server_test.dart` runs the app against it.
