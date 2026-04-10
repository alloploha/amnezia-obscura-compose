## AI Agent Guidelines

This file is the source of truth for the top-level project.
Future AI agents should start here before making changes.

## Documentation Policy

- `README.md` is the main user-facing document for the repository.
- English top-level docs are the primary source documents.
- `README.ru.md` is a dependent translation of `README.md` and must stay aligned with it.
- If additional localized top-level README files are added later, they are also dependent documents and must stay aligned with `README.md`.
- Every time `README.md` changes meaningfully, update `README.ru.md` and any other dependent top-level translations in the same work whenever feasible.
- `README.md` should stay compact, practical, and use-case oriented.
- `README.md` should explain what Obscura is, why it exists, what works today, and how a non-expert user can try it.
- `README.md` should not carry detailed implementation notes, internal architecture rules, compatibility debt, or agent directives.
- This file owns technical implementation notes, architecture, constraints, compatibility rules, deferred cleanup records, and AI-helper directives.
- If `README.md` or this file changes meaningfully, update the other one in the same work whenever feasible so they stay aligned.
- Do not let user-facing docs drift away from code or from the canonical repo state described here.

## Project Identity

Project name: Obscura
Current project version: `0.16.0`

Version file:
- the repository root contains `VERSION`
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

## Repository Purpose

Build a Docker Compose based, Amnezia-compatible server-side deployment layer for self-hosted VPN infrastructure.

This repository is not a fork of the Amnezia application.
It is an alternative deployment and orchestration layer intended to run server components in a cleaner, more operator-friendly way while preserving practical compatibility with Amnezia where that is useful.

## Final Goal

Develop Obscura into a Compose-native backend for Amnezia-style server deployments with:
- better Docker integration
- easier direct server management
- side-by-side compatibility with vanilla Amnezia
- reuse of compatible data layouts, networks, and container behavior where practical
- support for multiple VPN protocols such as WireGuard, AWG, Xray, OpenVPN, and IPsec

The long-term target is not only DNS.
The long-term target is a fuller server stack where DNS and VPN services are managed as durable Compose services rather than being created ad hoc by a GUI client over SSH.

## Current Status

Current implementation status:
- implemented: private DNS resolver based on Unbound
- implemented as an opt-in profile: Compose-native SOCKS5 proxy module based on 3proxy
- implemented as an early opt-in profile: Compose-native Xray module with persistent state generation, client-management helpers, migration tooling, and side-by-side shared-state compatibility
- implemented as a host-side module: blacklist inspection, backend auto-detection, apply, refresh, verify, flush, and systemd install/remove flows for Docker egress filtering
- partially prepared: helper scripts, compatibility overlays, and reserved volumes for future protocol services
- not yet implemented as Compose services: WireGuard, AWG, OpenVPN, IPsec, and other VPN containers

Be precise in docs and code comments:
- current product: DNS resolver plus groundwork
- target product: full Compose-native Amnezia-compatible backend

Do not describe the VPN stack as implemented unless the repo actually contains working Compose services for it.

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

- Honest documentation:
  Keep a hard separation between implemented behavior and planned direction.

## Current Architecture

### Top-Level Layout

Important top-level areas:
- `VERSION`
  Canonical project version string.

- `compose.yaml`
  Main standalone Compose definition.

- `compose.amnezia.yaml`
  Optional compatibility overlay for side-by-side Amnezia operation.

- `dns/`
  Implemented DNS service.

- `socks5proxy/`
  Optional Compose-native SOCKS5 module.

- `blacklist/`
  Optional host-side blacklist module with its own user-facing and agent-facing docs.

- `scripts/`
  Thin helper scripts for setup and operator workflows.

- `amnezia-client/`
  Upstream Amnezia Git submodule used as reference material for compatibility and future protocol work.

### Compose Model

Current Compose resources:
- default service: `dns`
- opt-in profile service: `socks5proxy`
- opt-in profile service: `xray`
- reserved volume for future work: `awg-data`
- current service data volume: `socks5proxy-data`
- current service data volume: `xray-data`
- internal network: `obscura-dns`
- optional external compatibility network: `amnezia-dns-net`, provided only by `compose.amnezia.yaml`

