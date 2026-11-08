# RSDWServerAPI

A server management API for **RuneScape: Dragonwilds** dedicated servers on Linux.

It adds a REST API and a Source RCON listener to a running server, so you can see who is
connected, read their live stats, and kick them remotely - from a panel, a script, a
Discord bot, or anything else that speaks HTTP.

## Features

- **Live player data** - names, character names, SteamID64, character GUID, ping,
  position, rotation, velocity, health, sustenance, hydration, skills and every float
  attribute the character carries.
- **Remote kick** through the game's own kick function, persistent until the server
  restarts, exactly like an in-game kick.
- **Broadcast** to all players through the game's own chat.
- **Give items** through the game's own give function.
- **Bans** that survive restarts, with offline players bannable by SteamID64.
- **In-game admin commands** - `/kick`, `/ban`, `/unban`, `/give`, gated by the game's
  own owner and admin list.
- **Discord relay** - in-game chat and player deaths posted to a webhook.
- **Two independent listeners** - REST and Source RCON, each switchable on its own.
- **Access control on both** - bearer token or RCON password, IP whitelisting, per-address
  rate limiting and automatic blocking after repeated failed logins.
- **Offsets validated at runtime.** Every discovery step is checked and cross-checked
  before anything is read, and a mismatch after a game patch degrades to a `503` and a log
  line rather than serving nonsense.

## Build

Docker is the only requirement. The build container is Debian bookworm, matching the image
the dedicated server runs in, so the result never asks the host for a newer glibc than it
has. `libstdc++` and `libgcc` are linked statically.

```bash
./build.sh
```

Output: `dist/librsdwapi.so`.

A bare `make` or `xmake` also works if you already have a Linux toolchain. Builds on hosts
with glibc 2.38+ (Ubuntu 24.04, Fedora 39+) stay loadable on the server image thanks to
`src/utils/glibc_compat.cpp`; run `make glibc-check` to confirm the result needs nothing newer
than bookworm's glibc 2.36. Objects track their header dependencies, so a header change rebuilds
everything that includes it; `make rebuild` forces a full build from scratch.

The version lives in `src/version.h` and nowhere else.

## Install

Copy `dist/librsdwapi.so` to the server and prefix the startup command:

```bash
LD_PRELOAD=./librsdwapi.so ./RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping -log -port=7777
```

On Pterodactyl or Pelican, put the `.so` in the server root and set the startup to:

```
LD_PRELOAD=/home/container/librsdwapi.so ./RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping -log -port={{SERVER_PORT}} -ini:Game:[/Script/Engine.GameSession]:MaxPlayers={{MAX_PLAYERS}}
```

Allocate the API port (and the RCON port, if you turn it on) in the panel.

A ready-made egg is in [`egg/`](egg/): import `egg-runescape-dragonwilds-rsdwapi.json`. It
installs the server through SteamCMD, downloads `librsdwapi.so` from a GitHub release (by asset
name) or a URL you give it, writes `DedicatedServer.ini` from panel variables on every boot,
and exposes every setting below as a panel variable. Edit `egg/install.sh` and `egg/start.sh`,
then regenerate the JSON with `python3 egg/build-egg.py`.

The mod only activates inside the server binary itself (`RSDragonwildsServer*`, not the `.sh`
wrapper). `LD_PRELOAD` is inherited by every child of the startup shell, so this keeps a wrapper
script from grabbing the API port first. Set `RSDWAPI_FORCE=1` to load it into anything else.

## Configuration

On first run the mod writes `rsdwapi/settings.ini` beside the server binary, which on a
stock install is `RSDragonwilds/Binaries/Linux/rsdwapi/`. Set `RSDWAPI_DIR` to put it
somewhere easier to reach - on a panel, `RSDWAPI_DIR=/home/container/rsdwapi`.

A bearer token and an RCON password are generated on that first run and never regenerated
afterwards, so an empty value stays empty.

**The REST API is on by default. RCON is off by default** - set `Enabled=true` under
`[RCON]` to use it; the password is already generated and waiting.

