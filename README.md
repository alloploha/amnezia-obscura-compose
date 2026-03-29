# Amnezia Obscura Compose

Obscura is a Docker Compose based, Amnezia-compatible server-side deployment layer for self-hosted VPN infrastructure.

The final goal of the project is to provide a Compose-native backend for Amnezia-style deployments:
- containerized VPN and DNS services
- better Docker integration
- easier direct server management
- side-by-side compatibility with vanilla Amnezia

Current status:
- implemented now: private DNS resolver
- planned next: Compose-managed VPN protocol services such as WireGuard, AWG, Xray, OpenVPN, and IPsec

This repository is not a fork of the Amnezia application.
It is an independent deployment/orchestration layer built around Amnezia-compatible ideas and upstream server container logic.

## Why This Project Exists

Vanilla Amnezia is very good at provisioning VPN containers through the client UI, but its server-side lifecycle is largely driven by application-managed SSH scripts and imperative `docker run` flows.

Obscura aims to provide a cleaner operator experience:
- Compose-managed services instead of ad hoc container runs
- explicit networks and volumes
- easier server administration from the command line
- compatibility with existing Amnezia assumptions where it is useful

## Current Scope

Today this repo provides a private DNS resolver for VPN-centric environments with:
- Unbound
- DNS-over-TLS upstream resolution
- dual-stack upstream forwarding over IPv4 and IPv6
- DNSSEC-aware hardening
- Emercoin stub zones
- Docker network integration
- optional compatibility attachment to `amnezia-dns-net`
- an opt-in Compose-native SOCKS5 proxy module based on 3proxy

At the moment, the base Compose project defines the DNS service plus an opt-in `socks5proxy` profile.
The broader VPN stack is the intended direction of the project, not the current implementation.

## Architecture Overview

### Resolver

- Unbound
- caching
- DNSSEC and resolver hardening
- DoT forwarding to public upstream resolvers over IPv4 and IPv6
- stub zones for Emercoin domains

Configuration lives in:
- `dns/unbound.conf`
- `dns/forward-records.conf`

### Networks

Internal Obscura DNS network:
- name: `obscura-dns`
- IPv4: `172.30.153.0/26`
- IPv6: `fd30:153::/64`

Optional Amnezia compatibility network:
- name: `amnezia-dns-net`
- IPv4 expected by current code: `172.29.172.0/24`

### DNS Container Addresses

- internal IPv4: `172.30.153.53`
- internal IPv6: `fd30:153::53`
- compatibility IPv4 on `amnezia-dns-net`: `172.29.172.153`

### Security Model

- restricted resolver ACLs
- no host exposure by default
- intended for Docker and VPN clients on known networks

## Repository Layout

- `compose.yaml`
  Main standalone Compose definition for the project.

- `compose.amnezia.yaml`
  Optional overlay that attaches the DNS service to the external `amnezia-dns-net` network used for side-by-side Amnezia compatibility.

- `dns/`
  Dockerfile and Unbound configuration for the implemented DNS resolver.

- `socks5proxy/`
  Dockerfile, entrypoint, and baseline config for the opt-in SOCKS5 proxy service.

- `scripts/`
  Helper scripts for Docker Compose plugin installation, Docker IPv6 enablement, Amnezia compatibility Compose usage, and SOCKS5 externalization.

- `amnezia-client/`
  Upstream Amnezia client submodule kept as reference/source material for protocol container scripts and compatibility work.

## Requirements

- Linux host with root access
- Docker Engine
- Docker Compose plugin
- optional: Docker IPv6 enabled for dual-stack operation

## Prepare The Host

### 1. Install Docker Compose Plugin

If Docker is already installed but `docker compose` is missing:

```bash
sudo bash scripts/install-docker-compose-plugin.sh
```

### 2. Enable Docker IPv6 (Optional)

If you want the internal IPv6 network to work:

```bash
sudo bash scripts/enable-docker-ipv6.sh --restart
```

