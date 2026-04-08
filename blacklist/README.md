# Obscura Blacklist

Russian version: [README.ru.md](README.ru.md)

`obscura-blacklist` is an optional module for a Linux server running Docker.
It blocks unwanted outbound connections from containers based on domain and ASN lists.

This module runs on the host.
For normal use, the interface is the three top-level scripts in `scripts/`.

## Requirements

- Linux server
- Docker
- systemd
- `python3`
- root access

The module selects its networking backend automatically.
Regular users do not need to know in advance whether the host uses `iptables` or `nftables`.

## Installation

1. Clone the repository:

```bash
git clone https://github.com/alloploha/amnezia-obscura-compose.git
cd amnezia-obscura-compose
```

2. Run the installer:

```bash
sudo sh scripts/install-blacklist.sh
```

The script will:
- check for `python3`, `docker`, and `systemctl`
- verify that systemd is the active init system
- verify that the Docker daemon is reachable
- install the system launcher, config, source files, and systemd units
- run a validation check
- immediately apply the blacklist

After installation, the module uses these system paths:
- config: `/etc/obscura-blacklist/blacklist.conf`
- source files: `/etc/obscura-blacklist/sources/`

## Updating The Lists

After installation, edit the files in:

```text
/etc/obscura-blacklist/sources/
```

For example, that directory contains files such as:
- `domains-*.txt`
- `asns-*.txt`

## Current Default Lists

The repository currently ships blacklist source files for:
- Vkontakte
- Max Messenger
- Rostelecom
- `gov.ru` related ASN ranges, including Roskomnadzor-related infrastructure
- Sberbank
- `mail.ru`
- Odnoklassniki
- Gosuslugi

After changing the lists, apply the update:

```bash
sudo sh scripts/refresh-blacklist.sh
```

This script rereads the installed config and updates the active rules.
It uses:
- `/etc/obscura-blacklist/blacklist.conf`
- `/etc/obscura-blacklist/sources/`

If you want to copy blacklist source file changes from the cloned repository into the installed blacklist and refresh them in one step, use:

```bash
sudo sh scripts/refresh-blacklist.sh --copy
```

In `--copy` mode, the script copies the repo source files from:
- `blacklist/config/sources/`

into:
- `/etc/obscura-blacklist/sources/`

and then runs the normal installed refresh using `/etc/obscura-blacklist/blacklist.conf`.

## Removing The Module

To remove the systemd integration, run:

```bash
sudo sh scripts/uninstall-blacklist.sh
```

The script will:
- disable and stop the timer
- stop the service
- try to remove the module's active rules
- remove the systemd units

Important:
- the script removes the systemd integration
- the installed config and source files are not deleted automatically
- the state and cache directories are also not deleted automatically

## Troubleshooting

First check:
- whether Docker is running
- whether `docker info` works
- whether systemd is active on the host

If installation fails, fix the reported problem and run the same script again.
