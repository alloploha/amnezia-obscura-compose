## AI Agent Guidelines

This file is the primary source of truth for the project state, direction, and architecture.
Future AI agents should start here before making changes.

Use this file as:
- the entry point for understanding the repo
- the canonical summary of current implementation vs planned implementation
- the place to record architecture decisions and important constraints as the project evolves

If you change the project in a meaningful way, update this file in the same work whenever feasible.
Do not let `README.md` or code drift away from what is documented here.

## Project Identity

Project name: Obscura

Repository purpose:
Build a Docker Compose based, Amnezia-compatible server-side deployment layer for self-hosted VPN infrastructure.

This repository is not a fork of the Amnezia application.
It is an alternative deployment/orchestration layer intended to run server components in a cleaner, more operator-friendly way while preserving practical compatibility with Amnezia.

## Final Goal

Develop Obscura into a Compose-native backend for Amnezia-style server deployments with:
- better Docker integration
- easier direct server management for advanced users
- side-by-side compatibility with vanilla Amnezia
- reuse of compatible data layouts, networks, and container behavior where practical
- support for multiple VPN protocols such as WireGuard, AWG, Xray, OpenVPN, and IPsec

The long-term target is not "just DNS".
The long-term target is a full server stack where DNS and VPN services are managed as durable Compose services rather than being created ad hoc by a GUI client over SSH.

## Current State

Current implementation status:
- implemented: private DNS resolver based on Unbound
- partially prepared: Compose project layout, helper scripts, reserved volumes for future protocol services
- not yet implemented as Compose services: WireGuard, AWG, Xray, OpenVPN, IPsec, and other VPN containers

As of the current repo state:
- `compose.yaml` defines only one active service: `dns`
- the top-level `dns/` directory contains the actual service Dockerfile and Unbound configuration
- `scripts/` contains helper scripts for Docker Compose plugin installation and Docker IPv6 enablement
- `amnezia-client/` is an upstream Git submodule used as reference/source material for protocol container scripts and compatibility work

Be precise in docs and code comments:
- current product: DNS resolver + groundwork
- target product: full Compose-native Amnezia-compatible backend

Do not describe the VPN stack as implemented unless the repo actually contains working Compose services for it.

## Clear Objectives

- Better Docker integration:
  Containerize the full server stack with shared networks, clear volume boundaries, and explicit Compose definitions.

- Easier management:
  Let operators manage the stack directly with Compose, scripts, and files rather than only through an application-driven SSH workflow.

- Compatibility:
  Preserve interoperability with Amnezia where it is useful, especially shared Docker network assumptions, config behavior, and protocol container semantics.

- Incremental delivery:
  Keep the DNS service stable while evolving toward a broader server platform.

- Honest documentation:
  Keep a hard separation between "implemented now" and "planned next".

## Design Principles

- Compose first:
  Prefer stable Compose services and volumes over imperative `docker run` flows.

- Compatibility over reinvention:
  Reuse proven behavior from upstream Amnezia scripts when it helps preserve compatibility.

- Operator clarity:
  Make networking, persistence, startup behavior, and external dependencies explicit.

- Minimal host mutation:
  Prefer containerized behavior and targeted helper scripts over broad host-level changes.

- Side-by-side operation:
  Avoid assumptions that force users to abandon vanilla Amnezia deployments.

## Current Architecture

### Top-Level Compose Model

Top-level file:
- `compose.yaml`

Current Compose resources:
- service: `dns`
- volumes reserved for future use: `awg-data`, `xray-data`
- networks:
  - internal network `obscura-dns`
  - optional external compatibility network `amnezia-dns-net`

### DNS Resolver

Implemented resolver:
- Unbound

Files:
- `dns/Dockerfile`
- `dns/unbound.conf`
- `dns/forward-records.conf`

Behavior:
- caching resolver
- DNSSEC validation and hardening
- DNS-over-TLS forwarding
- Emercoin-related stub zones
- Docker-friendly stdout/stderr logging
- no host port exposure by default

### Networking

Current internal network:
- name: `obscura-dns`
- IPv4 subnet: `172.30.153.0/26`
- IPv6 subnet: `fd30:153::/64`

Current optional external compatibility network:
- name: `amnezia-dns-net`
- IPv4 subnet expected by current code: `172.29.172.0/24`

Current DNS container addresses:
- internal IPv4: `172.30.153.53`
- internal IPv6: `fd30:153::53`
- compatibility IPv4 on `amnezia-dns-net`: `172.29.172.153`

Important:
- treat the code as authoritative unless and until it is intentionally changed

### Security Model

Current DNS security posture:
- not an open resolver by default
- access restricted by Unbound ACLs
- intended for Docker and VPN clients on known subnets
- no external exposure unless the operator publishes ports explicitly

