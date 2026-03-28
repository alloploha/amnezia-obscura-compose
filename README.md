# Obscura DNS

Minimal self-hosted DNS service for VPN environments (Amnezia, WireGuard, Xray).

>This project is not a fork of the original [Amnezia VPN](https://github.com/amnezia-vpn/amnezia-client) repository.
>It is an independent deployment layer designed to standardize and extend infrastructure around Amnezia-compatible components.

## What this gives you

- Private DNS resolver for VPN clients and containers
- DNS-over-TLS upstreams (Cloudflare, Quad9, Google)
- Protection from ISP DNS interception
- Support for Emercoin domains (.coin, .emc, etc.)
- IPv4 + IPv6 support (optional)

## Requirements

- Docker + Docker Compose
- Optional: IPv6 enabled in Docker

## Enable IPv6 (optional)

```bash
./enable-docker-ipv6.sh --restart
```

## Run

```bash
docker compose up -d --build
```

## Amnezia network

This setup optionally connects to an existing Docker network: `amnezia-dns`.

If you see:

```
network amnezia-dns declared as external, but could not be found
```

Then remove it:

* delete `amnezia-dns` network block
* remove it from `services.dns.networks`

## How to use

DNS server runs at:

* internal: `172.30.153.53`
* IPv6: `fd30:153::53`
* optional (Amnezia): `172.27.172.153`

Use this IP in your VPN or container configs.

## Testing

### Inside container (recommended)

```bash
docker exec -it obscura-dns-1 drill @127.0.0.1 google.com
```

### From another container

```bash
docker run --rm -it --network obscura-dns drill @172.30.153.53 google.com
```

### From host (optional)

Expose port 53 in compose:

```yaml
ports:
  - "53:53/udp"
  - "53:53/tcp"
```

Then:

```bash
dig @127.0.0.1 google.com
```

## Troubleshooting

### No DNS response

* check container:

```bash
docker ps
docker logs obscura-dns-1
```

### Host cannot reach 172.x.x.x

* expected behavior
* use container tests or expose ports

### IPv6 not working

* ensure Docker IPv6 is enabled
* restart Docker after changes