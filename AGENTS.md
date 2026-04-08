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
Current project version: `0.4.1`

Version file:
- the parent repository root contains `VERSION`
- `VERSION` must contain exactly one semantic version string in `major.minor.patch` format

Versioning policy:
- increase `major` only for breaking changes
- increase `minor` for non-breaking features and bug fixes
- reset `patch` to `0` when `minor` increases
- reset both `minor` and `patch` to `0` when `major` increases
- increase `patch` for non-functional changes only, such as documentation updates, formatting-only changes, test-only changes, packaging metadata changes, and similar work

Agent directive:
- treat `VERSION` as the canonical project version for the whole repository
- when making changes, decide whether they require a version bump under the policy above
- if the work changes the effective project version, update `VERSION` in the same work whenever feasible
- do not change `major`, `minor`, or `patch` outside this policy
- keep documentation, code references, and packaging metadata aligned with `VERSION`

## Compatibility Debt Policy

When a user-facing or operator-facing behavior should eventually change in a breaking way, but the current work keeps backward compatibility for now:
- keep a clear written record of that deferred breaking cleanup in this file
- describe what compatibility code, aliases, legacy flags, shims, fallback behavior, or transitional paths should be removed later
- note why the cleanup is deferred and what future breaking change should absorb it

Agent directive:
- if you intentionally keep compatibility code only to avoid a breaking change in the current release line, record that deferred removal here in the same work whenever feasible
- do not silently leave transitional compatibility behavior undocumented
- when the next real breaking release happens and `major` is increased, review the recorded deferred compatibility items and remove the obsolete compatibility code as part of that breaking-change work
- when such compatibility code is removed in a major release, update this file to clear or revise the corresponding deferred record

Current deferred compatibility items:
- `scripts/refresh-blacklist.sh` accepts `--repo` as a backward-compatible alias for `--copy`
  This alias exists only to preserve the previously introduced flag spelling without forcing an immediate breaking change.
  Remove the `--repo` alias when the next real major-version breaking change is made.

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
- implemented as an opt-in profile: Compose-native SOCKS5 proxy module based on 3proxy
- implemented as a host-side module: blacklist inspection, backend auto-detection, apply, and verify flows for Docker egress filtering
- partially prepared: Compose project layout, helper scripts, reserved volumes for future protocol services
- not yet implemented as Compose services: WireGuard, AWG, Xray, OpenVPN, IPsec, and other VPN containers

As of the current repo state:
- `compose.yaml` defines one default service: `dns`
- `compose.yaml` also contains an opt-in `socks5proxy` profile-backed service
- the top-level `dns/` directory contains the actual service Dockerfile and Unbound configuration
- the top-level `socks5proxy/` directory contains the 3proxy-based SOCKS5 module
- the top-level `blacklist/` directory contains a host-side blacklist module, config, category source files, CLI entrypoint, and systemd unit templates
- `scripts/` contains helper scripts for Docker Compose plugin installation, Docker IPv6 enablement, and blacklist install/uninstall wrappers
  There is also a refresh wrapper for operators who edit blacklist source files and want to reapply rules immediately.
  By default the refresh wrapper targets the installed blacklist config under `/etc/obscura-blacklist`; with `--copy` it first copies repo blacklist source files into `/etc/obscura-blacklist/sources`, then runs the normal installed refresh.
  The blacklist install wrapper also performs systemd/Docker preflight checks, then a post-install `check` and immediate refresh; the uninstall wrapper disables/stops the blacklist units, waits for them to go inactive, then flushes live state before removing systemd integration.
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

- Dual-stack by default:
  Current and future modules should support both IPv4 and IPv6 whenever the Docker daemon and Compose networks have IPv6 enabled.
  Do not hardcode IPv4-only listener addresses or upstream resolver addresses unless there is a protocol-specific reason.

## Current Architecture

### Top-Level Compose Model

Top-level files:
- `compose.yaml`
- `compose.amnezia.yaml`

Current Compose resources:
- service: `dns`
- opt-in profile service: `socks5proxy`
- volumes reserved for future use: `awg-data`, `xray-data`
- service data volume: `socks5proxy-data`
- networks:
  - internal network `obscura-dns`
  - optional external compatibility network `amnezia-dns-net` provided only by `compose.amnezia.yaml`
  - optional Amnezia-compatible SOCKS5 overlay behavior in `compose.amnezia.yaml` using `/srv/amnezia/socks5proxy/conf`

Current non-Compose host-side modules:
- optional blacklist module in `blacklist/`

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
- dual-stack public upstream forwarding over IPv4 and IPv6
- Emercoin-related stub zones
- Docker-friendly stdout/stderr logging
- no host port exposure by default

### SOCKS5 Proxy

