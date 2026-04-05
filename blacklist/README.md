# Obscura Blacklist

`obscura-blacklist` is an optional host-side filtering module for Docker-hosted infrastructure.

It converts declarative source files:
- domain lists
- ASN lists

into enforced firewall objects that block matching outbound destinations from containers.

This module is not a Compose service.
It is intended to run directly on the host and manage host firewall state.

## Current Status

Current repo status:
- module layout present
- config and example source lists present
- `check`, `status`, `apply`, `refresh`, `verify`, `flush`, `install-systemd`, and `uninstall-systemd` implemented
- systemd unit templates present
- successful apply/refresh persist `last_apply.json`, `last_good_targets.json`, and `health.json`
- remaining work is mostly operational hardening

## Intended Behavior

Supported backend families:
- `iptables` with `ipset`
- native `nftables`

Backend classification rule:
- `iptables` in `nf_tables` compatibility mode is still classified as `iptables`
- the tool should report the frontend variant separately, for example `legacy` or `nf_tables`
- native `nftables` means rules are managed through the `nft` CLI and dedicated nft objects

Auto-detection policy:
- inspect both frontend families when possible
- prefer live Docker firewall evidence over raw binary presence
- treat `DOCKER-USER` in `iptables` as strong evidence for the `iptables` frontend
- if Docker evidence points to one frontend but that backend is unusable, fail with a mismatch error instead of silently switching to the other frontend
- when evidence is ambiguous, prefer fully usable `iptables` first, then native `nftables`

What gets blocked:
- destinations derived from concrete domain names
- destinations derived from ASN-owned prefixes

Where rules are installed:
- `DOCKER-USER` for the `iptables` backend
- a dedicated Obscura-managed forward chain for the `nftables` backend

iptables chain shape:
- first rule: `-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT`
- last rule: `-j RETURN`
- generated blacklist rules are ordered with domain-derived categories first and ASN-derived categories after them

Dual-stack model:
- IPv4 and IPv6 are handled separately
- each category renders separate IPv4 and IPv6 objects as required by the backend

Wildcard handling:
- wildcard domains such as `*.example.com` are ignored
- the tool should emit a warning for them

Local route safety:
- generated targets inside well-known local/private ranges are ignored with a warning
- this protects Docker bridge networks, loopback, link-local space, and private/ULA routing from accidental blacklisting

Docker requirement:
- Docker is required
- commands should fail clearly if Docker is not available

Firewall tooling requirement:
- the tool must not assume `iptables`, `ip6tables`, `ipset`, or `nft` is installed
- it should detect a usable backend and fail cleanly if none is available

## Module Layout

- `bin/obscura-blacklist`
  User-facing CLI entrypoint

- `libexec/obscura_blacklist/`
  Python implementation modules

- `config/blacklist.conf`
  Default config values

- `config/sources/`
  Per-category domain and ASN files

- `systemd/`
  Example units for boot-time apply and periodic refresh

## Command Contract

The scaffolded CLI owns these subcommands:

- `help`
  Show usage and command summary.

- `commands`
  Print the stable command list with one-line descriptions.

- `check`
  Validate local prerequisites without mutating firewall state.
  Intended checks include Docker reachability, backend candidates, Docker firewall evidence, final backend selection reason, config parsing, and source validation.

- `status`
  Report configured backend mode, backend candidates and usability, detected Docker firewall evidence, final backend selection, Docker interfaces, source categories, and last successful apply metadata.

- `apply`
  Resolve sources, render backend objects, and atomically apply the desired blacklist state.
  Current behavior also emits trace output while it resolves and updates backend state.
  It also refuses to replace a previously populated managed set with an empty one when source entries still exist and resolution produced no usable targets.
  If fresh resolution produces no usable targets but a matching last-known-good target set is available and fresh enough, it reuses that cached target set instead of failing open after reboot.

- `refresh`
  Alias for a periodic update run.
  Intended to reuse cached data where valid and refresh expired network-derived data.
  It writes degraded health state when one or more categories had to use stale last-known-good targets.

- `verify`
  Confirm that the live firewall state matches the last rendered state.

- `flush`
  Remove only Obscura-managed firewall rules and sets.
  It also removes the persisted manifest, last-known-good target cache, and health state files.

