#!/usr/bin/env bash
set -euo pipefail

DEFAULT_CONTAINER_NAME="amnezia-socks5proxy"
DEFAULT_DATA_DIR="/srv/amnezia/socks5proxy"

CONTAINER_NAME="$DEFAULT_CONTAINER_NAME"
DATA_DIR="$DEFAULT_DATA_DIR"
FORCE=0
VERBOSE=0

BACKUP_NAME=""
RENAMED_OLD=0
NEW_CREATED=0
SUCCESS=0

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: externalize-amnezia-socks5proxy.sh [options]

This one-shot script migrates an existing Amnezia SOCKS5 proxy container to use
host-mounted directories for:
  - /usr/local/3proxy/conf
  - /usr/local/3proxy/logs

It intentionally does not externalize:
  - /usr/local/3proxy/libexec

Default target layout:
  /srv/amnezia/socks5proxy/conf
  /srv/amnezia/socks5proxy/logs

Options:
  --container <name>   Container name to migrate
  --data-dir <path>    Host data directory root
  --force              Allow reuse of non-empty host directories
  --verbose            More output
  -h, --help           Show this help

Examples:
  sudo bash scripts/externalize-amnezia-socks5proxy.sh
  sudo bash scripts/externalize-amnezia-socks5proxy.sh \
    --container amnezia-socks5proxy \
    --data-dir /srv/amnezia/socks5proxy
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "This script must be run as root."
    err "Run: sudo bash $0"
    exit 1
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --container)
        [[ $# -ge 2 ]] || { err "Missing value for --container"; exit 1; }
        CONTAINER_NAME="$2"
        shift 2
        ;;
      --data-dir)
        [[ $# -ge 2 ]] || { err "Missing value for --data-dir"; exit 1; }
        DATA_DIR="$2"
        shift 2
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

ensure_container_exists() {
  docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || {
    err "Container not found: $CONTAINER_NAME"
    exit 1
  }
}

ensure_not_already_migrated() {
  local mounts
  mounts="$(docker inspect -f '{{range .Mounts}}{{println .Destination "|" .Source "|" .Type}}{{end}}' "$CONTAINER_NAME")"

  if grep -q '^/usr/local/3proxy/conf |' <<<"$mounts" || grep -q '^/usr/local/3proxy/logs |' <<<"$mounts"; then
    err "Container already has a mount on /usr/local/3proxy/conf or /usr/local/3proxy/logs."
    exit 1
  fi
}

ensure_target_dirs_ready() {
  local conf_dir="$DATA_DIR/conf"
  local logs_dir="$DATA_DIR/logs"

  mkdir -p "$conf_dir" "$logs_dir"

  if [[ $FORCE -eq 0 ]]; then
    if find "$conf_dir" -mindepth 1 -print -quit | grep -q .; then
      err "Target directory is not empty: $conf_dir"
      err "Use --force if you want to reuse it."
      exit 1
    fi
    if find "$logs_dir" -mindepth 1 -print -quit | grep -q .; then
      err "Target directory is not empty: $logs_dir"
      err "Use --force if you want to reuse it."
      exit 1
    fi
  fi
}

copy_container_data() {
  local conf_dir="$DATA_DIR/conf"
  local logs_dir="$DATA_DIR/logs"

  log "Copying /usr/local/3proxy/conf from $CONTAINER_NAME to $conf_dir"
  docker cp "$CONTAINER_NAME":/usr/local/3proxy/conf/. "$conf_dir"/

  log "Copying /usr/local/3proxy/logs from $CONTAINER_NAME to $logs_dir"
  docker cp "$CONTAINER_NAME":/usr/local/3proxy/logs/. "$logs_dir"/
}

set_permissions() {
  local conf_dir="$DATA_DIR/conf"
  local logs_dir="$DATA_DIR/logs"

  chown -R root:root "$conf_dir"
  find "$conf_dir" -type d -exec chmod 700 {} \;
  find "$conf_dir" -type f -exec chmod 600 {} \;

  chown -R 65535:65535 "$logs_dir"
  find "$logs_dir" -type d -exec chmod 750 {} \;
  find "$logs_dir" -type f -exec chmod 640 {} \;
}

read_container_state() {
  IMAGE_NAME="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME")"
  RESTART_POLICY="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER_NAME")"
  LOG_DRIVER="$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$CONTAINER_NAME")"

  mapfile -t PORT_BINDINGS < <(
    docker inspect -f '{{range $p, $cfg := .HostConfig.PortBindings}}{{if $cfg}}{{range $cfg}}{{printf "%s|%s|%s\n" $p .HostIp .HostPort}}{{end}}{{end}}{{end}}' "$CONTAINER_NAME"
  )

  mapfile -t LOG_OPTIONS < <(
    docker inspect -f '{{range $k, $v := .HostConfig.LogConfig.Config}}{{printf "%s=%s\n" $k $v}}{{end}}' "$CONTAINER_NAME"
  )

  mapfile -t EXTRA_NETWORKS < <(
    docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$CONTAINER_NAME" \
      | awk '$1 != "bridge" && $1 != "host" && $1 != "none" { print $1 }'
  )

  if [[ $VERBOSE -eq 1 ]]; then
    log "Image: $IMAGE_NAME"
    log "Restart policy: $RESTART_POLICY"
    log "Log driver: $LOG_DRIVER"
  fi
}