Current non-Compose host-side module:
- optional blacklist module in `blacklist/`

### DNS Resolver

Implemented resolver:
- Unbound

Files:
- `dns/Dockerfile`
- `dns/unbound.conf`
- `dns/forward-records.conf`

Current behavior:
- caching resolver
- DNSSEC validation and resolver hardening
- DNS-over-TLS forwarding
- dual-stack upstream forwarding over IPv4 and IPv6
- Emercoin-related stub zones
- Docker-friendly stdout and stderr logging
- no host port exposure by default
- intended for Docker and VPN clients on known networks rather than open internet exposure

Important current network values:
- internal network `obscura-dns`
- internal IPv4 subnet `172.30.153.0/26`
- internal IPv6 subnet `fd30:153::/64`
- DNS container IPv4 `172.30.153.53`
- DNS container IPv6 `fd30:153::53`
- compatibility IPv4 on `amnezia-dns-net`: `172.29.172.153`

Security posture:
- not an open resolver by default
- ACL-restricted to loopback, the internal Obscura subnet, and the compatibility IPv4 subnet

Known implementation quirk:
- `dns/unbound.conf` includes `a-records.conf` and `srv-records.conf`
- those files are not present in this repo
- treat this as an image-level assumption that may need revisiting if the base image behavior changes

### SOCKS5 Proxy

Implemented module:
- 3proxy-based SOCKS5 service

Files:
- `socks5proxy/Dockerfile`
- `socks5proxy/3proxy.base.cfg`
- `socks5proxy/entrypoint.sh`
- `socks5proxy/healthcheck.sh`

Current design:
- static baseline config is baked into the image
- runtime entrypoint renders the effective `3proxy.cfg`
- dynamic state can come from an Obscura-managed state directory or from an Amnezia-compatible mounted config file
- the service listens on fixed internal port `1080`
- host publishing is the operator-controlled customization point

Current runtime behavior:
- generated config is written to `/usr/local/3proxy/conf/3proxy.cfg`
- DNS defaults to Obscura's internal DNS service over both IPv4 and IPv6
- default listen address is `::` for dual-stack capable ingress
- outbound family selection is explicit through `SOCKS5_RESOLVE_MODE`
- if no users are present and anonymous mode is not explicitly allowed, Obscura mode bootstraps a managed single-user config
- the container health check verifies the rendered config exists, PID 1 is alive, and the expected TCP listener is present

Compatibility model:
- Obscura-managed mode:
  - canonical state comes from `socks5proxy-data` or an operator bind mount
  - dynamic files can include `users.list`, `username`, `password`, `auth_type`, and `extra.cfg`

- Amnezia-compatible mode:
  - enabled through `compose.amnezia.yaml`
  - mounts `/srv/amnezia/socks5proxy/conf` read-only at `/compat`
  - points `SOCKS5_COMPAT_CONFIG` at `/compat/3proxy.cfg`
  - imports only proxy credentials from the Amnezia `users ...` line
  - keeps the Obscura listener port at `1080`

Important limitation:
- in Docker bridge mode, published host ports are static at container creation time
- if an external Amnezia-managed config changes the SOCKS5 listen port, Obscura cannot follow that host-port change automatically without recreating the service or changing the networking model

### Xray Module

Implementation status:
- implemented as an early opt-in Compose profile
- current work covers image build, first-start state generation, template rendering, health checks, client-management helpers, externalize and import tooling, and live side-by-side compatibility with externalized Amnezia Xray state

Upstream Amnezia model summary:
- build an image from `client/server_scripts/xray/Dockerfile`
- run it with `docker run`, publish the selected TCP port, and connect it to `amnezia-dns-net`
- exec a one-shot configure script that generates Reality key material, short ID, bootstrap UUID, and `/opt/amnezia/xray/server.json`
- upload and launch a startup script that starts Xray and then keeps the container alive with a dummy long-running process
- add later clients by mutating `server.json` in place and restarting the container

Obscura should preserve:
- upstream-compatible Xray server config shape
- Reality key material and short ID semantics
- the operator-facing port and site-name parameters
- client template compatibility for VLESS over TCP with Reality
- practical compatibility with the `/opt/amnezia/xray` file layout where useful