- `print-default-config`
  Print the default config file to stdout.

- `install-systemd`
  Install or print instructions for the systemd service and timer integration.

- `uninstall-systemd`
  Remove installed systemd integration owned by the module.

Implemented today:
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

## Config Model

The default config lives at [`config/blacklist.conf`](/home/alexey/amnezia-obscura-compose/blacklist/config/blacklist.conf).

Key settings:
- `BLACKLIST_BACKEND`
  `auto`, `iptables`, or `nftables`

- `BLACKLIST_TARGET`
  logical enforcement target, currently intended for Docker forward traffic

- `BLACKLIST_RULE_DIRECTION`
  default match direction, currently `dst`

- `BLACKLIST_RESOLVER`
  optional comma- or space-separated list of IPv4 and IPv6 DNS server IP literals to use for domain resolution instead of the host system resolver

- `BLACKLIST_ALLOW_STALE_RESTORE`
  allow reuse of last-known-good per-category targets when fresh resolution produces no usable targets

- `BLACKLIST_MAX_STALE_AGE`
  maximum age in seconds for reusing last-known-good targets

- `BLACKLIST_FAIL_IF_ALL_STALE`
  fail the run if every category would be restored from stale cached targets

- `BLACKLIST_STATE_DIR`
  persistent rendered-state directory

- `BLACKLIST_CACHE_DIR`
  cache directory for DNS and ASN expansion data

- `BLACKLIST_IPTABLES_CHAIN`
  iptables chain name, currently `DOCKER-USER`

- `BLACKLIST_NFT_TABLE`
  nft table name

- `BLACKLIST_NFT_CHAIN`
  nft chain name

- `BLACKLIST_SOURCES_DIR`
  source directory containing category files

## Source Files

Current source naming:
- `domains-*.txt`
- `asns-*.txt`

Rules:
- comments and blank lines are ignored
- concrete domains are accepted
- wildcard domains are ignored with a warning
- ASNs such as `AS47764` are accepted

Domain resolution:
- by default uses the host system resolver
- if `BLACKLIST_RESOLVER` is set, uses the configured DNS server list directly
- supports a comma- or space-separated list of IP literals

Current ASN expansion implementation:
- cached HTTPS lookup against RIPE Stat announced-prefix data

Each source file should map to one independent category and one pair of IPv4/IPv6 rendered objects.

## Systemd Model

The intended persistence model is:
- `obscura-blacklist.service`
  oneshot apply/refresh unit, enabled for boot and Docker starts

- `obscura-blacklist.timer`
  periodic refresh timer for twice-daily maintenance

The service should run after Docker is available and after the network is up.

Current install behavior:
- installs launcher at `/usr/local/bin/obscura-blacklist`
- installs Python package under `/usr/local/libexec/obscura-blacklist`
- installs default config at `/etc/obscura-blacklist/blacklist.conf` if it does not already exist
- installs missing default source files under `/etc/obscura-blacklist/sources`
- installs systemd units under `/etc/systemd/system`
- enables `obscura-blacklist.service` for boot and Docker starts
- enables and starts `obscura-blacklist.timer`

Current uninstall behavior:
- disables and stops the timer
- stops the service
- removes the installed unit files
- reloads systemd
- preserves installed config, cache, state, launcher, and Python package

## Persistent State

The blacklist module writes these state files under the configured state directory:

- `last_apply.json`
  audit and verification record for the last successful applied ruleset

- `last_good_targets.json`
  backend-independent last-known-good IPv4 and IPv6 targets per category

- `health.json`
  freshness/degraded state for the current applied ruleset

Stale restore rules:
- only reuse cached targets if the current category source hash still matches
- only reuse cached targets if they are within `BLACKLIST_MAX_STALE_AGE`
- log a warning when stale targets are reused
- prefer fresh resolution whenever fresh usable targets exist

## Next Steps

Implementation should proceed in this order:
1. parse config and sources
2. detect Docker and firewall backend
3. resolve domains and expand ASNs with cache support
4. render `iptables`/`ipset` or `nftables` objects
5. apply atomically
6. verify and report status
7. install systemd persistence