build_docker_run_args() {
  DOCKER_RUN_ARGS=(run -d --name "$CONTAINER_NAME")

  if [[ -n "$RESTART_POLICY" && "$RESTART_POLICY" != "no" ]]; then
    DOCKER_RUN_ARGS+=(--restart "$RESTART_POLICY")
  fi

  if [[ -n "$LOG_DRIVER" ]]; then
    DOCKER_RUN_ARGS+=(--log-driver "$LOG_DRIVER")
  fi

  for opt in "${LOG_OPTIONS[@]}"; do
    [[ -n "$opt" ]] || continue
    DOCKER_RUN_ARGS+=(--log-opt "$opt")
  done

  for binding in "${PORT_BINDINGS[@]}"; do
    [[ -n "$binding" ]] || continue

    IFS='|' read -r container_port host_ip host_port <<<"$binding"
    local container_number="${container_port%/*}"
    local proto="${container_port#*/}"
    local publish_arg=""

    if [[ -n "$host_ip" && "$host_ip" != "0.0.0.0" ]]; then
      if [[ "$host_ip" == *:* ]]; then
        publish_arg="[$host_ip]:$host_port:$container_number/$proto"
      else
        publish_arg="$host_ip:$host_port:$container_number/$proto"
      fi
    else
      publish_arg="$host_port:$container_number/$proto"
    fi

    DOCKER_RUN_ARGS+=(-p "$publish_arg")
  done

  DOCKER_RUN_ARGS+=(
    -v "$DATA_DIR/conf:/usr/local/3proxy/conf"
    -v "$DATA_DIR/logs:/usr/local/3proxy/logs"
    "$IMAGE_NAME"
  )
}

cleanup_on_error() {
  local exit_code=$?
  if [[ $SUCCESS -eq 1 ]]; then
    return
  fi

  warn "Migration failed."

  if [[ $NEW_CREATED -eq 1 ]] && docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    warn "Removing partially recreated container: $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi

  if [[ $RENAMED_OLD -eq 1 ]] && [[ -n "$BACKUP_NAME" ]] && docker inspect "$BACKUP_NAME" >/dev/null 2>&1; then
    warn "Restoring original container name: $CONTAINER_NAME"
    docker rename "$BACKUP_NAME" "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi

  exit "$exit_code"
}

main() {
  trap cleanup_on_error EXIT

  parse_args "$@"
  require_root

  have_cmd docker || {
    err "Docker CLI is not installed."
    exit 1
  }

  ensure_container_exists
  ensure_not_already_migrated
  ensure_target_dirs_ready
  read_container_state
  copy_container_data
  set_permissions
  build_docker_run_args

  BACKUP_NAME="${CONTAINER_NAME}-old-$(date +%Y%m%d-%H%M%S)"

  log "Stopping container: $CONTAINER_NAME"
  docker stop "$CONTAINER_NAME" >/dev/null

  log "Renaming old container to: $BACKUP_NAME"
  docker rename "$CONTAINER_NAME" "$BACKUP_NAME"
  RENAMED_OLD=1

  log "Creating replacement container with host-mounted conf and logs directories"
  docker "${DOCKER_RUN_ARGS[@]}" >/dev/null
  NEW_CREATED=1

  for network_name in "${EXTRA_NETWORKS[@]}"; do
    [[ -n "$network_name" ]] || continue
    log "Connecting $CONTAINER_NAME to network: $network_name"
    docker network connect "$network_name" "$CONTAINER_NAME"
  done

  SUCCESS=1

  log "Migration completed."
  log "New container: $CONTAINER_NAME"
  log "Backup container: $BACKUP_NAME"
  log "Host conf dir: $DATA_DIR/conf"
  log "Host logs dir: $DATA_DIR/logs"
  log "The following path intentionally remains inside the image: /usr/local/3proxy/libexec"
}

main "$@"