```ini
[General]
EnableLogging=true
VerboseLogging=true

[API]
Enabled=true
BindAddress=0.0.0.0
Port=8080
BearerToken=<generated>
IPWhitelist=

[RCON]
Enabled=false
BindAddress=0.0.0.0
Port=27020
Password=<generated>
IPWhitelist=
CommandsPerMinute=60
CommandBurst=15
MaxFailedAuth=5
FailWindowSeconds=60
BanSeconds=300
MaxConnections=16

[Discord]
Enabled=false
WebhookUrl=
DeathWebhookUrl=
Username=Dragonwilds
```

### Environment overrides

Any of these, when set and non-empty, override `settings.ini` on startup and are written back
to it, so the file always shows what is running. Panels export blank variables as empty
strings, which are ignored. Names are logged at startup; values never are.

| Variable | Setting |
|----------|---------|
| `RSDWAPI_VERBOSE_LOGGING` | `[General] VerboseLogging` |
| `RSDWAPI_API_ENABLED`, `RSDWAPI_API_PORT`, `RSDWAPI_API_BIND`, `RSDWAPI_API_TOKEN`, `RSDWAPI_API_WHITELIST` | `[API]` |
| `RSDWAPI_RCON_ENABLED`, `RSDWAPI_RCON_PORT`, `RSDWAPI_RCON_BIND`, `RSDWAPI_RCON_PASSWORD`, `RSDWAPI_RCON_WHITELIST` | `[RCON]` |
| `RSDWAPI_DISCORD_ENABLED`, `RSDWAPI_DISCORD_WEBHOOK`, `RSDWAPI_DISCORD_DEATH_WEBHOOK`, `RSDWAPI_DISCORD_USERNAME` | `[Discord]` |

Booleans accept `true`/`1`/`yes`/`on`.

Set `Enabled=true` and paste a webhook URL to relay in-game chat to a Discord channel.
Player deaths go to `DeathWebhookUrl`, or to `WebhookUrl` when that is left empty.

Bans are kept in `rsdwapi/bans.json` beside the config and survive restarts.

`IPWhitelist` takes a comma separated list of addresses and CIDR blocks
(`127.0.0.1,10.0.0.0/8`). Empty allows everyone. It applies to both listeners
independently, and an unparseable entry is logged and ignored rather than silently locking
everyone out.

Clearing `BearerToken` disables REST authentication entirely. That is deliberate and it
sticks, but bind to `127.0.0.1` or set an `IPWhitelist` if you do it. A warning is logged
at startup either way.

An empty RCON `Password` keeps RCON from starting at all, by design.

Logs go to `<data dir>/logs/api.log`, rotated on each boot with ten kept, and mirrored to
the server's stdout so a panel console shows them.

## REST endpoints

