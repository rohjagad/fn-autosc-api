# fn-autosc-api

Restored API layer for the **FN AutoSC** autoscript (the panel in
[`rohjagad/fn-autosc`](https://github.com/rohjagad/fn-autosc)).

The panel's nginx config proxies `/api/` to `127.0.0.1:9000`, and the endpoints under it
(`/api/add-vmess`, `/api/list-xray`, ...) are what a web UI would call. The implementation was lost:
the original handler bundle came from `https://scvps.rerechanstore.eu.org/rere` (Rerechan's
infrastructure, now dead) and the upstream parent repository is gone.

This repository is the complete, self-contained API for the panel - **server, handlers and
installer**. [`FN-API`](https://github.com/rohjagad/FN-API) is kept only as a reference for the
original endpoint list; nothing here fetches or depends on it.

## Layout

| Path | What it is |
| :-- | :-- |
| `server` | the API server (Python 3, stdlib only). Binds `127.0.0.1:9000` by default, authenticates against `/etc/xray/.key`, runs `/usr/bin/rere/<endpoint>` with the body on stdin and returns its stdout; logs to `/etc/xray/api.log` |
| `menu-api` | installer / menu: install, uninstall, status, regenerate token. Installs `server`, `lib.sh` and the handlers, writes `/etc/xray/.key`, creates `api.service` |
| `lib.sh` | shared helpers, installed to `/usr/local/lib/fn-api/lib.sh` - reads a JSON body on stdin, writes JSON on stdout |
| `handlers/` | one executable per endpoint, each wrapping the panel's own scripts |

## Install

> **If you have just pushed to this repo**, `raw.githubusercontent.com` can serve a stale copy of a
> changed file for a few minutes (a query string does not bust it). If `menu-api install` reports a
> `FAILED to fetch ...`, fetch the **commit-pinned** URL instead -
> `https://raw.githubusercontent.com/rohjagad/fn-autosc-api/<commit>/menu-api` - or the jsDelivr
> mirror `https://cdn.jsdelivr.net/gh/rohjagad/fn-autosc-api@main/menu-api`. In normal use the plain
> `main` URL is correct.


```
wget -O /usr/bin/menu-api https://raw.githubusercontent.com/rohjagad/fn-autosc-api/main/menu-api
chmod +x /usr/bin/menu-api
menu-api install
```

`menu-api`, `menu-api status` and `menu-api token` run non-interactively; with no argument it opens
a menu. It requires the same authorisation (`izin.txt`) the panel menus use.

## Endpoint contract

Request body is a JSON object on stdin; the response is a JSON object on stdout. Auth is the raw
`Authorization` header value matching a line in `/etc/xray/.key`.

| Endpoint | Method | Body fields | Backend |
| :-- | :-- | :-- | :-- |
| `ping` | any | - | health check |
| `add-vmess` / `add-vless` / `add-trojan` | POST | `username`, `core` (`ws`/`http`/`split`/`grpc`, default `ws`), `expired` (days), `limit-ip`, `quota` | `add-<proto>-<core>` |
| `addssh` | POST | `username`, `password`, `expired`, `limit-ip` | `addssh` |
| `add-noobz` | POST | `username`, `password`, `expired` | `noobzvpns` |
| `list-xray` | GET | - | the four `json/*.json` (username, expiry, transport) |
| `list-ssh` / `cek-ssh` | GET | - | `list-ssh` / `cek-login-ssh` (text body) |
| `cek-xray` | GET | - | the four `cek-xray-*` (text body) |
| `list-noobz` | GET | - | `noobzvpns print-all` (text body) |
| `delete-xray` | DELETE | `username` | `delete-ws/http/split/grpc`, for every transport that holds it |
| `delete-ssh` | DELETE | `username` | `delete-ssh` |
| `delete-noobz` | DELETE | `username` | `noobzvpns remove` |
| `renew-xray` | PUT/POST | `username`, `days`, `core` (default `ws`) | `extend-<core>` - keeps the account's usage |
| `renew-ssh` | PUT/POST | `username`, `days` | `extend-ssh` |
| `password-ssh` | PUT/POST | `username`, `password` | `pwd-ssh` - also rewrites the account card |
| `add-ss`, `add-socks` | - | - | error JSON: no Shadowsocks/Socks5 backend exists (nor in either reference version) |

The transport is named the same everywhere: `core` accepts `ws`, `http`, `split` or `grpc`, and
`list-xray` / `delete-xray` report it back under those names (the panel's own `upgrade` name for the
HTTPUpgrade transport is not exposed). Every handler verifies the panel actually did the work and
answers `{"status":"error",...}` when it did not - a `success` means the change is in the config.

Example:

```
curl -sk -H 'Authorization: <token>' -H 'Content-Type: application/json' \
     -d '{"username":"alice","core":"ws","expired":30,"limit-ip":2,"quota":5}' \
     https://<domain>/api/add-vmess
```

```json
{"status":"success","username":"alice","protocol":"vmess","core":"ws","expired":"26-10-26","links":["vmess://..."]}
```

## Coverage

Every endpoint the panel can serve is implemented. Only `add-ss` and `add-socks` cannot work,
because the panel - and both reference versions of the autoscript - have no Shadowsocks or Socks5
account type at all; they return a clear error instead.

Two notes on the panel's own limits, which the endpoints inherit:

- `renew-ssh` and `password-ssh` drive tools the lite edition does not ship; on lite they answer
  `{"status":"error","message":"this panel edition does not ship 'extend-ssh'"}` rather than
  pretending to have worked.
- Creating a username that already exists is refused with
  `{"status":"error","message":"username '<name>' already exists"}` instead of reporting
  success for a change that never happened. The check is per transport for Xray (the same
  name may live on `ws` and `grpc` at once, and `delete-xray` spans them), global for SSH
  system users and the NoobzVPN database.
- `password-ssh` uses the panel's `pwd-ssh`, which reads the new password with Go's `Scanln` and so
  stops at the first space. A password containing whitespace is rejected rather than silently
  truncated.

## Response shape

A handler always answers HTTP 200 with `{"status":"success",...}` or
`{"status":"error","message":"..."}`; a non-zero handler exit (a crash) is HTTP 500 with
`{"error":...,"stdout":...}`. The original reference README described `{"ok":true}` /
`{"ok":false,"description":...}` for a handler bundle that no longer exists; this layer uses one
consistent shape instead of two (see `project-information/is-decision.md` in `fn-autosc`).
A handler file that cannot be executed (lost `+x`, dangling symlink target) answers the same
HTTP 500 shape rather than dropping the connection.

## Security

- Requests are handled **one at a time** (the server is single-threaded, like the
  reference). The panel's scripts edit shared state - `json/*.json`, `/etc/passwd`, service
  units - with no locking of their own, so they must never run concurrently; concurrent
  calls queue instead of racing. nginx fronts this server and buffers requests, so there
  is nothing to gain from handling them in parallel.
- The server binds **`127.0.0.1`** by default, so the API is reachable only through nginx's
  `/api/` location; pass `--bind` explicitly if you ever want it elsewhere. It also rejects paths
  with more than one segment, so a request cannot reach a handler outside `/usr/bin/rere/`.
- The handlers run **as root** (they wrap the panel's scripts), so treat the token as a root
  credential: it is generated with 40 random characters and stored `0600` in `/etc/xray/.key`.
- Consider restricting the nginx `/api/` location by source IP if only your web UI should reach it.
