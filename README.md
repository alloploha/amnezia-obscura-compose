# Obscura

Obscura is a Docker Compose based server-side toolkit for self-hosted VPN infrastructure.
It is compatible with some Amnezia server layouts, but it is not a fork of the Amnezia app.

Russian version: [README.ru.md](README.ru.md)

Current project version: `0.21.1`

## What This Is

Amnezia is usually managed by its desktop or mobile client, which connects to a server and creates containers there.
Obscura is for people who want more direct control over that server side with ordinary Docker Compose commands.

In practical terms, Obscura helps you:
- run a private DNS resolver for containers and VPN-related services
- optionally run SOCKS5, AWG, and Xray services from Compose
- keep useful compatibility with existing Amnezia server data
- inspect and migrate supported Amnezia service state more safely
- add optional host-side blacklist rules for Docker container traffic

You do not need to understand all internal protocol details to try it.
You should be comfortable using a Linux shell, Docker, and `sudo`.

## What Works Today

Implemented:
- private DNS resolver based on Unbound
- optional SOCKS5 proxy
- optional AWG service
- optional Xray service
- optional host-side blacklist tool
- safe migration wrapper for supported Amnezia AWG, Xray, and SOCKS5 state

Still planned:
- Compose services for WireGuard, OpenVPN, IPsec, and other VPN protocols
- broader real-host validation across more Linux and Docker firewall setups

## Requirements

- Linux server or Linux-like Docker host
- Docker Engine
- Docker Compose plugin
- `sudo` access for setup, migration, and host-side networking tasks

IPv6 support in Docker is useful but not required for basic IPv4 operation.

## Quick Start

Clone the repository:

```bash
git clone --recurse-submodules https://github.com/alloploha/amnezia-obscura-compose.git
cd amnezia-obscura-compose
```

If `docker compose` is missing on Debian or Ubuntu:

```bash
sudo bash scripts/install-docker-compose.sh
```

Check whether the host looks ready:

```bash
bash scripts/check-host.sh
```

Start the default stack:

```bash
docker compose up -d --build
docker compose ps
```

The default stack starts the DNS resolver.

## Optional Services

Start SOCKS5:

```bash
docker compose --profile socks5proxy up -d --build
```

Start Xray:

```bash
docker compose --profile xray up -d --build
```

Start AWG:

```bash
docker compose --profile awg up -d --build
```

AWG needs `/dev/net/tun` and Docker `NET_ADMIN` support on the host.
Run `bash scripts/check-host.sh` first if you are not sure.

## Working Alongside Amnezia

Obscura can run next to an existing Amnezia installation for supported services.
For that mode, use the Amnezia Compose overlay:

```bash
./scripts/compose-amnezia.sh
```

Before migrating any live Amnezia state, inspect and snapshot it:

```bash
sudo bash scripts/obscura.sh migrate audit --service all
sudo bash scripts/obscura.sh migrate snapshot --service xray
```

Then use a dry run before a real migration:

```bash
sudo bash scripts/obscura.sh migrate migrate --service xray --target-container obscura-xray-1 --dry-run
```

The migration wrapper creates backups under `/srv/obscura/backups/amnezia-migration` by default and avoids printing key material.

## Validation

Run the default repository checks:

```bash
bash scripts/test-all.sh
```

Run Docker build checks:

```bash
bash scripts/test-all.sh --docker
```

Run extra checks when needed:

```bash
bash scripts/test-all.sh --xray-migration
bash scripts/test-all.sh --socks5-compat
bash scripts/test-all.sh --migration-workflow
```

Some checks need Docker access and may take several minutes.

## Blacklist Tool

Install the optional blacklist module:

```bash
sudo sh scripts/install-blacklist.sh
```

Refresh installed blacklist rules:

```bash
sudo sh scripts/refresh-blacklist.sh
```

Remove blacklist systemd integration:

```bash
sudo sh scripts/uninstall-blacklist.sh
```

## More Details

For deeper technical details, architecture, compatibility rules, and AI-agent guidance, read [AGENTS.md](AGENTS.md).
For blacklist-specific user documentation, read [blacklist/README.md](blacklist/README.md).
