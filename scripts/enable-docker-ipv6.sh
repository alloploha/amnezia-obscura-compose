#!/usr/bin/env bash
set -euo pipefail

# enable-docker-ipv6.sh
#
# Purpose:
# - Detect a likely Docker daemon.json location
# - Check whether IPv6 is already enabled
# - Add the minimal settings needed to enable Docker IPv6
# - Optionally restart Docker at the end
#
# Notes:
# - This script prefers editing daemon.json with jq when available.
# - If jq is not installed, it falls back to a minimal Python JSON edit.
# - It creates a timestamped backup before changing anything.
# - For Docker Desktop / WSL2, editing the config file may still require
#   a Docker Desktop restart from Windows to fully apply.
#
# Usage examples:
#   ./enable-docker-ipv6.sh
#   ./enable-docker-ipv6.sh --restart
#   ./enable-docker-ipv6.sh --cidr-v6 fd30:153::/48 --restart
#   ./enable-docker-ipv6.sh --config ~/.docker/daemon.json
#
# Exit codes:
#   0 success / no change needed
#   1 general error

DEFAULT_CIDR_V6="fd00:b00b:b00b::/48"
RESTART_DOCKER=0
CONFIG_PATH=""
FORCE_PATH=0
VERBOSE=0

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
Usage: enable-docker-ipv6.sh [options]

Options:
  --restart                 Restart Docker after a change is made
  --cidr-v6 <prefix>        Set fixed-cidr-v6 (default: fd00:b00b:b00b::/48)
  --config <path>           Use an explicit daemon.json path
  --verbose                 More output
  -h, --help                Show this help

Behavior:
  - Detects a likely Docker daemon.json location if not given
  - Checks whether "ipv6": true is already set
  - Adds minimal keys:
      "ipv6": true
      "fixed-cidr-v6": "<prefix>"
  - Preserves existing JSON settings
  - Makes a backup before writing

Typical config paths checked:
  - /etc/docker/daemon.json
  - /etc/docker/daemon/daemon.json
  - $HOME/.docker/daemon.json

Restart behavior:
  - Native Linux: tries systemctl, then service
  - Docker Desktop / WSL2: restart may need to be done in the Docker Desktop UI
    or by restarting Docker Desktop from Windows
