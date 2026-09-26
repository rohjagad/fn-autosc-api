# fn-autosc-api

Restored API layer for the **FN AutoSC** autoscript (the panel in
[`rohjagad/fn-autosc`](https://github.com/rohjagad/fn-autosc)).

The panel's nginx config proxies `/api/` to `127.0.0.1:9000`. The service that answers there is
[`FN-API`](https://github.com/rohjagad/FN-API) (`core/server`, a Python HTTP server on `:9000`), but
the pieces it dispatches to were missing: it runs `/usr/bin/rere/<endpoint>`, and that handler
bundle plus the `menu-api` command were lost - the original came from
`https://scvps.rerechanstore.eu.org/rere` (Rerechan's infrastructure, now dead) and the upstream
parent repository is gone.

This repository restores them. **`rohjagad/FN-API` is left untouched and is still used read-only**
for `core/server`; everything restored lives here.

## Layout

| Path | What it is |
| :-- | :-- |
| `menu-api` | installer / menu: install, uninstall, status, regenerate token. Fetches the server from FN-API, patches it to bind loopback, writes `/etc/xray/.key`, installs `lib.sh` and the handlers, creates `api.service` |
| `lib.sh` | shared helpers, installed to `/usr/local/lib/fn-api/lib.sh` - reads a JSON body on stdin, writes JSON on stdout |
| `handlers/` | one executable per endpoint, each wrapping the panel's own scripts |

## Install

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

- `menu-api install` patches the fetched server to bind **`127.0.0.1`** (upstream binds all
  interfaces), so the API is reachable only through nginx's `/api/` location.
- The handlers run **as root** (they wrap the panel's scripts), so treat the token as a root
  credential: it is generated with 40 random characters and stored `0600` in `/etc/xray/.key`.
- Consider restricting the nginx `/api/` location by source IP if only your web UI should reach it.
