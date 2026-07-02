#!/usr/bin/env bash

migration_repo_root() {
    local script_dir
    script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
    CDPATH= cd -- "$script_dir/.." && pwd
}

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

err() {
    printf 'ERROR: %s\n' "$*" >&2
}

die() {
    err "$*"
    exit 1
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

require_cmd() {
    have_cmd "$1" || die "required command not found: $1"
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_bool() {
    if [ "$1" = "1" ] || [ "$1" = "true" ]; then
        printf 'true'
    else
        printf 'false'
    fi
}

is_root_or_allowed() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || [ "${OBSCURA_ALLOW_NON_ROOT:-0}" = "1" ]
}

require_root_or_allowed() {
    is_root_or_allowed || die "this action must run as root. Use sudo, or set OBSCURA_ALLOW_NON_ROOT=1 only for disposable tests."
}

confirm_or_die() {
    local yes="$1"
    local prompt="$2"
    local answer

    if [ "$yes" -eq 1 ]; then
        return
    fi

    printf '%s [y/N] ' "$prompt" >&2
    read -r answer
    case "$answer" in
        y|Y|yes|YES) return ;;
        *) die "operation cancelled" ;;
    esac
}

safe_service_name() {
    case "$1" in
        xray|awg|socks5proxy) return 0 ;;
        all) return 0 ;;
        *) return 1 ;;
    esac
}

service_source_container() {
    case "$1" in
        xray) printf '%s\n' "amnezia-xray" ;;
        awg) printf '%s\n' "amnezia-awg" ;;
        socks5proxy) printf '%s\n' "amnezia-socks5proxy" ;;
        *) return 1 ;;
    esac
}

service_external_subdir() {
    case "$1" in
        xray) printf '%s\n' "xray" ;;
        awg) printf '%s\n' "awg" ;;
        socks5proxy) printf '%s\n' "socks5proxy" ;;
        *) return 1 ;;
    esac
}

service_external_dir() {
    local service="$1"
    local amnezia_dir="$2"
    printf '%s/%s\n' "$amnezia_dir" "$(service_external_subdir "$service")"
}

service_container_path() {
    case "$1" in
        xray) printf '%s\n' "/opt/amnezia/xray" ;;
        awg) printf '%s\n' "/opt/amnezia/awg" ;;
        socks5proxy) printf '%s\n' "/usr/local/3proxy" ;;
        *) return 1 ;;
    esac
}

service_obscura_state_dir() {
    case "$1" in
        xray) printf '%s\n' "/var/lib/obscura/xray" ;;
        awg) printf '%s\n' "/var/lib/obscura/awg" ;;
        socks5proxy) printf '%s\n' "/var/lib/obscura/socks5proxy" ;;
        *) return 1 ;;
    esac
}

service_required_files() {
    case "$1" in
        xray) printf '%s\n' "server.json xray_uuid.key xray_short_id.key xray_public.key xray_private.key" ;;
        awg) printf '%s\n' "awg0.conf wireguard_server_private_key.key wireguard_server_public_key.key wireguard_psk.key" ;;
        socks5proxy) printf '%s\n' "conf/3proxy.cfg" ;;
        *) return 1 ;;
    esac
}

service_externalize_script() {
    case "$1" in
        xray) printf '%s\n' "scripts/externalize-amnezia-xray.sh" ;;
        awg) printf '%s\n' "scripts/externalize-amnezia-awg.sh" ;;
        socks5proxy) printf '%s\n' "scripts/externalize-amnezia-socks5proxy.sh" ;;
        *) return 1 ;;
    esac
}

service_import_script() {
    case "$1" in
        xray) printf '%s\n' "scripts/import-amnezia-xray.sh" ;;
        awg) printf '%s\n' "scripts/import-amnezia-awg.sh" ;;
        *) return 1 ;;
    esac
}

docker_available() {
    have_cmd docker && docker info >/dev/null 2>&1
}

container_exists() {
    docker inspect "$1" >/dev/null 2>&1
}

container_running() {
    [ "$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true)" = "running" ]
}

container_health() {
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || true
}

container_summary_value() {
    local container="$1"
    local key="$2"

    case "$key" in
        image) docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null || true ;;
        status) docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true ;;
        restart) docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null || true ;;
        privileged) docker inspect -f '{{.HostConfig.Privileged}}' "$container" 2>/dev/null || true ;;
        ports) docker inspect -f '{{range $p, $cfg := .HostConfig.PortBindings}}{{if $cfg}}{{range $cfg}}{{printf "%s:%s " $p .HostPort}}{{end}}{{end}}{{end}}' "$container" 2>/dev/null || true ;;
        networks) docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{printf "%s " $name}}{{end}}' "$container" 2>/dev/null || true ;;
        mounts) docker inspect -f '{{range .Mounts}}{{printf "%s:%s " .Destination .Source}}{{end}}' "$container" 2>/dev/null || true ;;
        capadd) docker inspect -f '{{range .HostConfig.CapAdd}}{{printf "%s " .}}{{end}}' "$container" 2>/dev/null || true ;;
        *) return 1 ;;
    esac
}

detect_obscura_container() {
    local service="$1"

    docker ps \
        --filter "label=com.docker.compose.project=obscura" \
        --filter "label=com.docker.compose.service=$service" \
        --filter "label=com.docker.compose.container-number=1" \
        --format '{{.Names}}' 2>/dev/null \
        | head -n 1
}

latest_backup_container() {
    local source_container="$1"

    docker ps -a \
        --filter "name=${source_container}-old-" \
        --format '{{.Names}}' 2>/dev/null \
        | awk -v prefix="${source_container}-old-" '$0 ~ "^" prefix { print }' \
        | sort \
        | tail -n 1
}

host_path_for_docker() {
    local path="$1"

    case "$(uname -s 2>/dev/null || true)" in
        MINGW*|MSYS*|CYGWIN*)
            if have_cmd cygpath; then
                cygpath -w "$path"
                return
            fi
            ;;
    esac

    printf '%s\n' "$path"
}

safe_restore_path() {
    local path="$1"
    [ -n "$path" ] || return 1
    [ "$path" != "/" ] || return 1
    case "$path" in
        /srv/amnezia/*|/srv/obscura/*|/tmp/*|/var/tmp/*) return 0 ;;
        *) return 1 ;;
    esac
}

sha256_file() {
    local file="$1"
    if have_cmd sha256sum; then
        sha256sum "$file"
    elif have_cmd shasum; then
        shasum -a 256 "$file"
    else
        printf 'sha256-unavailable  %s\n' "$file"
    fi
}