Obscura should replace:
- imperative `docker run` orchestration with a Compose service
- one-shot `docker exec` mutation as the main lifecycle
- dummy keepalive PID 1 behavior
- direct rendered-config mutation as the canonical state model
- unnecessary privilege assumptions unless testing proves they are required for the actual server-side feature set

Target Compose-native design:
- service name: `xray`
- default data volume: existing reserved volume `xray-data`
- canonical state directory in the container: `/var/lib/obscura/xray`
- compatibility mirror path in the container: `/opt/amnezia/xray`
- the service should execute `xray -config ...` as PID 1 directly
- the service should use Obscura's internal DNS by default and should support dual-stack networking where Docker supports it
- the service should optionally attach to `amnezia-dns-net` through `compose.amnezia.yaml`

Current implemented files:
- `xray/Dockerfile`
- `xray/entrypoint.sh`
- `xray/server.template.json`
- `xray/client.template.json`
- `xray/healthcheck.sh`
- `scripts/externalize-amnezia-xray.sh`
- `scripts/manage-xray-clients.sh`
- `scripts/import-amnezia-xray.sh`
- `scripts/test-xray-host.sh`

Current image-build behavior:
- the Xray image uses a multi-stage Docker build
- the fetch stage downloads and unpacks the upstream Xray release artifact
- the final runtime stage copies only the `xray` binary and does not keep `curl` or `unzip`

Current implemented Compose behavior:
- the service is enabled through the `xray` Compose profile
- the service depends on `dns`
- the service listens internally on `${XRAY_LISTEN_PORT:-443}`
- the service publishes `${XRAY_PUBLISHED_PORT}:${XRAY_LISTEN_PORT}/tcp`
- the service mounts `xray-data` at `${XRAY_STATE_DIR:-/var/lib/obscura/xray}`
- standalone mode uses only the local Obscura state volume or bind mount
- `compose.amnezia.yaml` attaches the service to the optional external network `amnezia-dns-net`
- `compose.amnezia.yaml` also mounts `/srv/amnezia/xray` at `/compat/xray` and sets `XRAY_COMPAT_STATE_DIR=/compat/xray`
- the upstream-backed expected shape of `amnezia-dns-net` is:
  - driver `bridge`
  - subnet `172.29.172.0/24`
  - bridge name `amn0`
  - vanilla Amnezia DNS container address `172.29.172.254`
- the full Compose overlay path with `amnezia-dns-net` and `/srv/amnezia/xray` has now been live-validated on a Docker host

Current startup behavior:
- in standalone mode, generate bootstrap UUID if `xray_uuid.key` is absent
- in standalone mode, generate Reality short ID if `xray_short_id.key` is absent
- in standalone mode, generate Reality x25519 keypair if `xray_public.key` and `xray_private.key` are absent
- in standalone mode, create `clients.json` with one bootstrap client if it is absent
- in compatibility mode, require externalized shared Xray state under `${XRAY_COMPAT_STATE_DIR}` and fail clearly if required files are missing
- in compatibility mode, rebuild the local Obscura `clients.json` snapshot from the shared Amnezia `server.json` client list on each start
- render the persisted client template with the bootstrap client flow so server-side and exported client-side flow semantics stay aligned
- render the local Obscura `server.json` from `server.template.json`
- publish an Amnezia-style compatibility view under `/opt/amnezia/xray` where the rendered config and exported client template are local to the Obscura instance, while shared key files point at the externalized Amnezia state when compatibility mode is enabled
- export and test helpers must use the published host port, not the internal listen port, so generated client configs remain correct when operators remap the external port

Current state ownership model:
- standalone Obscura mode:
  - canonical local state lives under `${XRAY_STATE_DIR:-/var/lib/obscura/xray}`
  - canonical files are `server.json`, `clients.json`, `client.template.json`, `xray_uuid.key`, `xray_short_id.key`, `xray_public.key`, and `xray_private.key`
