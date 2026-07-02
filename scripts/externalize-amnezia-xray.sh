#!/usr/bin/env bash
set -euo pipefail

DEFAULT_CONTAINER_NAME="amnezia-xray"
DEFAULT_DATA_DIR="/srv/amnezia/xray"
DEFAULT_CONTAINER_PATH="/opt/amnezia/xray"

CONTAINER_NAME="$DEFAULT_CONTAINER_NAME"
DATA_DIR="$DEFAULT_DATA_DIR"
CONTAINER_PATH="$DEFAULT_CONTAINER_PATH"
FORCE=0
VERBOSE=0
ALLOW_NON_ROOT="${OBSCURA_ALLOW_NON_ROOT:-0}"

BACKUP_NAME=""
RENAMED_OLD=0
NEW_CREATED=0
SUCCESS=0

IMAGE_NAME=""
RESTART_POLICY=""
LOG_DRIVER=""
PRIVILEGED=""
declare -a PORT_BINDINGS=()
declare -a LOG_OPTIONS=()
declare -a EXTRA_NETWORKS=()
declare -a CAP_ADDS=()
declare -a ENV_VARS=()
declare -a EXTRA_BIND_MOUNTS=()
declare -a DOCKER_RUN_ARGS=()

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
Usage: externalize-amnezia-xray.sh [options]

This one-shot script migrates an existing Amnezia Xray container to use a
host-mounted state directory for:
  - /opt/amnezia/xray

Default target layout:
  /srv/amnezia/xray

The script:
  1. copies the existing container state to the host
  2. recreates the same container name with a bind mount on /opt/amnezia/xray
  3. preserves existing non-Xray bind mounts such as a mounted /opt/amnezia/start.sh
  3. reconnects the recreated container to its non-default Docker networks

Options:
  --container <name>         Container name to migrate
  --data-dir <path>          Host data directory
  --container-path <path>    Path inside the container, default /opt/amnezia/xray
  --force                    Allow reuse of a non-empty host directory
  --verbose                  More output
  -h, --help                 Show this help

Examples:
  sudo bash scripts/externalize-amnezia-xray.sh
  sudo bash scripts/externalize-amnezia-xray.sh \
    --container amnezia-xray \
    --data-dir /srv/amnezia/xray
EOF
}

require_root() {
    if [[ "${EUID}" -ne 0 && "$ALLOW_NON_ROOT" != "1" ]]; then
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
            --container-path)
                [[ $# -ge 2 ]] || { err "Missing value for --container-path"; exit 1; }
                CONTAINER_PATH="$2"
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

    if grep -q "^$CONTAINER_PATH |" <<<"$mounts"; then
        err "Container already has a mount on $CONTAINER_PATH."
        exit 1
    fi
}

ensure_target_dir_ready() {
    mkdir -p "$DATA_DIR"

    if [[ $FORCE -eq 0 ]]; then
        if find "$DATA_DIR" -mindepth 1 -print -quit | grep -q .; then
            err "Target directory is not empty: $DATA_DIR"
            err "Use --force if you want to reuse it."
            exit 1
        fi
    fi
}

copy_container_data() {
    log "Copying $CONTAINER_PATH from $CONTAINER_NAME to $DATA_DIR"
    docker cp "$CONTAINER_NAME":"$CONTAINER_PATH"/. "$DATA_DIR"/

    for required in server.json xray_uuid.key xray_short_id.key xray_public.key xray_private.key; do
        if [[ ! -s "$DATA_DIR/$required" ]]; then
            err "Required Xray state file was not copied or is empty: $required"
            exit 1
        fi
    done
}

set_permissions() {
    if [[ "${EUID}" -eq 0 ]]; then
        chown -R root:root "$DATA_DIR"
    fi
    find "$DATA_DIR" -type d -exec chmod 700 {} \;
    find "$DATA_DIR" -type f -exec chmod 600 {} \;

    if [[ -f "$DATA_DIR/client.template.json" ]]; then
        chmod 644 "$DATA_DIR/client.template.json"
    fi
}

read_container_state() {
    IMAGE_NAME="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME")"
    RESTART_POLICY="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER_NAME")"
    LOG_DRIVER="$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$CONTAINER_NAME")"
    PRIVILEGED="$(docker inspect -f '{{.HostConfig.Privileged}}' "$CONTAINER_NAME")"

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

    mapfile -t CAP_ADDS < <(
        docker inspect -f '{{range .HostConfig.CapAdd}}{{println .}}{{end}}' "$CONTAINER_NAME"
    )

    mapfile -t ENV_VARS < <(
        docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME"
    )

    mapfile -t EXTRA_BIND_MOUNTS < <(
        docker inspect -f '{{range .Mounts}}{{printf "%s|%s|%t\n" .Destination .Source .RW}}{{end}}' "$CONTAINER_NAME" \
            | awk -F'|' -v state_path="$CONTAINER_PATH" '$1 != state_path { print }'
    )

    if [[ $VERBOSE -eq 1 ]]; then
        log "Image: $IMAGE_NAME"
        log "Restart policy: $RESTART_POLICY"
        log "Log driver: $LOG_DRIVER"
        log "Privileged: $PRIVILEGED"
    fi
}

build_docker_run_args() {
    local binding
    local env_var
    local cap

    DOCKER_RUN_ARGS=(run -d --name "$CONTAINER_NAME")

    if [[ -n "$RESTART_POLICY" && "$RESTART_POLICY" != "no" ]]; then
        DOCKER_RUN_ARGS+=(--restart "$RESTART_POLICY")
    fi

    if [[ -n "$LOG_DRIVER" ]]; then
        DOCKER_RUN_ARGS+=(--log-driver "$LOG_DRIVER")
    fi

    for binding in "${LOG_OPTIONS[@]}"; do
        [[ -n "$binding" ]] || continue
        DOCKER_RUN_ARGS+=(--log-opt "$binding")
    done

    if [[ "$PRIVILEGED" == "true" ]]; then
        DOCKER_RUN_ARGS+=(--privileged)
    fi

    for cap in "${CAP_ADDS[@]}"; do
        [[ -n "$cap" ]] || continue
        DOCKER_RUN_ARGS+=(--cap-add "$cap")
    done

    for env_var in "${ENV_VARS[@]}"; do
        [[ -n "$env_var" ]] || continue
        [[ "$env_var" != PATH=* ]] || continue
        DOCKER_RUN_ARGS+=(-e "$env_var")
    done

    for binding in "${EXTRA_BIND_MOUNTS[@]}"; do
        [[ -n "$binding" ]] || continue

        IFS='|' read -r destination source rw <<<"$binding"
        local mount_arg="$source:$destination"

        if [[ "$rw" != "true" ]]; then
            mount_arg="$mount_arg:ro"
        fi

        DOCKER_RUN_ARGS+=(-v "$mount_arg")
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
        -v "$DATA_DIR:$CONTAINER_PATH"
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
    ensure_target_dir_ready
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

    log "Creating replacement container with host-mounted Xray state"
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
    log "Host Xray state dir: $DATA_DIR"
    if [[ ${#EXTRA_BIND_MOUNTS[@]} -gt 0 ]]; then
        log "Preserved additional bind mounts:"
        for binding in "${EXTRA_BIND_MOUNTS[@]}"; do
            [[ -n "$binding" ]] || continue
            IFS='|' read -r destination source rw <<<"$binding"
            log "  $destination <- $source"
        done
    fi
}

main "$@"
