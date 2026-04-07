#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s\n' "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "This script must be run as root."
    log "Run: sudo bash $0"
    exit 1
  fi
}

has_docker_compose() {
  docker compose version >/dev/null 2>&1
}

detect_linux_family() {
  if [[ ! -r /etc/os-release ]]; then
    log "Cannot read /etc/os-release"
    exit 1
  fi

  . /etc/os-release

  case "${ID:-}" in
    ubuntu|debian)
      DIST_ID="$ID"
      ;;
    *)
      if [[ "${ID_LIKE:-}" == *debian* ]]; then
        DIST_ID="debian"
      else
        log "Unsupported distribution: ${ID:-unknown}"
        log "This script supports apt-based Debian/Ubuntu systems."
        exit 1
      fi
      ;;
  esac

  VERSION_CODENAME_VALUE="${VERSION_CODENAME:-}"
  if [[ -z "$VERSION_CODENAME_VALUE" ]]; then
    log "VERSION_CODENAME is not set in /etc/os-release."
    log "Set the Docker repository manually for this distribution."
    exit 1
  fi
}

ensure_prerequisites() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg
}

ensure_docker_cli_exists() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Docker CLI is not installed."
    log "Install Docker Engine/CLI first, then rerun this script."
    exit 1
  fi
}

ensure_keyring() {
  install -m 0755 -d /etc/apt/keyrings

  local keyring="/etc/apt/keyrings/docker.gpg"
  local tmp_key
  tmp_key="$(mktemp)"

  curl -fsSL "https://download.docker.com/linux/${DIST_ID}/gpg" | gpg --dearmor -o "$tmp_key"
  install -m 0644 "$tmp_key" "$keyring"
  rm -f "$tmp_key"
}

ensure_repo() {
  local repo_file="/etc/apt/sources.list.d/docker.list"
  local arch
  arch="$(dpkg --print-architecture)"

  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" \
    "$DIST_ID" \
    "$VERSION_CODENAME_VALUE" \
    > "$repo_file"
}

install_compose_plugin() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y docker-compose-plugin
}

main() {
  require_root

  if has_docker_compose; then
    log "Docker Compose is already installed."
    docker compose version
    exit 0
  fi

  detect_linux_family
  ensure_docker_cli_exists
  ensure_prerequisites
  ensure_keyring
  ensure_repo
  install_compose_plugin

  if has_docker_compose; then
    log "Docker Compose installed successfully."
    docker compose version
  else
    log "Installation completed, but 'docker compose' is still unavailable."
    exit 1
  fi
}

main "$@"