IPv6 is optional.
If Docker IPv6 is not enabled, the DNS service can still work over IPv4.

### 3. Clone The Repository

```bash
git clone --recurse-submodules https://github.com/alloploha/amnezia-obscura-compose.git
cd amnezia-obscura-compose
```

Using `--recurse-submodules` is recommended because the repo keeps the upstream Amnezia client as a submodule for compatibility work and future protocol integration.

## Choosing A Deployment Mode

Use one of these modes:

### Mode A: Side-By-Side With Vanilla Amnezia

If you already use vanilla Amnezia on the same host, it may already have created `amnezia-dns-net`.

If not, create it manually:

```bash
docker network create \
  --driver bridge \
  --subnet=172.29.172.0/24 \
  amnezia-dns-net
```

Then start Obscura with the Amnezia overlay:

```bash
docker compose -f compose.yaml -f compose.amnezia.yaml up -d --build
```

Or use the wrapper script:

```bash
./scripts/compose-amnezia.sh
```

### Mode B: Standalone DNS Deployment

If you do not need Amnezia network compatibility, use the base file only.

## Install And Run

Start the current stack:

```bash
docker compose up -d --build
```

Verify:

```bash
docker compose ps
```

You should see the DNS service running in the `obscura` project.

## Usage

### DNS Inside Docker Networks

Use these addresses from containers or VPN services:

- `172.30.153.53`
- `fd30:153::53`
- `172.29.172.153` on `amnezia-dns-net` if that network is attached

Typical use cases:
- set the DNS server for future VPN protocol containers
- point test containers at the resolver
- integrate side-by-side with an Amnezia-managed environment

### DNS From The Host

By default, the DNS container is not exposed to the host.

If you want host access, publish port 53 in `compose.yaml`:

```yaml
services:
  dns:
    ports:
      - "53:53/udp"
      - "53:53/tcp"
```

Then query it from the host:

```bash
dig @127.0.0.1 google.com
```

## Testing

### Test From Inside The DNS Container

```bash
docker exec -it obscura-dns-1 drill @127.0.0.1 google.com
```

### Test Logs

```bash
docker logs obscura-dns-1
```

### Check Docker Networks

```bash
docker network ls
```

## Troubleshooting

### `amnezia-dns-net` Is Missing

This matters only when using `compose.amnezia.yaml`.

If the Amnezia-overlay command fails with an external network error, either:
- create `amnezia-dns-net`, or
- run the base `compose.yaml` without the Amnezia overlay

### Host Cannot Reach Container IPs

This is expected for a user-defined bridge network.
Use port publishing if you need host access.

### IPv6 Does Not Work

Check Docker IPv6 support:

```bash
docker info | grep -i ipv6
```

If needed, enable IPv6 and restart Docker:

```bash
sudo bash scripts/enable-docker-ipv6.sh --restart
```

### No DNS Response

Check:
- container status with `docker compose ps`
- logs with `docker logs obscura-dns-1`
- Docker networks with `docker network ls`
- whether the client is querying one of the allowed subnets

## Relationship To Upstream Amnezia

This repo includes the upstream `amnezia-client` repository as a submodule.
That submodule currently serves as:
- reference implementation
- source of protocol Dockerfiles
- source of protocol configuration scripts
- compatibility material for future Compose-native VPN services

The current top-level Compose stack does not yet run those protocol services.
That is the planned next stage of the project.

## Roadmap Direction

The intended path for Obscura is:
1. keep the DNS service stable
2. define persistent state and volume layout for protocol containers
3. add Compose-native services for WireGuard, AWG, Xray, and other protocols
4. preserve practical compatibility with Amnezia networking and configuration behavior
5. provide a server-side stack that advanced users can manage directly

## Contributing

Contributions should preserve two things at the same time:
- honest documentation about what is implemented now
- steady progress toward the full Compose-native Amnezia-compatible backend

If you change architecture, networking, service definitions, or compatibility assumptions, update both:
- `README.md`
- `AGENTS.md`

## License

See `LICENSE`.