Implemented module:
- 3proxy-based SOCKS5 service

Files:
- `socks5proxy/Dockerfile`
- `socks5proxy/3proxy.base.cfg`
- `socks5proxy/entrypoint.sh`

Current design:
- static baseline config is baked into the image
- runtime entrypoint renders the effective `3proxy.cfg`
- dynamic state can come from an Obscura-managed state directory or an Amnezia-compatible mounted config file
- default state volume in Compose: `socks5proxy-data`
- default state path in the container: `/var/lib/obscura/socks5proxy`
- base Obscura mode uses a fixed internal listener port `1080`
- base Obscura mode also defaults to publishing host port `1080`
- `compose.amnezia.yaml` enables Amnezia mode by mounting `/srv/amnezia/socks5proxy/conf` read-only and setting `SOCKS5_COMPAT_CONFIG=/compat/3proxy.cfg`
- Amnezia mode shares only SOCKS5 credentials with the externalized Amnezia config; it does not follow the Amnezia listen port

Current runtime behavior:
- the image keeps the upstream 3proxy startup path instead of replacing it with a dummy long-running shell
- the generated config is written to `/usr/local/3proxy/conf/3proxy.cfg`
- the base 3proxy image then starts with `/etc/3proxy/3proxy.cfg`, preserving the upstream safe-chroot model
- logs are configured for stdout rather than an internal log file
- DNS resolution is rendered dynamically and defaults to Obscura's internal DNS service over both IPv4 and IPv6 (`172.30.153.53`, `fd30:153::53`) rather than hardcoded public resolvers
- the default listen address is `::` so the service can accept both IPv4 and IPv6 connections when the network stack is configured for dual-stack operation
- outbound source binding can be set explicitly with `SOCKS5_EXTERNAL_ADDR` as a simple fallback, or more precisely with the advanced per-family overrides `SOCKS5_EXTERNAL_ADDR_V4` and `SOCKS5_EXTERNAL_ADDR_V6`; if either family-specific variable is set, it takes precedence over the generic fallback
- in Obscura mode the container always listens on `1080/tcp`; host publishing is the only port customization point
- in Amnezia mode the container still listens on `1080/tcp`; only proxy credentials are imported from the externalized Amnezia config
- outbound address-family selection is explicit via `SOCKS5_RESOLVE_MODE`; default is `prefer_ipv6`, which renders 3proxy's `-64` flag
- the host-side validation helper `scripts/test-socks5proxy-host.sh` now separates raw SOCKS auth checks, raw SOCKS CONNECT checks, and HTTP-over-SOCKS checks so ingress/auth failures are not conflated with upstream egress failures
- live validation confirmed that `prefer_ipv6` causes 3proxy to use IPv6 upstream addresses when AAAA records are available and container IPv6 egress is healthy
- if no users are present and anonymous mode is not explicitly allowed, the Obscura-mode entrypoint bootstraps a managed single-user config into the state directory
- the service now has a local Docker health check that verifies the rendered config exists, PID 1 is alive, and the expected TCP listener is present in `/proc/net/tcp` or `/proc/net/tcp6`

Compatibility model:
- Obscura-managed mode:
  - use `socks5proxy-data` or a bind-mounted host directory as the canonical state source
  - internal SOCKS5 listener port is fixed at `1080`
  - dynamic files can include `users.list`, `username`, `password`, `auth_type`, and `extra.cfg`

- Amnezia-compatible mode:
  - enabled through `compose.amnezia.yaml`
  - mount `/srv/amnezia/socks5proxy/conf` read-only at `/compat`
  - point `SOCKS5_COMPAT_CONFIG` to `/compat/3proxy.cfg`
  - the entrypoint imports only the proxy users/passwords from the Amnezia `users ...` line
  - the Obscura listener port remains `1080` and the published host port remains operator-controlled
  - this mode is intended for side-by-side operation where `obscura-socks5proxy` extends rather than replaces `amnezia-socks5proxy`

Multi-user support:
- supported in Obscura-managed mode through `users.list`
- not part of the current Amnezia UI model, which manages only one username/password pair

Important limitation:
- in Docker bridge mode, published host ports are static at container creation time
- therefore, if an external Amnezia-managed config changes the SOCKS5 listen port, Obscura cannot follow that host-port change automatically without recreating the service or switching to host networking
- for full compatibility with live Amnezia-managed port changes, host networking is the cleanest option on Linux

### Networking

Current internal network:
- name: `obscura-dns`
- IPv4 subnet: `172.30.153.0/26`
- IPv6 subnet: `fd30:153::/64`

Current optional external compatibility network:
- name: `amnezia-dns-net`
- IPv4 subnet expected by current code: `172.29.172.0/24`
- attached only when `compose.amnezia.yaml` is used