- Amnezia-compatible side-by-side mode:
  - shared live files under `/srv/amnezia/xray` are:
    - `server.json` only as the shared client-registry source
    - `xray_uuid.key`
    - `xray_short_id.key`
    - `xray_public.key`
    - `xray_private.key`
  - Obscura-local per-instance files under `${XRAY_STATE_DIR:-/var/lib/obscura/xray}` are:
    - `server.json` rendered with the Obscura instance's own listen address, internal listen port, log level, and site name
    - `client.template.json`
    - `clients.json` as a regenerated local snapshot derived from the shared Amnezia client list
  - this split is intentional so multiple Obscura Xray instances can share credentials and Reality key material while still differing in instance-local parameters such as port or SNI

Current health-check model:
- verify `/opt/amnezia/xray/server.json` exists
- verify PID 1 is alive
- parse the configured TCP port from the rendered config
- verify the expected listener is present in `/proc/net/tcp` or `/proc/net/tcp6`

Current host-side client-management model:
- `clients.json` is now the canonical editable client registry
- the bootstrap UUID remains tracked separately in `xray_uuid.key`
- `scripts/manage-xray-clients.sh` supports `list`, `add`, `remove`, and `export`
- `list` excludes the bootstrap client by default and can include it explicitly
- in standalone mode, `add` and `remove` update the live local `clients.json`, then restart the Xray container so the entrypoint regenerates `server.json`
- in compatibility mode, `add` and `remove` update the shared Amnezia `server.json` client list in place, then restart the Xray container so the entrypoint refreshes its local snapshot and re-renders the local `server.json`
- `export` renders a concrete client config from the persisted client template, the selected client registry entry, and the live Reality key material

Current import and migration model:
- `scripts/externalize-amnezia-xray.sh` recreates a live Amnezia-style Xray container with a host bind mount on `/opt/amnezia/xray`, making the Amnezia container effectively stateless and exposing its durable state under `/srv/amnezia/xray` by default
- the externalize helper also preserves existing non-Xray bind mounts such as a mounted `/opt/amnezia/start.sh`, so test and sidecar entrypoint patterns survive the recreation
- `scripts/import-amnezia-xray.sh` can import from a running Amnezia-style Xray container or from an already externalized host directory
- the import helper normalizes the upstream `server.json` client list into Obscura `clients.json`
- the import helper preserves Reality keys, short ID, bootstrap UUID, and the imported `server.json`
- the import helper writes `import-metadata.json` with the imported server port, site name, listen address, log level, and bootstrap client id
- with `--apply-live`, the helper can push the imported state into the running Obscura Xray container and restart it
- live apply intentionally refuses to proceed if the imported port or site name does not match the running Obscura Xray service settings, because the current entrypoint still renders `server.json` from Compose environment and state rather than treating imported `server.json` as the long-term editable source
- the preferred side-by-side migration path is now:
  1. externalize the vanilla Amnezia Xray container to `/srv/amnezia/xray`
  2. let Obscura mount or import that host-backed state
- this split mirrors the existing SOCKS5 compatibility strategy more closely than direct container-only imports

Current limitations:
- the current client registry stores only `id` and `flow`; richer per-client metadata such as names, notes, or enabled flags is not implemented yet
- the image still downloads Xray from upstream release artifacts during `docker build`, but now does so in a builder stage rather than the final runtime image
- the current host-side validation script exercises the bootstrap client path by rendering a temporary client config and probing a known web site through a temporary host-networked Xray client container
- imported live apply currently requires the running Obscura Xray `XRAY_PUBLISHED_PORT` and `XRAY_SITE_NAME` to already match the imported Amnezia state; the helper does not rewrite Compose configuration automatically
- the externalize helper preserves the Amnezia container image, published ports, restart policy, log settings, environment, `--privileged`, `--cap-add`, and existing non-Xray bind mounts
- compatibility mode intentionally does not share the Amnezia `server.json` wholesale as the runtime config, because that file also contains per-container settings such as port, listen address, and fake site name that should be allowed to diverge across multiple Obscura Xray instances

Canonical server-side state to persist:
- rendered server config: `server.json`
- Reality public key
- Reality private key
- Reality short ID
- bootstrap UUID for the first generated client
- structured Obscura-managed client registry, for example `clients.json` or `clients.d/`
- structured server settings such as selected listen port and fake site name if those are not kept only in Compose environment

