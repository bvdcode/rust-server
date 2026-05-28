# rust-server

Docker image for running a [Rust](https://store.steampowered.com/app/252490/Rust/) dedicated server. Bundles SteamCMD, the latest server build, an optional Oxide/uMod install, and the Facepunch webrcon UI served through nginx.

Images are published to Docker Hub and GHCR on every push to `main`:

- `bvdcode/rust-server:latest`
- `ghcr.io/bvdcode/rust-server:latest`

Versioned tags follow [SemVer](https://semver.org/) (e.g. `1.2.3`, `v1.2.3`) and are produced by [GitVersion](https://gitversion.net/) from commit history.

## Quick start

```bash
docker run -d \
  --name rust \
  -p 28015:28015 -p 28015:28015/udp \
  -p 28016:28016 -p 28016:28016/udp \
  -p 28082:28082 \
  -p 8080:8080 \
  -v /data/rust:/steamcmd/rust \
  -e RUST_SERVER_NAME="My Rust Server" \
  -e RUST_RCON_PASSWORD="change-me" \
  --restart unless-stopped \
  bvdcode/rust-server:latest
```

The server installs itself into the mounted volume on first start, which can take several minutes. Webrcon is available on `http://<host>:8080/` once the container is up.

## docker-compose

```yaml
services:
  rust:
    image: bvdcode/rust-server:latest
    container_name: rust
    restart: unless-stopped
    volumes:
      - /data/rust:/steamcmd/rust
    environment:
      RUST_SERVER_NAME: "My Rust Server"
      RUST_SERVER_DESCRIPTION: "Running in Docker"
      RUST_SERVER_WORLDSIZE: "3500"
      RUST_SERVER_SEED: "12345"
      RUST_SERVER_MAXPLAYERS: "50"
      RUST_RCON_PASSWORD: "change-me"
      RUST_OXIDE_ENABLED: "1"
    ports:
      - "28015:28015"
      - "28015:28015/udp"
      - "28016:28016"
      - "28016:28016/udp"
      - "28082:28082"
      - "8080:8080"
```

A more elaborate example (custom map, weather tuning, tags) lives in [src/docker-compose.yml](src/docker-compose.yml).

## Configuration

All configuration is done via environment variables. Defaults are defined in [src/Dockerfile](src/Dockerfile).

### Server

| Variable | Default | Description |
| --- | --- | --- |
| `RUST_SERVER_NAME` | `Rust Server [DOCKER]` | Server name shown in the browser. |
| `RUST_SERVER_DESCRIPTION` | `This is a Rust server...` | Server description. |
| `RUST_SERVER_IDENTITY` | `docker` | Save folder name under `/steamcmd/rust/server/`. |
| `RUST_SERVER_PORT` | `` | Game port (defaults to `28015`). |
| `RUST_SERVER_QUERYPORT` | `` | Query port (defaults to `28016`). |
| `RUST_SERVER_SEED` | `12345` | Procedural map seed. |
| `RUST_SERVER_WORLDSIZE` | `3500` | Procedural map size. |
| `RUST_SERVER_MAXPLAYERS` | `500` | Player slot count. |
| `RUST_SERVER_SAVE_INTERVAL` | `600` | Save interval in seconds. |
| `RUST_SERVER_URL` | hub.docker URL | Server website. |
| `RUST_SERVER_BANNER_URL` | `` | Server banner image URL. |
| `RUST_SERVER_LEVELURL` | `` | Custom map URL. If set, overrides seed/worldsize. |
| `RUST_SERVER_STARTUP_ARGUMENTS` | see Dockerfile | Raw extra `RustDedicated` flags. |

### RCON

| Variable | Default | Description |
| --- | --- | --- |
| `RUST_RCON_PORT` | `28016` | RCON port. |
| `RUST_RCON_PASSWORD` | `docker` | RCON password — **change this**. |
| `RUST_RCON_WEB` | `1` | Serve the webrcon UI on port `8080`. |
| `RUST_RCON_SECURE_WEBSOCKET` | `0` | Use `wss://` in the webrcon client. |
| `RUST_APP_PORT` | `28082` | Rust+ companion app port. |

### Updates & lifecycle

| Variable | Default | Description |
| --- | --- | --- |
| `RUST_START_MODE` | `0` | `0` = update + start, `1` = update only, `2` = skip update if installed. |
| `RUST_UPDATE_BRANCH` | `public` | Steam branch (e.g. `staging`, `aux01`). |
| `RUST_UPDATE_CHECKING` | `0` | Periodic update checker with auto-restart. |
| `RUST_HEARTBEAT` | `0` | Enable heartbeat reporter. |
| `RUST_OXIDE_ENABLED` | `0` | Install Oxide/uMod. |
| `RUST_OXIDE_UPDATE_ON_BOOT` | `1` | Re-download Oxide on every boot. |

### Container

| Variable | Default | Description |
| --- | --- | --- |
| `PUID` / `PGID` | `1000` | UID/GID for the `docker` user inside the container. |
| `TZ` | `Etc/UTC` | Timezone. |
| `CHOWN_DIRS` | `/app,/steamcmd,/usr/share/nginx/html,/var/log/nginx` | Comma-separated dirs reowned to `PUID:PGID` at startup. |
| `ENABLE_PASSWORDLESS_SUDO` | `false` | Add `docker` user to sudoers (Ubuntu-based images only). |

## Ports

| Port | Protocol | Purpose |
| --- | --- | --- |
| `28015` | TCP/UDP | Game traffic |
| `28016` | TCP/UDP | RCON / query |
| `28082` | TCP | Rust+ companion app |
| `8080` | TCP | webrcon UI (nginx) |

## Volume

`/steamcmd/rust` holds the SteamCMD install of Rust, world saves, plugins, and logs. Mount it to persist data across container recreations.

## Building locally

```bash
docker build -t rust-server -f src/Dockerfile src/
```

## License

[MIT](src/LICENSE.md) © Vadim Belov
