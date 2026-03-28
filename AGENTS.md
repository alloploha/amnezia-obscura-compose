## Purpose

Provide a containerized DNS resolver for VPN-centric environments with:

- controlled resolution path
- encrypted upstream (DoT)
- compatibility with Docker networking and VPN tunnels

---

## Architecture

### Resolver

- Unbound
- caching + DNSSEC validation
- DoT forwarding
- stub zones for Emercoin

Config:
- unbound.conf
- forward-records.conf

---

### Networking

Two-layer model:

1. Internal DNS network
   - IPv4: 172.30.153.0/26
   - IPv6: fd30:153::/64

2. Optional external network
   - amnezia-dns (172.27.172.0/24)

Container can be attached to both.

---

### Resolution flow

Client → Unbound → (cache)

If miss:
- DoT upstream (Cloudflare / Quad9 / Google)
- or stub zones (Emercoin)

---

### Security model

- not open resolver
- restricted via access-control
- no external exposure by default

---

### Docker behavior

- user-defined bridge network
- container IPs not reachable from host by default
- requires port publishing for host access

---

### IPv6 model

- Docker daemon must enable IPv6
- Compose network must enable IPv6
- Unbound must bind to ::0

---

### Logging

- stdout/stderr (Docker-friendly)
- verbosity: low by default
- json-file driver with rotation

---

### Failure modes

1. External network missing
   - Compose fails → remove amnezia-dns

2. IPv6 not enabled
   - service falls back to IPv4

3. Host cannot reach container IP
   - expected → use port mapping

---

### Extension points

- add DoT listener (port 853)
- integrate with VPN containers
- expose DNS externally (with ACL hardening)