Recommended file and module layout:
- `xray/Dockerfile`
- `xray/entrypoint.sh` or a small renderer such as `xray/render.py`
- `xray/server.template.json`
- `xray/client.template.json`
- `xray/healthcheck.sh`
- optional thin helper scripts or a small Python management tool for client add, remove, and export flows

Runtime rendering model:
- on first start, generate Reality x25519 keypair, short ID, and bootstrap UUID if they are absent
- store generated values in the canonical state directory
- render `server.json` from templates and structured state on each start
- maintain `/opt/amnezia/xray` as the effective compatibility view of the same durable state, either directly or through symlinks
- validate the rendered config before starting Xray when practical

Client management model:
- Obscura should not treat rendered `server.json` as the canonical editable source of truth
- Obscura should keep a structured client registry and derive the Xray `clients` array from it
- exported client configs should still match the upstream client template semantics expected by Amnezia's Xray client path
- the bootstrap UUID should be tracked explicitly so it can be excluded from operator-facing client lists where appropriate, matching upstream behavior

Mode model:
- Obscura-managed mode:
  - canonical state lives in `xray-data` or an explicit operator bind mount
  - Obscura owns template rendering, key generation, and client registry management

- Amnezia-compatible mode:
  - preferred compatibility target is an externalized host-backed Xray state directory, for example under `/srv/amnezia/xray`
  - Obscura mounts that shared state read-write at `/compat/xray`
  - Obscura treats the shared key files and the shared `server.json` client list as the live compatibility source
  - Obscura keeps each instance's rendered runtime `server.json` and exported `client.template.json` local
  - compatibility focuses on shared credentials and key material, not on reusing one whole runtime config across multiple containers

Migration direction:
- externalize state from a live Amnezia Xray container into a host directory first
- use that host-backed state as the preferred source for the follow-up import or attach workflow for the Obscura `xray` service
- do not assume a live Amnezia Xray container must remain the long-term source of truth

Operational direction:
- add a health check that verifies the rendered config exists, Xray is running, and the expected TCP listener is present
- keep logging Docker-friendly and avoid internal forever-shell patterns
- avoid `--privileged`, `NET_ADMIN`, and `/dev/net/tun` assumptions unless a verified server-side requirement appears during implementation
- prefer a stable Compose restart model over uploaded startup scripts

Tracked implementation steps:
- completed: add `xray/` module files and Compose service using the existing `xray-data` volume
- completed: implement first-start state generation for Reality keys, short ID, and bootstrap UUID
- completed: implement template-based `server.json` rendering from structured state
- completed: define a structured client registry and stop using rendered `server.json` as the primary editable source
- completed: add a client export path compatible with upstream Xray client configuration expectations
- completed: add health checks for the running `xray` service
- completed: add host-side validation tooling for the running `xray` service
- completed: add optional Amnezia overlay support for `amnezia-dns-net`
- completed: add a one-shot externalize and import helper path for existing Amnezia Xray deployments
- completed: document the recommended host bind-mount layout and migration path
- completed: add live Xray compatibility mode that mounts `/srv/amnezia/xray` and shares client and key state while keeping per-instance rendered config local
- completed: split Xray internal listen port from published host port and make client export paths use the published port

### Blacklist Module

The blacklist module is the strongest current example of the project's intended implementation style.
It is a host-side subsystem, not a Compose service.

Purpose:
- optional host-side egress filtering for Docker container traffic
- driven by declarative domain and ASN source files
- enforced through kernel firewall objects rather than per-application logic

Current status:
- implemented host-side CLI with real `check`, `status`, `apply`, `refresh`, `verify`, `flush`, `install-systemd`, and `uninstall-systemd` commands
- implemented desired-state rendering, persistence, backend-specific apply logic, verification, and systemd integration
- remaining work is mostly operational hardening

Current behavior summary:
- Docker presence is mandatory
- backend auto-detection supports `iptables` and `nftables`
- dual-stack behavior is first-class
- wildcard domains are ignored with warnings
- domains resolve to A and AAAA answers
- ASNs expand through cached RIPE Stat lookups
- private and local ranges are filtered out conservatively
- apply and refresh persist `last_apply.json`, `last_good_targets.json`, and `health.json`
- stale last-known-good targets can be reused under policy when fresh resolution fails
- verify compares live state against the last persisted manifest
- flush removes only Obscura-managed state