Every request needs `Authorization: Bearer <token>` unless `BearerToken` is empty.

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/hello` | Load check |
| GET | `/api/health` | Mod status and uptime |
| GET | `/api/players` | Every connected player |
| POST | `/api/kick` | Disconnect a player |
| POST | `/api/broadcast` | Send a message to every player |
| POST | `/api/give` | Give an item to a player |
| GET | `/api/items` | List loaded items, `?search=` to filter |
| POST | `/api/ban` | Ban a player |
| POST | `/api/unban` | Remove a ban |
| GET | `/api/bans` | List bans |

### GET /api/players

Accepts `?name=`, `?characterName=`, `?netId=` and `?characterGuid=` to narrow the list.

```bash
curl -H "Authorization: Bearer TOKEN" http://localhost:8080/api/players
```

```json
{
  "count": 1,
  "players": [{
    "name": "ExamplePlayer",
    "characterName": "Adventurer",
    "playerId": 256,
    "uniqueNetId": "76561190000000000",
    "uniqueNetIdSource": "net-id-string",
    "characterGuid": "00000000000000000000000000000000",
    "platform": "WIN",
    "pingMs": 60,
    "score": 0.0,
    "startTime": 80,
    "isSpectator": false, "isBot": false, "isInactive": false,
    "spawned": true,
    "pawnClass": "BP_PlayerCharacter_C",
    "color": { "hex": "D47247FF", "r": 0.658, "g": 0.168, "b": 0.063, "a": 1.0 },
    "location": { "x": 10360.0, "y": 186410.0, "z": -3070.0 },
    "rotation": { "pitch": 0.0, "yaw": 128.2, "roll": 0.0 },
    "velocity": { "x": 0.0, "y": 0.0, "z": 0.0 },
    "movementMode": 1,
    "health":     { "current": 100.0, "max": 100.0, "canDie": true, "isDead": false },
    "sustenance": { "current": 72.0, "max": 100.0 },
    "hydration":  { "current": 65.0, "max": 100.0 },
    "endurance":  { "current": 99.4, "max": null, "source": "component" },
    "attributes": [{ "name": "Health", "value": 100.0, "baseValue": 100.0, "shared": false }],
    "skills":     [{ "skill": "SKILL_Woodcutting", "currentXP": 4210 }],
    "pointers": { "playerState": "0x...", "pawn": "0x...", "controller": "0x..." }
  }]
}
```

`endurance` comes from the pawn's `EnduranceComponent` (or `Endurance`/`MaxEndurance`
attributes, if a build ever adds them). The live component stores no maximum, so `max` is
`null` unless the game provides one. The whole field is `null` when nothing plausible is
read; `source` says where it came from.

Health and max health come from the character's attributes component, not from
`UHealthComponent`'s own fields - on a player those are always zero, because
`UPlayerHealthComponent` sources both from attributes.

### POST /api/kick

`player` accepts a SteamID64, player id, character GUID, character name or display name.
They are matched in that order, most stable first.

```
curl -X POST http://localhost:8080/api/kick -H "Authorization: Bearer TOKEN" -H "Content-Type: application/json" -d "{\"player\":\"76561190000000000\",\"reason\":\"Kicked by an administrator\"}"
```

A kick holds until the server restarts. The kicked player is remembered and removed again
if they reconnect.

### POST /api/broadcast

Sends a line to every connected player's chat box.

```
curl -X POST http://localhost:8080/api/broadcast -H "Authorization: Bearer TOKEN" -H "Content-Type: application/json" -d "{\"message\":\"Restarting in 5 minutes\"}"
```

`sender` is optional and defaults to `Server`, giving `[Server] Restarting in 5 minutes`.

The game has no server identity in chat, so a broadcast is delivered under the receiving
player's own name. Everyone sees the `[Server]` prefix, but it appears as though they sent
it themselves.

The response reports how many players the message was *dispatched* to. Chat messages are
client RPCs, so the server never learns whether a client actually displayed one.

Each player's `PlayerChatComponent` is located at runtime and validated by class before every
use, so a game patch that moves it costs one rediscovery (logged) instead of silently sending
messages to the wrong component.

### POST /api/give

```
curl -X POST http://localhost:8080/api/give -H "Authorization: Bearer TOKEN" -H "Content-Type: application/json" -d "{\"player\":\"76561190000000000\",\"item\":\"IronBar\",\"count\":10}"
```

`item` matches the full asset name (`ITEM_Resources_IronBar`), the name without the `ITEM_`
prefix, or a unique partial like `ironbar`. Only items currently loaded on the server can be
given; `GET /api/items` shows what is available right now. `count` defaults to 1.

### POST /api/ban

```
curl -X POST http://localhost:8080/api/ban -H "Authorization: Bearer TOKEN" -H "Content-Type: application/json" -d "{\"player\":\"76561190000000000\",\"reason\":\"Griefing\"}"
```

Kicks the player if online and adds them to `bans.json`. They are removed again whenever
they reconnect. Offline players can be banned by SteamID64. `POST /api/unban` takes the
same `player` field.

### GET /api/health

Deliberately minimal, because authentication can be turned off and this therefore has to be
safe to serve to anyone. No ports, no owner id, no server GUID, no memory addresses.

```json
{"status":"healthy","version":"0.1.0","uptimeSeconds":41.2,"engineReady":true}
```

`status` is `starting` until the world has loaded. Engine discovery detail goes to the log
at startup and to the authenticated RCON `status` command.

## Web panel

[`web/index.html`](web/index.html) is a single-file admin panel for the REST API, with no
build step and no external requests. Open it straight from disk, or host it anywhere, then
enter the API address and bearer token.

- **Players** - live table with health, sustenance, hydration and endurance, looked up
  again every 3 minutes by default (30s to 5m, or off). Click a row for position, skills,
  attributes and the raw JSON. Kick, ban and give from each row.
- **Broadcast** - message with an optional sender prefix and a preview.
- **Give items** - pick an online player and a loaded item from selectors, or search the
  item list and click one.
- **Bans** - ban online players or offline SteamID64s, and unban.

The API already sends `Access-Control-Allow-Origin: *`, so the panel works from any origin.
A panel served over `https` cannot call an `http` API (browsers block mixed content), so
either open it from disk, or put the API behind HTTPS as below. The token is only kept in
the browser's local storage when "Remember token" is ticked.

### Docker

The panel is published as `ghcr.io/cobratrinity/rsdw-panel`, a small nginx image. Point
it at the game server's API and it proxies `/api/` there, so the panel and the API share
one address:

```bash
docker run -d --name rsdw-panel --restart unless-stopped -p 8081:80 \
  -e RSDW_API_UPSTREAM=http://192.168.1.50:8080 \
  ghcr.io/cobratrinity/rsdw-panel:latest