### IPv6 Model

For dual-stack behavior:
- Docker daemon must have IPv6 enabled
- Compose network must have IPv6 enabled
- Unbound is configured to bind on `::0`

Helper script:
- `scripts/enable-docker-ipv6.sh`

If IPv6 is unavailable, the service should still be usable over IPv4.

## Relationship To Upstream Amnezia

The `amnezia-client/` directory is a Git submodule pointing to the upstream Amnezia client repository.

Its role in this repo:
- source of protocol Dockerfiles
- source of protocol config-generation scripts
- source of startup/runtime behavior for containers
- reference for compatibility assumptions

It is not the Obscura implementation itself.

### Upstream Deployment Model

Upstream Amnezia currently uses an imperative SSH-driven workflow:
1. prepare host
2. upload/build a protocol image
3. run a container with `docker run`
4. execute protocol-specific configuration scripts inside the container
5. upload/start a startup script inside the container

Relevant upstream code paths:
- `amnezia-client/client/core/controllers/serverController.cpp`
- `amnezia-client/client/core/scripts_registry.cpp`
- `amnezia-client/client/server_scripts/*`

Example protocol script families exist for:
- `wireguard`
- `awg`
- `awg_legacy`
- `xray`
- `openvpn`
- `openvpn_cloak`
- `openvpn_shadowsocks`
- `ipsec`
- plus auxiliary containers such as `dns`, `sftp`, `socks5_proxy`, `website_tor`

### Obscura Architectural Direction

Obscura should translate the upstream behavior into a Compose-native model.

That means:
- services should be defined declaratively in `compose.yaml` or split Compose files
- protocol state should live in explicit volumes instead of being implicitly created inside transient containers
- startup/config generation should become durable server-side behavior rather than one-time SSH actions from the client
- compatibility with Amnezia should be preserved where it matters, especially around network naming, protocol config formats, and expected filesystem layouts

Do not blindly copy upstream scripts into the top-level project without adapting them to the Compose model.
The key task is orchestration redesign, not just Dockerfile duplication.

## Codebase Map

Top-level areas:
- `compose.yaml`
  Current Compose definition for Obscura resources.

- `dns/`
  Real implemented DNS service.

- `scripts/`
  Host-side helper scripts for setup tasks.

- `amnezia-client/`
  Upstream reference implementation and compatibility source material.

Important current files:
- `compose.yaml`
- `dns/Dockerfile`
- `dns/unbound.conf`
- `dns/forward-records.conf`
- `scripts/enable-docker-ipv6.sh`
- `scripts/install-docker-compose-plugin.sh`

Important upstream reference files:
- `amnezia-client/client/core/controllers/serverController.cpp`
- `amnezia-client/client/core/scripts_registry.cpp`
- `amnezia-client/client/server_scripts/prepare_host.sh`
- `amnezia-client/client/server_scripts/*`

## Known Constraints And Gaps

- Only DNS is implemented as a top-level Compose service.
- The default Compose file currently references the external network `amnezia-dns-net`.
  If that network does not exist, `docker compose up` fails unless the operator removes that network block or creates the network.
- `compose.yaml` already reserves some future volumes, but they are not yet attached to working services.
- The current Unbound config includes `a-records.conf` and `srv-records.conf`.
  Those files are not present in this repo's `dns/` directory.
  If the base image behavior changes, this assumption may need to be revisited.
- There is not yet a documented persistence model for protocol state equivalent to upstream `/opt/amnezia/...`.
- There is not yet a compatibility layer for importing existing Amnezia-managed protocol data.

## Recommended Implementation Direction

When extending the project toward the final goal, prefer this order:

1. Keep DNS stable and well documented.
2. Define the target persistence model for protocol state and keys.
3. Introduce one protocol at a time as a real Compose service.
4. Reuse upstream config-generation logic where it preserves compatibility.
5. Replace imperative per-container startup with durable entrypoints and volumes.
6. Document compatibility and migration behavior as soon as it exists.

Suggested early protocol candidates:
- WireGuard
- AWG
- Xray

They already have strong upstream script coverage and align with the repo's reserved volumes and stated goals.

## Documentation Rules For Future Agents

When working on this repo:
- start by reading this file and `README.md`
- verify claims against the actual code before updating docs
- keep "current implementation" separate from "planned platform"
- if you add or remove services, update both this file and `README.md`
- if you change networks, subnets, ports, or compatibility assumptions, update this file immediately
- if you introduce a new architectural decision, capture it here so future agents do not have to rediscover it

This file should remain the agent-facing source of truth.
`README.md` should remain the user-facing homepage and installation manual.