Operator wrappers:
- `scripts/install-blacklist.sh`
- `scripts/refresh-blacklist.sh`
- `scripts/uninstall-blacklist.sh`

For blacklist-specific details, also read:
- `blacklist/README.md`
- `blacklist/AGENTS.md`

### Scripts

Top-level scripts are intentionally thin wrappers around stable module behavior or Compose entrypoints.

Important scripts:
- `scripts/install-docker-compose.sh`
- `scripts/enable-docker-ipv6.sh`
- `scripts/compose-amnezia.sh`
- `scripts/externalize-amnezia-socks5proxy.sh`
- `scripts/test-socks5proxy-host.sh`
- blacklist install, refresh, and uninstall wrappers

The preferred pattern is:
- Python core or declarative Compose logic for real behavior
- thin shell wrappers for operator entrypoints

## Relationship To Upstream Amnezia

The `amnezia-client/` directory is a Git submodule pointing to the upstream Amnezia client repository.

Its role in this repo:
- source of protocol Dockerfiles
- source of protocol config-generation scripts
- source of startup and runtime behavior for containers
- reference for compatibility assumptions

It is not the Obscura implementation itself.

Upstream Amnezia currently uses an imperative SSH-driven deployment model.
Obscura's architectural direction is to translate that behavior into a Compose-native model with explicit services, volumes, and durable server-side state.

Do not blindly copy upstream scripts into the top-level project without adapting them to the Compose model.
The task is orchestration redesign, not only Dockerfile reuse.

## Known Constraints And Gaps

- only DNS is implemented as a default Compose service
- the base `compose.yaml` is standalone and does not require `amnezia-dns-net`
- side-by-side compatibility with vanilla Amnezia lives in `compose.amnezia.yaml`, which requires the external network `amnezia-dns-net` to exist
- `compose.yaml` already reserves some future volumes, but they are not yet attached to working services
- the `socks5proxy` module exists as an opt-in service and already supports both Obscura-managed and Amnezia-compatible config sources
- full automatic compatibility with Amnezia-driven SOCKS5 port changes is not possible in normal bridge mode because Compose port publishing is static
- `SOCKS5_RESOLVE_MODE=prefer_ipv6` has been live-validated; the remaining modes are still worth validating explicitly
- there is not yet a documented persistence model for full protocol state equivalent to upstream `/opt/amnezia/...`
- there is not yet a compatibility layer for importing existing Amnezia-managed protocol data beyond current SOCKS5 compatibility support
- the blacklist module must treat Docker presence as mandatory, but it must not assume that either `iptables` or `nft` tooling is installed
- the blacklist module supports an explicit `BLACKLIST_RESOLVER` override and cached ASN expansion through RIPE Stat
- the blacklist module currently requires root privileges for `apply`, `verify`, and `flush`

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

Near-term service work includes:
- continue validating the `socks5proxy` module against live Amnezia-managed setups
- decide whether the preferred path for tighter SOCKS5 compatibility should be bridge mode with explicit recreate on port changes or Linux host networking
- document a recommended host bind-mount layout for service state under `/srv/amnezia/...`
- implement the tracked Compose-native `xray` module plan recorded in this file
- keep blacklist enforcement host-side rather than forcing it into a privileged Compose service
- continue hardening blacklist refresh, restore, and degraded-state reporting semantics

## Documentation Rules For Future Agents

When working on this repo:
- start by reading this file and `README.md`
- verify claims against the actual code before updating docs
- keep implemented behavior separate from planned platform direction
- if you make a release-relevant change, consider whether `VERSION` should be bumped in the same work
- if you add or remove services, update both this file and `README.md`
- if you change networks, ports, state paths, or compatibility assumptions, update this file immediately
- if you introduce a new architectural decision, capture it here so future agents do not have to rediscover it
- if you change the blacklist module meaningfully, also update `blacklist/README.md` and `blacklist/AGENTS.md` as appropriate

This file should remain the agent-facing technical source of truth.
`README.md` should remain the compact user-facing entry point.
