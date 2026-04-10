# Obscura

Obscura is a Docker Compose based, Amnezia-compatible server-side deployment layer for self-hosted VPN infrastructure.

Russian version: [README.ru.md](README.ru.md)

Current project version: `0.16.0`

Obscura is not a fork of the Amnezia app.
It is a separate project that aims to make the server side easier to run and manage directly with Docker Compose.

## Main Goal

The long-term goal is to turn Amnezia-style server deployments into a Compose-native backend with:
- better Docker integration
- easier direct server management
- side-by-side compatibility with vanilla Amnezia
- durable Compose services for DNS and VPN components

In the future, that should include protocol services such as WireGuard, AWG, Xray, OpenVPN, and IPsec.

## What It Can Do Today

Today Obscura provides:
- a private DNS resolver based on Unbound
- an optional SOCKS5 proxy module based on 3proxy
- an early optional Xray profile with persistent server state, client management, migration tooling, and side-by-side Amnezia compatibility
- an optional host-side blacklist tool for blocking unwanted container egress

The full VPN stack is still planned work.
Today the project is best understood as DNS plus supporting groundwork.

## Why This Project Exists

Vanilla Amnezia is good at provisioning containers through its client UI, but its server-side workflow is largely driven by SSH scripts and one-off container actions.

Obscura moves in a different direction:
- Compose-managed services instead of ad hoc `docker run`
- clearer files, networks, and volumes
- easier command-line administration
- practical compatibility with existing Amnezia setups where useful

## Common Use Cases

- Run a private DNS resolver for containers or a VPN server host.
- Add an optional SOCKS5 proxy to the same stack.
- Run Obscura next to a vanilla Amnezia installation instead of replacing it.
- Add optional host-side blacklist rules for Docker container traffic.

## Requirements

- Linux host
- Docker Engine
- Docker Compose plugin
- root access for setup tasks

Docker IPv6 support is optional.
If IPv6 is disabled, the current services can still work over IPv4.

## Quick Start

Clone the repository:

```bash
git clone --recurse-submodules https://github.com/alloploha/amnezia-obscura-compose.git
cd amnezia-obscura-compose
```

If `docker compose` is missing on a Debian or Ubuntu based host:

```bash
sudo bash scripts/install-docker-compose.sh
```

Start the default stack:

```bash
docker compose up -d --build
docker compose ps
```

This starts the current default service set, which is the DNS resolver.

## Optional Features

Enable the SOCKS5 proxy profile:

```bash
docker compose --profile socks5proxy up -d --build
```

Enable the early Xray profile:

```bash
docker compose --profile xray up -d --build
```

This currently gives you a Compose-managed Xray service with generated persistent server state.
When used with the Amnezia overlay and an externalized `/srv/amnezia/xray`, it can reuse Amnezia-managed Xray clients and key material while keeping Obscura-specific instance settings separate.
For that side-by-side mode, the host also needs the `amnezia-dns-net` Docker network that vanilla Amnezia normally creates.
If you publish Xray on a different host port, the helper scripts export client configs with that published port automatically.

Use the Amnezia compatibility overlay:

```bash
./scripts/compose-amnezia.sh
```

Install the optional blacklist module:

```bash
sudo sh scripts/install-blacklist.sh
```

Refresh blacklist rules after editing installed source files:

```bash
sudo sh scripts/refresh-blacklist.sh
```

Remove blacklist systemd integration:

```bash
sudo sh scripts/uninstall-blacklist.sh
```

## Where To Look Next

- General technical and architecture notes: `AGENTS.md`
- Blacklist module user guide: `blacklist/README.md`
- Blacklist module technical guide: `blacklist/AGENTS.md`

If you want the current implementation details, compatibility notes, or agent-facing technical guidance, use `AGENTS.md`.