Current DNS container addresses:
- internal IPv4: `172.30.153.53`
- internal IPv6: `fd30:153::53`
- compatibility IPv4 on `amnezia-dns-net`: `172.29.172.153`

Important:
- treat the code as authoritative unless and until it is intentionally changed

### Blacklist Module

Implemented module status:
- implemented host-side CLI with real `check`, `status`, `apply`, `refresh`, `verify`, `flush`, `install-systemd`, and `uninstall-systemd` commands
- remaining planned work includes operational hardening

Purpose:
- optional host-side egress filtering for Docker container traffic
- driven by declarative domain and ASN category files under `blacklist/config/sources`
- intended to block container destinations by generating kernel firewall objects rather than per-domain application logic

Current backend model:
- backend auto-detection with explicit override support
- `iptables` backend requires `iptables`, `ip6tables`, and `ipset`
- `nftables` backend requires `nft`
- scripts must stop with a clear error if Docker is unavailable
- scripts must not assume either firewall stack is installed
- frontend family and implementation variant are tracked separately
- `iptables` in `nf_tables` compatibility mode is still treated as the `iptables` backend
- auto-detection prefers live Docker firewall evidence over raw binary presence
- if Docker evidence strongly points to one frontend but that backend is unusable, commands should fail rather than silently switching

Current enforcement model:
- dual-stack first: maintain separate IPv4 and IPv6 objects and rules
- wildcard domain entries are ignored with a warning; only concrete hostnames are resolved
- domain lists resolve to A and AAAA answers
- if `BLACKLIST_RESOLVER` is set, domain lookups use that explicit DNS server list instead of the host system resolver
- ASN lists expand to IPv4 and IPv6 prefixes via a cached HTTPS lookup against RIPE Stat
- generated targets inside well-known local/private ranges are ignored with a warning so internal routing is not blacklisted by mistake
- `iptables` backend maps per-category sets to `DOCKER-USER` rules in both `iptables` and `ip6tables`
- generated blacklist rules are ordered with domain-derived categories before ASN-derived categories so broader ASN matches do not hide more specific domain hits in rule statistics
- for the `iptables` backend, `DOCKER-USER` is normalized so the first rule is `RELATED,ESTABLISHED` accept and the last rule is `RETURN`
- `nftables` backend maps per-category sets to rules in a dedicated Obscura-managed forward-hook table/chain
- successful apply writes a persisted manifest under the configured state directory
- successful apply/refresh also write `last_good_targets.json` and `health.json` under the configured state directory
- refresh re-runs the same safe update pipeline as apply and is intended to be the timer-oriented maintenance entrypoint
- the installed systemd service is enabled for boot and Docker starts so rules are restored as early as practical after system or Docker restart; the timer is only low-frequency maintenance
- refresh/apply can reuse per-category last-known-good targets when fresh resolution produces no usable targets and the cached target set still matches the current source contents and freshness policy
- verify compares live firewall state against the last successful persisted manifest
- flush removes only Obscura-managed backend state and clears the persisted manifest, last-known-good target cache, and health state when present
- apply emits stage-by-stage trace output so long resolution or backend updates are visible
- apply refuses to replace a previously populated managed set with an empty one when source entries still exist and resolution produced no usable targets
- install-systemd installs the launcher under `/usr/local/bin`, the Python package under `/usr/local/libexec/obscura-blacklist`, default config under `/etc/obscura-blacklist`, enables the service for boot and Docker starts, and enables the timer unit
- uninstall-systemd removes only the installed systemd integration; it does not purge config, cache, state, launcher, or Python package files
- persistence and periodic refresh should eventually be handled by `systemd`

Current module layout:
- `blacklist/bin/obscura-blacklist`
- `blacklist/libexec/obscura_blacklist/`
- `blacklist/systemd/`
- `blacklist/config/blacklist.conf`
- `blacklist/config/sources/`

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
- New services should bind on dual-stack listener addresses where the underlying software supports it
- New services should prefer Obscura's internal dual-stack DNS endpoints instead of bypassing them with hardcoded public resolvers

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
- `VERSION`
  Canonical project version string in `Major.Minor.Patch` format.

- `compose.yaml`
  Current Compose definition for Obscura resources.

- `dns/`
  Real implemented DNS service.

- `socks5proxy/`
  Compose-native SOCKS5 module with a baked baseline config and a runtime config renderer.

- `blacklist/`
  Host-side blacklist module with operator documentation, config, category source lists, Python implementation, CLI entrypoint, and systemd unit templates.

- `scripts/`
  Host-side helper scripts for setup tasks.

- `amnezia-client/`
  Upstream reference implementation and compatibility source material.

