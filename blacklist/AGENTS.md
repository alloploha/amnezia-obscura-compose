## Blacklist Module

This file is the source of truth for the `blacklist/` subtree.
Future agents working on the blacklist module should start here.

## Purpose

The blacklist module is an optional, host-side egress filtering subsystem for Docker-hosted services.

Its job is to turn operator-managed source files:
- domain lists
- ASN lists

into enforced kernel firewall objects and rules that block matching outbound destinations from containers.

This module is not a Compose service.
It is intended to run on the host and manage host firewall state.

## Current Status

Current status:
- scaffolded module layout exists
- config and example source lists exist
- command contract exists
- systemd unit templates exist
- enforcement logic is not implemented yet

Do not document the module as functional until backend discovery, resolution, rendering, apply, verify, and cleanup paths really work.

## Design Constraints

- Docker is mandatory.
  All operational commands must fail clearly if Docker is unavailable.

- Firewall backend is not mandatory.
  The module must not assume `iptables`, `ip6tables`, `ipset`, or `nft` is installed.
  It must detect what is available and stop cleanly if no supported backend is usable.

- Dual-stack is required.
  All planning and implementation must treat IPv4 and IPv6 as first-class.
  Separate objects and rules should be maintained per family where the backend model requires that.

- Wildcard domain entries are not supported.
  Entries such as `*.example.com` must be ignored with a warning.
  The module should only resolve concrete hostnames.

- Category isolation matters.
  Each source file maps to one independent logical category.
  Each category should render to its own IPv4 and IPv6 filtering objects and its own enforcement rules.

- Updates should be atomic where practical.
  Rebuild temporary objects first, then swap or replace to avoid partially applied states.

- Persistence should be systemd-based.
  Boot-time apply and periodic refresh should be handled with systemd service/timer units.

## Backend Model

Supported backend families:
- `iptables`
- `nftables`

Backend selection:
- `BLACKLIST_BACKEND=auto` should detect a usable backend
- explicit override should be supported later through config or CLI
- if `iptables`/`ip6tables` are present in `nf_tables` compatibility mode, they still count as the `iptables` backend
- backend reporting should distinguish family from variant, for example:
  - family `iptables`, variant `legacy`
  - family `iptables`, variant `nf_tables`
  - family `nftables`, variant `native`
- auto-detection should prefer live Docker firewall evidence over raw binary presence
- if Docker evidence strongly points to one frontend but that backend is unusable, commands should fail with a mismatch error instead of silently selecting the other frontend

Expected tool requirements:
- `iptables` backend:
  - `iptables`
  - `ip6tables`
  - `ipset`

- `nftables` backend:
  - `nft`

If the selected backend is not fully usable, commands should fail before mutating state.

Preferred auto-detection order:
1. inspect candidate frontend binaries
2. inspect Docker firewall evidence
3. select the backend with an explicit reason and confidence level

Strong Docker evidence currently includes:
- `DOCKER-USER` present in `iptables` or `ip6tables`
- Docker-specific markers in the nftables ruleset when native nftables appears to be in use

When evidence is ambiguous:
- prefer `iptables` if it is fully usable
- otherwise use native `nftables` if available

## Enforcement Model

### iptables backend

- create separate `ipset` objects for IPv4 and IPv6 per category
- attach rules to `DOCKER-USER`
- install both `iptables` and `ip6tables` rules
- default match direction is destination-based
- `iptables-nft` is still managed as an `iptables` frontend, not as native `nftables`

### nftables backend

- create a dedicated Obscura-managed nftables table
- create a dedicated forward-hook chain in that table
- create separate IPv4 and IPv6 sets per category
- scope matching to Docker container egress interfaces
- install one or more per-category drop rules in the dedicated chain

## Resolution Model

Source file conventions:
- `domains-*.txt`: concrete hostnames, comments allowed
- `asns-*.txt`: ASNs such as `AS47764`, comments allowed

Resolution behavior:
- domains resolve to A and AAAA records
- ASNs expand to IPv4 and IPv6 prefixes
- wildcard domains are ignored with a warning
- empty lines and comments are ignored

State behavior:
- cache network-derived data in a cache directory
- keep last successful rendered manifests in a state directory
- record per-category counts for verification output

## Module Layout

Expected layout:
- `bin/obscura-blacklist`
  User-facing CLI entrypoint

- `libexec/obscura_blacklist/`
  Python implementation modules for parsing, discovery, rendering, apply, and verification

- `systemd/`
  Service and timer units for persistence and refresh

- `config/blacklist.conf`
  Default config

- `config/sources/`
  Category inputs

## Command Contract

The module CLI should own these subcommands:
- `help`
- `commands`
- `check`
- `status`
- `apply`
- `refresh`
- `verify`
- `flush`
- `print-default-config`
- `install-systemd`
- `uninstall-systemd`

Current scaffold behavior may expose the contract before enforcement logic exists.
Keep the contract stable unless there is a strong reason to change it.

## Operator Model

Expected host install locations:
- config: `/etc/obscura-blacklist`
- state: `/var/lib/obscura-blacklist`
- cache: `/var/cache/obscura-blacklist`
- executable: `/usr/local/bin/obscura-blacklist`

Expected systemd behavior:
- one oneshot service to apply/refresh rules
- one timer for periodic refresh
- service ordered after `docker.service` and `network-online.target`

## Implementation Direction

Prefer this order:
1. implement config and source parsing
2. implement backend and Docker discovery
3. implement domain resolution and ASN expansion with cache support
4. implement backend-specific renderers
5. implement atomic apply and cleanup
6. implement verification output
7. wire in systemd installation workflow

Prefer a Python core with thin shell wrappers.
Do not build the enforcement logic as a privileged Compose service unless requirements change intentionally.