```

Open `http://<host>:8081`; the API address is already filled in, so only the bearer
token is needed. [`web/docker-compose.yml`](web/docker-compose.yml) does the same with
Compose, and `docker build -t rsdw-panel web` builds it from a checkout.

| Variable | Effect |
|----------|--------|
| `RSDW_API_UPSTREAM` | Game server API to proxy `/api/` to. The panel defaults to its own address. |
| `RSDW_API_URL` | Without an upstream, the API address the panel is pre-filled with. |

Both must be plain `http(s)://` URLs; anything else stops the container with an error
rather than being written into the nginx config. The container starts even while the game
server is down, and `/healthz` backs the image's health check. The token is never part of
the image or its environment: each person enters it in their own browser.

Images are built by [`.github/workflows/panel-image.yml`](.github/workflows/panel-image.yml)
on every push to `main` that touches `web/` (`:latest`) and on `v*` tags (`:1.2.3`), for
amd64 and arm64.

### HTTPS with Nginx Proxy Manager

The mod speaks plain HTTP. To reach it over HTTPS, put a reverse proxy such as
[Nginx Proxy Manager](https://nginxproxymanager.com/) in front of it.

With the Docker image above, forward one host (`panel.example.com`) to the container's
port (`8081`) and request a certificate as in step 3: the panel and the API are then both
on HTTPS. The whitelist advice below still applies, with the panel container as the
address to allow. Without the container, proxy the API itself:

1. Point a DNS name (`api.example.com`) at the proxy's public IP.
2. **Hosts → Proxy Hosts → Add Proxy Host**:
   - *Domain Names*: `api.example.com`
   - *Scheme*: `http`, *Forward Hostname / IP*: the game server's address, *Forward Port*:
     the API port (`8080`)
   - Turn on *Block Common Exploits*. Websockets are not needed.
3. **SSL** tab: *Request a new SSL Certificate*, and turn on *Force SSL* and *HTTP/2
   Support*.
4. In the panel, use `https://api.example.com` as the API address.

No extra headers are needed. Nginx forwards `Authorization` by default, the mod answers
CORS preflight itself, and every response already carries the CORS headers.

Then close the plain HTTP route, or the token can still be sniffed on it:

- Set `[API] IPWhitelist` to the proxy's address, so only the proxy can reach the API. If
  the proxy runs in Docker on the same host, the mod sees a Docker bridge address rather
  than the host's public IP. With `VerboseLogging=true`, rejected addresses are logged as
  `HTTP: rejected <ip> (not whitelisted)`, which tells you what to allow.
- Or bind the API to `127.0.0.1` when the proxy runs on the same host outside Docker, or
  firewall the API port from the internet.

Behind a proxy the whitelist only ever sees the proxy, so restrict who can reach the
proxy host itself if you need per-client IP limits (NPM's *Access Lists*).

## RCON

Standard Valve Source RCON, so `mcrcon`, `rcon-cli` and panel consoles all work. Off by
default.

```bash
mcrcon -H 127.0.0.1 -P 27020 -p PASSWORD players
```

| Command | Description |
|---------|-------------|
| `help` | List commands |
| `health` | Mod and engine readiness in one line |
| `status` | Server identity, world and engine discovery |
| `players [json]` | Player table, or the API payload |
| `playercount` | Number of connected players |
| `player <name>` | Everything known about one player, as JSON |
| `kick <player> [reason]` | Disconnect a player |
| `broadcast <message>` | Send a message to every player |
| `give <player> <item> [count]` | Give an item to a player |
| `items [search]` | List loaded items |
| `ban <player> [reason]` | Ban a player, offline players by SteamID64 |
| `unban <player or SteamID64>` | Remove a ban |
| `bans` | List bans |

## In-game commands

Admins can run these from chat. Admin status comes from the game's own owner and admin
list, so anyone who has entered the admin password in the Server Management screen
qualifies. Replies go only to the sender, and the command line itself is never shown to
other players.

| Command | Description |
|---------|-------------|
| `/kick <player> [reason]` | Disconnect a player |
| `/ban <player> [reason]` | Ban a player |
| `/unban <player or SteamID64>` | Remove a ban |
| `/give <player> <item> [count]` | Give an item to a player |
| `/help` | List commands |

## Discord

With `[Discord]` enabled, every chat message is relayed to `WebhookUrl` as
`**Name**: message`, and player deaths are posted to `DeathWebhookUrl` as
`:skull: **Name** died at x, y, z`. Leave `DeathWebhookUrl` empty to send both to the same
channel.
Messages are batched and sent at most once per second, so a busy server stays inside
Discord's rate limits.

Rate limiting is a per-address token bucket: `CommandsPerMinute` is the sustained rate,
`CommandBurst` is how much can be spent at once. Separately, `MaxFailedAuth` failed logins
inside `FailWindowSeconds` refuse that address for `BanSeconds`, enforced at `accept`
before the password is read.

## SDK

The engine layer is driven by a Dumper-7 dump of the server binary, which is not included
in this repository. Generate your own and place it at `RSDWSDK/`. Every offset the mod uses
carries a `// Source:` comment naming the file it came from, so they can be re-verified
against a fresh dump after a game patch.

Upstream Dumper-7 is Windows only; the Linux server can be dumped with a Linux build of it
(`LD_PRELOAD`, see its `UsingLinux.md`). After a patch, check every offset in one go:

```bash
python3 tools/check_offsets.py RSDWSDK
```

It prints `OK`/`MISMATCH` per constant and exits non-zero if anything moved. If the global
offsets (`GObjects`, `GNames`, `GWorld`) are stale the mod still finds them by scanning, just
more slowly; the mod log then says `(segment scan)` instead of `(SDK offset)`.

`UObject::ProcessEvent` is not exported by the stripped shipping binary. It is looked up by name
in the `RSDragonwildsServer-Linux-Shipping.sym` file that ships with the server, then at the
SDK offset (only if `UObject`'s vtable holds that address at the dumped slot). Kick, give and
broadcast are then available at startup. If both fail, it is derived from the stack once the
first player connects.

## License

Released under the MIT License. See [LICENSE](LICENSE) for the full text.

This software is provided as is, without warranty of any kind. Use it at your own risk.

If you use this code in your own project, please provide credit and keep a link back to
this repository.