Important current files:
- `compose.yaml`
- `dns/Dockerfile`
- `dns/unbound.conf`
- `dns/forward-records.conf`
- `socks5proxy/Dockerfile`
- `socks5proxy/3proxy.base.cfg`
- `socks5proxy/entrypoint.sh`
- `blacklist/config/blacklist.conf`
- `blacklist/bin/obscura-blacklist`
- `blacklist/systemd/obscura-blacklist.service`
- `blacklist/systemd/obscura-blacklist.timer`
- `scripts/enable-docker-ipv6.sh`
- `scripts/install-blacklist.sh`
- `scripts/refresh-blacklist.sh`
- `scripts/uninstall-blacklist.sh`
- `scripts/install-docker-compose-plugin.sh`
- `scripts/externalize-amnezia-socks5proxy.sh`
- `scripts/test-socks5proxy-host.sh`

Important upstream reference files:
- `amnezia-client/client/core/controllers/serverController.cpp`
- `amnezia-client/client/core/scripts_registry.cpp`
- `amnezia-client/client/server_scripts/prepare_host.sh`
- `amnezia-client/client/server_scripts/*`

## Known Constraints And Gaps

- Only DNS is implemented as a top-level Compose service.
- The base `compose.yaml` is standalone and does not require `amnezia-dns-net`.
- Side-by-side compatibility with vanilla Amnezia now lives in `compose.amnezia.yaml`, which requires the external network `amnezia-dns-net` to exist.
- `compose.yaml` already reserves some future volumes, but they are not yet attached to working services.
- The `socks5proxy` module exists as an opt-in service. Live validation has confirmed external IPv4 ingress, external IPv6 ingress, and IPv6-preferred upstream egress with `SOCKS5_RESOLVE_MODE=prefer_ipv6`.
- The current Unbound config includes `a-records.conf` and `srv-records.conf`.
  Those files are not present in this repo's `dns/` directory.
  If the base image behavior changes, this assumption may need to be revisited.
- There is not yet a documented persistence model for protocol state equivalent to upstream `/opt/amnezia/...`.
- There is not yet a compatibility layer for importing existing Amnezia-managed protocol data.
- The SOCKS5 module currently has two state models:
  - structured Obscura-managed state in a volume or bind mount
  - parsed compatibility input from an Amnezia-generated `3proxy.cfg`
  This split is intentional for now but may be worth unifying later.
- Full automatic compatibility with Amnezia-driven SOCKS5 port changes is not possible in normal bridge mode because Compose port publishing is static.
- The SOCKS5 module now supports configurable outbound family preference. `prefer_ipv6` has been live-validated; the remaining modes (`auto`, `ipv6_only`, `prefer_ipv4`, `ipv4_only`) are still worth validating explicitly.
- The blacklist module must treat Docker presence as mandatory, but it must not assume that either `iptables`/`ipset` or `nft` is installed.
- Wildcard domain entries in blacklist source files are intentionally ignored with a warning rather than expanded heuristically.
- The blacklist module supports an explicit `BLACKLIST_RESOLVER` override as a list of DNS server IP literals; if unset it still uses the host system resolver.
- The blacklist module currently uses a RIPE Stat HTTPS lookup with a local cache for ASN expansion.
- The blacklist module currently requires root privileges for `apply` and `verify`.
- The blacklist module now has real `install-systemd` and `uninstall-systemd` helper commands in addition to the unit templates.

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

Near-term service work now includes:
- validate the new `socks5proxy` module against a live Amnezia-managed SOCKS5 container
- decide whether the preferred compatibility path should be:
  - bridge mode + explicit recreate on port changes
  - or Linux host networking for seamless port compatibility
- document the recommended host bind-mount layout for service state under `/srv/amnezia/...`
- use the existing one-shot SOCKS5 migration helper when converting a live Amnezia `amnezia-socks5proxy` container to host-backed `conf/` and `logs/`
- use `scripts/compose-amnezia.sh` when operating the stack with the Amnezia overlay
- prefer a Python-based resolution/render core with thin shell wrappers for install/apply flows
- keep blacklist enforcement host-side rather than forcing it into a privileged Compose service
- continue hardening blacklist refresh/restore semantics, especially around stale cache reuse and degraded-state reporting

## Documentation Rules For Future Agents

When working on this repo:
- start by reading this file and `README.md`
- verify claims against the actual code before updating docs
- keep "current implementation" separate from "planned platform"
- if you make a release-relevant change, consider whether `VERSION` should be bumped in the same work
- if you add or remove services, update both this file and `README.md`
- if you change networks, subnets, ports, or compatibility assumptions, update this file immediately
- if you introduce a new architectural decision, capture it here so future agents do not have to rediscover it

This file should remain the agent-facing source of truth.
`README.md` should remain the user-facing homepage and installation manual.
