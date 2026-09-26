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
| `add-ss`, `add-socks` | - | - | error JSON: no Shadowsocks/Socks5 backend exists (nor in either reference version) |

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

## Security

- The server binds **`127.0.0.1`** by default, so the API is reachable only through nginx's
  `/api/` location; pass `--bind` explicitly if you ever want it elsewhere. It also rejects paths
  with more than one segment, so a request cannot reach a handler outside `/usr/bin/rere/`.
- The handlers run **as root** (they wrap the panel's scripts), so treat the token as a root
  credential: it is generated with 40 random characters and stored `0600` in `/etc/xray/.key`.
- Consider restricting the nginx `/api/` location by source IP if only your web UI should reach it.
