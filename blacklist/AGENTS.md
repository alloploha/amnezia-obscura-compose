## Blacklist Module

This file is the source of truth for the `blacklist/` subtree.
Future agents working on the blacklist module should start here.

## Documentation Policy

- `blacklist/README.md` is the main user-facing copy for this module.
- `blacklist/README.ru.md` and any other translations are dependent documents and must stay aligned with `blacklist/README.md`.
- Every time `blacklist/README.md` is modified, update all dependent translations accordingly in the same work whenever feasible, including files such as `blacklist/README.ru.md`, `blacklist/README.by.md`, and any other localized variants present in the subtree.
- Keep user-facing READMEs simple and script-oriented.
  They should describe the normal operator workflow through the top-level scripts in `scripts/`.
- Keep detailed technical behavior, backend rules, internal command contracts, and AI-helper guidance in this file, not in the READMEs.
- If `blacklist/README.md` changes meaningfully, update the translations in the same work whenever feasible.

## Version Policy

- The blacklist module uses the repository-level `VERSION` file as its canonical version source.
- `blacklist/libexec/obscura_blacklist/__init__.py` reads that version for `__version__`, so blacklist packaging and CLI-visible versioning must stay aligned with `VERSION`.
- Apply the repository versioning policy to blacklist work as well:
  - increase `major` only for breaking changes
  - increase `minor` for non-breaking features and bug fixes
  - reset `patch` to `0` when `minor` increases
  - reset both `minor` and `patch` to `0` when `major` increases
  - increase `patch` for non-functional changes only, such as documentation, formatting, testing-only changes, and similar work
- When blacklist work changes the effective project/module version under that policy, update the top-level `VERSION` file in the same work whenever feasible.
- Do not hardcode or separately track a divergent blacklist version unless the architecture is intentionally changed later.

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
- module layout exists
- config and example source lists exist
- `check`, `status`, `apply`, `refresh`, `verify`, `flush`, `install-systemd`, and `uninstall-systemd` are implemented
- systemd unit templates exist
- successful apply/refresh now persist `last_apply.json`, `last_good_targets.json`, and `health.json`
- remaining work is mostly operational hardening rather than missing commands

Do not document the module as fully complete yet.
Backend discovery, desired-state rendering, apply, refresh, verify, flush, and systemd install helpers exist, but further hardening is still pending.

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

- Empty replacement must be treated conservatively.
  If source entries still exist but resolution produces no usable targets, apply should not replace a previously populated managed set with an empty one.

- Boot-time restore should fail closed where practical.
  If fresh resolution produces no usable targets but a matching last-known-good target set exists and is still within policy, the module should reuse that cached target set instead of restoring an empty ruleset after reboot.

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
- normalize `DOCKER-USER` so the first rule is `-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT`
- normalize `DOCKER-USER` so the last rule is `-j RETURN`
- install more specific domain-derived category rules before broader ASN-derived category rules so rule hit statistics remain more accurate

### nftables backend

- create a dedicated Obscura-managed nftables table
- create a dedicated forward-hook chain in that table
- create separate IPv4 and IPv6 sets per category
- scope matching to Docker container egress interfaces
- install one or more per-category drop rules in the dedicated chain
- keep the same category ordering policy as the iptables backend: domains first, ASNs after them

## Resolution Model

Source file conventions:
- `domains-*.txt`: concrete hostnames, comments allowed
- `asns-*.txt`: ASNs such as `AS47764`, comments allowed

Resolution behavior:
- domains resolve to A and AAAA records
- if `BLACKLIST_RESOLVER` is set, domains resolve through that explicit DNS server list instead of the host system resolver
- ASNs expand to IPv4 and IPv6 prefixes through a cached RIPE Stat HTTPS lookup
- wildcard domains are ignored with a warning
- generated targets inside well-known local/private ranges are ignored with a warning
- empty lines and comments are ignored

State behavior:
- cache network-derived data in a cache directory
- keep last successful rendered manifests in a state directory
- keep a backend-independent `last_good_targets.json` file for stale restore
- keep a `health.json` file that reports whether the current applied state is fresh or degraded
- record per-category counts and target origin metadata for verification and status output

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

Current implementation state:
- implemented: `help`, `commands`, `check`, `status`, `apply`, `refresh`, `verify`, `flush`, `print-default-config`, `install-systemd`, `uninstall-systemd`

Keep the contract stable unless there is a strong reason to change it.

## Operator Model

Expected host install locations:
- config: `/etc/obscura-blacklist`
- state: `/var/lib/obscura-blacklist`
- cache: `/var/cache/obscura-blacklist`
- executable: `/usr/local/bin/obscura-blacklist`

Refresh wrapper behavior:
- `scripts/refresh-blacklist.sh` with no extra arguments refreshes the installed config at `/etc/obscura-blacklist/blacklist.conf` and the installed sources under `/etc/obscura-blacklist/sources`
- `scripts/refresh-blacklist.sh --copy` copies source files from `blacklist/config/sources` into `/etc/obscura-blacklist/sources` and then runs the normal installed refresh through `/etc/obscura-blacklist/blacklist.conf`
- `scripts/refresh-blacklist.sh --repo` remains accepted as a backward-compatible alias for `--copy`, but `--copy` is the preferred user-facing flag

Important persisted state files:
- `last_apply.json`
- `last_good_targets.json`
- `health.json`

Expected systemd behavior:
- one oneshot service to apply/refresh rules
- enable that service for boot and Docker starts so rules are restored as early as practical after restart
- one timer for low-frequency periodic refresh
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