EOF
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --restart)
        RESTART_DOCKER=1
        shift
        ;;
      --cidr-v6)
        [[ $# -ge 2 ]] || { err "Missing value for --cidr-v6"; exit 1; }
        DEFAULT_CIDR_V6="$2"
        shift 2
        ;;
      --config)
        [[ $# -ge 2 ]] || { err "Missing value for --config"; exit 1; }
        CONFIG_PATH="$2"
        FORCE_PATH=1
        shift 2
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

is_wsl() {
  grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
}

is_docker_desktop() {
  if ! have_cmd docker; then
    return 1
  fi

  docker info 2>/dev/null | grep -q 'Operating System: Docker Desktop' && return 0
  docker context show 2>/dev/null | grep -qx 'desktop-linux' && return 0

  return 1
}

get_windows_user_home_wsl_path() {
  local win_home=""

  if have_cmd cmd.exe; then
    win_home="$(cmd.exe /C "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')"
  elif have_cmd powershell.exe; then
    win_home="$(powershell.exe -NoProfile -Command \
      "[Environment]::GetFolderPath('UserProfile')" 2>/dev/null | tr -d '\r')"
  else
    return 1
  fi

  [[ -n "$win_home" ]] || return 1

  if have_cmd wslpath; then
    wslpath "$win_home"
  else
    printf '%s\n' "$win_home" | sed -E 's#^([A-Za-z]):#/\Lmnt/\1#; s#\\#/#g'
  fi
}

detect_config_path() {
  if [[ $FORCE_PATH -eq 1 ]]; then
    printf '%s\n' "$CONFIG_PATH"
    return 0
  fi

  local docker_root=""
  if have_cmd docker; then
    docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  fi

  if [[ $VERBOSE -eq 1 && -n "$docker_root" ]]; then
    log "Detected DockerRootDir: $docker_root"
  fi

  # WSL + Docker Desktop:
  # use the Windows user's ~/.docker/daemon.json, not the distro-local one.
  if is_wsl && is_docker_desktop; then
    local win_home_wsl=""
    if win_home_wsl="$(get_windows_user_home_wsl_path)"; then
      printf '%s\n' "$win_home_wsl/.docker/daemon.json"
      return 0
    fi
    warn "WSL + Docker Desktop detected, but could not resolve Windows user home. Falling back."
  fi

  local candidates=(
    "/etc/docker/daemon.json"
    "/etc/docker/daemon/daemon.json"
    "$HOME/.docker/daemon.json"
  )

  for p in "${candidates[@]}"; do
    if [[ -f "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done

  # If running as root or /etc/docker is writable, prefer system config.
  if [[ -w /etc/docker || (! -e /etc/docker && -w /etc) ]]; then
    printf '%s\n' "/etc/docker/daemon.json"
    return 0
  fi

  # Fallback to user config for non-root native setups.
  printf '%s\n' "$HOME/.docker/daemon.json"
}

ensure_parent_dir() {
  local path="$1"
  local dir
  dir="$(dirname "$path")"
  mkdir -p "$dir"
}

backup_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    local backup="${path}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$path" "$backup"
    log "Backup created: $backup"
  fi
}

validate_json() {
  local path="$1"
  if have_cmd jq; then
    jq empty "$path" >/dev/null
  else
    python3 - <<'PY' "$path"
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    json.load(f)
PY
  fi
}

json_get_ipv6_enabled() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    printf 'missing\n'
    return 0
  fi

  if have_cmd jq; then
    jq -r 'if has("ipv6") then .ipv6 else "missing" end' "$path"
  else
    python3 - <<'PY' "$path"
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
    v = data.get("ipv6", "missing")
    if isinstance(v, bool):
        print("true" if v else "false")
    else:
        print("missing")
except FileNotFoundError:
    print("missing")
PY
  fi
}

json_get_fixed_cidr_v6() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    printf 'missing\n'
    return 0
  fi

  if have_cmd jq; then
    jq -r '."fixed-cidr-v6" // "missing"' "$path"
  else
    python3 - <<'PY' "$path"
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
    print(data.get("fixed-cidr-v6", "missing"))
except FileNotFoundError:
    print("missing")
PY
  fi
}

write_json_update() {
  local path="$1"
  local cidr_v6="$2"
  local tmp
  tmp="$(mktemp)"

  if [[ ! -f "$path" || ! -s "$path" ]]; then
    printf '{}\n' > "$path"
  fi

  validate_json "$path"

  if have_cmd jq; then
    jq \
      --arg cidr "$cidr_v6" \
      '.ipv6 = true | ."fixed-cidr-v6" = $cidr' \
      "$path" > "$tmp"
  else
    python3 - <<'PY' "$path" "$tmp" "$cidr_v6"
import json, sys
src, dst, cidr = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, 'r', encoding='utf-8') as f:
    data = json.load(f)
if not isinstance(data, dict):
    raise SystemExit("Top-level JSON must be an object")
data["ipv6"] = True
data["fixed-cidr-v6"] = cidr
with open(dst, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, sort_keys=False)
    f.write("\n")
PY
  fi

  mv "$tmp" "$path"
}

restart_docker_native_linux() {
  if have_cmd systemctl; then
    if systemctl is-active docker >/dev/null 2>&1 || systemctl status docker >/dev/null 2>&1; then
      sudo systemctl restart docker
      return 0
    fi
  fi

  if have_cmd service; then
    if service docker status >/dev/null 2>&1 || true; then
      sudo service docker restart
      return 0
    fi
  fi

  return 1
}

restart_docker_desktop_windows() {
  # Best-effort only. Works only when called from WSL with powershell.exe available.
  if have_cmd powershell.exe; then
    powershell.exe -NoProfile -Command \
      "Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 3; Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe'" \
      >/dev/null 2>&1 || return 1
    return 0
  fi
  return 1
}

main() {
  parse_args "$@"

  local path
  path="$(detect_config_path)"
  log "Using Docker daemon config: $path"

  ensure_parent_dir "$path"

  if [[ -f "$path" ]]; then
    validate_json "$path"
  else
    log "Config does not exist yet. It will be created."
  fi

  local current_ipv6 current_cidr changed=0
  current_ipv6="$(json_get_ipv6_enabled "$path")"
  current_cidr="$(json_get_fixed_cidr_v6 "$path")"

  if [[ $VERBOSE -eq 1 ]]; then
    log "Current ipv6: $current_ipv6"
    log "Current fixed-cidr-v6: $current_cidr"
  fi

  if [[ "$current_ipv6" == "true" && "$current_cidr" != "missing" ]]; then
    log "Docker IPv6 already appears enabled in daemon config."
    log "ipv6=true, fixed-cidr-v6=$current_cidr"
  else
    backup_file "$path"
    write_json_update "$path" "$DEFAULT_CIDR_V6"
    changed=1
    log "Updated daemon config:"
    log "  ipv6: true"
    log "  fixed-cidr-v6: $DEFAULT_CIDR_V6"
  fi

  if [[ $changed -eq 0 ]]; then
    log "No config change was needed."
  fi

  if [[ $changed -eq 1 && $RESTART_DOCKER -eq 1 ]]; then
    log "Restart requested."

    if is_wsl; then
      warn "WSL environment detected."
      if restart_docker_desktop_windows; then
        log "Docker Desktop restart triggered from WSL."
      else
        warn "Automatic Docker Desktop restart did not succeed."
        warn "Restart Docker Desktop manually."
      fi
    else
      if restart_docker_native_linux; then
        log "Docker service restarted."
      else
        warn "Could not automatically restart Docker."
        warn "Restart it manually, for example: sudo systemctl restart docker"
      fi
    fi
  elif [[ $changed -eq 1 ]]; then
    log "A Docker restart is required for the new IPv6 settings to take effect."
    if is_wsl; then
      log "In WSL/Docker Desktop, restart Docker Desktop."
    else
      log "On Linux, run: sudo systemctl restart docker"
    fi
  fi

  log "Done."
}

main "$@"
