#!/usr/bin/env bash
set -Eeuo pipefail

APP="backhaul"
BIN="/usr/local/bin/backhaul"
CONF_DIR="/etc/backhaul"
CONF="$CONF_DIR/config.toml"
SERVICE="/etc/systemd/system/backhaul.service"
OFFICIAL_REPO="Musixal/Backhaul"
BASE_URL="https://github.com/${OFFICIAL_REPO}/releases/latest/download"

C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'

info() { printf "${C_CYAN}==>${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}OK${C_RESET}  %s\n" "$*"; }
warn() { printf "${C_YELLOW}!!${C_RESET}  %s\n" "$*"; }
die()  { printf "${C_RED}ERROR:${C_RESET} %s\n" "$*" >&2; exit 1; }

trap 'printf "\n${C_RED}ERROR:${C_RESET} failed at line %s\n" "$LINENO" >&2' ERR

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root."
}

need_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemd is required."
}

install_packages() {
  local missing=()
  for cmd in curl tar sha256sum openssl ss; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) && return 0

  info "Installing required packages..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar coreutils openssl iproute2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates tar coreutils openssl iproute
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates tar coreutils openssl iproute
  else
    die "Unsupported package manager. Install curl, tar, sha256sum, openssl and ss manually."
  fi
}

arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "Unsupported architecture: $(uname -m). Official Backhaul releases provide linux/amd64 and linux/arm64." ;;
  esac
}

install_backhaul() {
  local arch asset tmp archive checksums expected
  arch="$(arch_name)"
  asset="backhaul_linux_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  archive="$tmp/$asset"
  checksums="$tmp/checksums.txt"
  info "Downloading latest official Backhaul (${arch})..."
  curl -fL --retry 3 --connect-timeout 15 "${BASE_URL}/${asset}" -o "$archive"
  curl -fL --retry 3 --connect-timeout 15 "${BASE_URL}/checksums.txt" -o "$checksums"

  expected="$(awk -v f="$asset" '$2 == f {print $1; exit}' "$checksums")"
  [[ -n "$expected" ]] || die "Could not find ${asset} in the official checksum file."
  printf '%s  %s\n' "$expected" "$archive" | sha256sum -c - >/dev/null
  ok "Official release checksum verified."

  tar -xzf "$archive" -C "$tmp"
  [[ -f "$tmp/backhaul" ]] || die "Archive did not contain the backhaul binary."
  install -m 0755 "$tmp/backhaul" "$BIN"

  local version
  version="$("$BIN" -v 2>&1 | head -n1 || true)"
  [[ -n "$version" ]] || die "Installed binary did not run correctly."
  ok "Installed ${version} to ${BIN}"
  rm -rf "$tmp"
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

prompt_port() {
  local __var="$1" prompt="$2" def="$3" value
  while true; do
    read -r -p "${prompt} [${def}]: " value
    value="${value:-$def}"
    if valid_port "$value"; then
      printf -v "$__var" '%s' "$value"
      return
    fi
    warn "Enter a TCP port from 1 to 65535."
  done
}

valid_token() {
  [[ "$1" =~ ^[A-Za-z0-9._~-]{8,256}$ ]]
}

toml_safe_host() {
  local h="$1"
  [[ -n "$h" && "$h" != *'"'* && "$h" != *'\'* && "$h" != *$'\n'* && "$h" != *$'\r'* ]]
}

hostport() {
  local host="$1" port="$2"
  if [[ "$host" == \[*\] ]]; then
    printf '%s:%s' "$host" "$port"
  elif [[ "$host" == *:* ]]; then
    printf '[%s]:%s' "$host" "$port"
  else
    printf '%s:%s' "$host" "$port"
  fi
}

is_tcp_listening() {
  local port="$1"
  ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$"
}

port_in_use_by_other() {
  local port="$1" lines
  lines="$(ss -H -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print}' || true)"
  [[ -n "$lines" && "$lines" != *'("backhaul"'* ]]
}

backup_existing() {
  if [[ -f "$CONF" ]]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONF" "${CONF}.bak.${stamp}"
    warn "Existing config backed up to ${CONF}.bak.${stamp}"
  fi
}

write_service() {
  cat > "$SERVICE" <<EOF
[Unit]
Description=Backhaul Reverse Tunnel
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${BIN} -c ${CONF}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable backhaul.service >/dev/null
}

open_firewall_port() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${port}/tcp" >/dev/null
    ok "Allowed TCP ${port} in UFW."
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    ok "Allowed TCP ${port} in firewalld."
  fi
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4fsS --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$ip"
    return
  fi
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  printf '%s' "$ip"
}

rewrite_vless() {
  local url="$1" new_host="$2" new_port="$3"
  [[ "$url" == vless://* ]] || return 1

  local rest user_and_tail user tail suffix formatted_host
  rest="${url#vless://}"
  [[ "$rest" == *@* ]] || return 1
  user="${rest%%@*}"
  user_and_tail="${rest#*@}"
  [[ -n "$user" && -n "$user_and_tail" ]] || return 1

  if [[ "$user_and_tail" =~ ^([^/?#]+)(.*)$ ]]; then
    tail="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  [[ -n "$tail" ]] || return 1

  if [[ "$new_host" == \[*\] ]]; then
    formatted_host="$new_host"
  elif [[ "$new_host" == *:* ]]; then
    formatted_host="[${new_host}]"
  else
    formatted_host="$new_host"
  fi

  printf 'vless://%s@%s:%s%s' "$user" "$formatted_host" "$new_port" "$suffix"
}

setup_server() {
  local tunnel_port listen_port target_host target_port target_addr token public_ip detected nodelay
  echo
  info "Configuring IRAN / Backhaul server."

  prompt_port tunnel_port "Backhaul tunnel port" "12000"
  prompt_port listen_port "Public forwarded port for VLESS" "12001"

  read -r -p "Foreign target host [127.0.0.1]: " target_host
  target_host="${target_host:-127.0.0.1}"
  toml_safe_host "$target_host" || die "Invalid target host."

  prompt_port target_port "Foreign VLESS inbound port" "443"

  read -r -p "Shared token (Enter = generate a secure one): " token
  if [[ -z "$token" ]]; then
    token="$(openssl rand -hex 32)"
  fi
  valid_token "$token" || die "Token must be 8-256 characters using letters, numbers, '.', '_', '~' or '-'."

  read -r -p "Enable TCP_NODELAY for lower latency? [Y/n]: " nodelay
  case "${nodelay:-y}" in
    y|Y|yes|YES) nodelay="true" ;;
    *) nodelay="false" ;;
  esac

  detected="$(detect_public_ip)"
  read -r -p "Iran public IP/hostname [${detected:-required}]: " public_ip
  public_ip="${public_ip:-$detected}"
  toml_safe_host "$public_ip" || die "A valid Iran public IP/hostname is required."

  [[ "$tunnel_port" != "$listen_port" ]] || die "Tunnel and forwarded ports must be different."
  if port_in_use_by_other "$tunnel_port"; then
    die "TCP ${tunnel_port} is already used by another process. Choose another tunnel port."
  fi
  if port_in_use_by_other "$listen_port"; then
    die "TCP ${listen_port} is already used by another process. Choose another forwarded port."
  fi

  target_addr="$(hostport "$target_host" "$target_port")"
  systemctl stop backhaul.service 2>/dev/null || true

  mkdir -p "$CONF_DIR"
  backup_existing

  cat > "$CONF" <<EOF
[server]
bind_addr = "0.0.0.0:${tunnel_port}"
transport = "tcp"
accept_udp = false
token = "${token}"
keepalive_period = 75
nodelay = ${nodelay}
channel_size = 2048
heartbeat = 40
sniffer = false
web_port = 0
log_level = "info"
skip_optz = true

ports = [
    "${listen_port}=${target_addr}"
]
EOF
  chmod 600 "$CONF"

  write_service
  open_firewall_port "$tunnel_port"
  open_firewall_port "$listen_port"
  systemctl restart backhaul.service
  sleep 1

  systemctl is-active --quiet backhaul.service || {
    journalctl -u backhaul.service -n 30 --no-pager >&2
    die "Backhaul server failed to start."
  }

  ok "Backhaul server is running."
  echo
  printf 'Iran endpoint:       %s\n' "$(hostport "$public_ip" "$listen_port")"
  printf 'Tunnel endpoint:     %s\n' "$(hostport "$public_ip" "$tunnel_port")"
  printf 'Foreign destination: %s\n' "$target_addr"
  printf 'Shared token:        %s\n' "$token"
  echo
  printf 'Use these on the FOREIGN/client setup:\n'
  printf '  Iran address : %s\n' "$public_ip"
  printf '  Tunnel port  : %s\n' "$tunnel_port"
  printf '  Token        : %s\n' "$token"

  echo
  local original_vless new_vless=""
  read -r -p "Paste the existing FOREIGN VLESS URL to generate the Iran/Backhaul URL (Enter to skip): " original_vless
  if [[ -n "$original_vless" ]]; then
    if ! new_vless="$(rewrite_vless "$original_vless" "$public_ip" "$listen_port")"; then
      warn "That does not look like a valid VLESS URL. Nothing was rewritten."
      new_vless=""
    fi
  fi

  echo
  info "Status: systemctl status backhaul --no-pager"
  info "Logs:   journalctl -u backhaul -f"

  if [[ -n "$new_vless" ]]; then
    echo
    ok "Backhaul VLESS URL:"
    printf '%s\n' "$new_vless"
  fi
}

setup_client() {
  local iran_host tunnel_port token pool nodelay remote
  echo
  info "Configuring FOREIGN / Backhaul client."

  read -r -p "Iran public IP/hostname: " iran_host
  toml_safe_host "$iran_host" || die "A valid Iran IP/hostname is required."

  prompt_port tunnel_port "Backhaul tunnel port" "12000"

  while true; do
    read -r -p "Shared token from Iran server: " token
    valid_token "$token" && break
    warn "Token must be 8-256 characters using letters, numbers, '.', '_', '~' or '-'."
  done

  while true; do
    read -r -p "Connection pool [8]: " pool
    pool="${pool:-8}"
    if [[ "$pool" =~ ^[0-9]+$ ]] && ((10#$pool >= 1 && 10#$pool <= 1024)); then
      break
    fi
    warn "Enter a connection pool from 1 to 1024."
  done

  read -r -p "Enable TCP_NODELAY for lower latency? [Y/n]: " nodelay
  case "${nodelay:-y}" in
    y|Y|yes|YES) nodelay="true" ;;
    *) nodelay="false" ;;
  esac

  remote="$(hostport "$iran_host" "$tunnel_port")"

  mkdir -p "$CONF_DIR"
  systemctl stop backhaul.service 2>/dev/null || true
  backup_existing

  cat > "$CONF" <<EOF
[client]
remote_addr = "${remote}"
transport = "tcp"
token = "${token}"
connection_pool = ${pool}
aggressive_pool = false
keepalive_period = 75
nodelay = ${nodelay}
retry_interval = 3
dial_timeout = 10
sniffer = false
web_port = 0
log_level = "info"
skip_optz = true
EOF
  chmod 600 "$CONF"

  write_service
  systemctl restart backhaul.service
  sleep 2

  systemctl is-active --quiet backhaul.service || {
    journalctl -u backhaul.service -n 30 --no-pager >&2
    die "Backhaul client failed to start."
  }

  ok "Backhaul client is running."
  printf 'Remote Iran endpoint: %s\n' "$remote"
  printf 'Connection pool:       %s\n' "$pool"
  echo
  info "Recent logs:"
  journalctl -u backhaul.service -n 8 --no-pager || true
  echo
  info "If the Iran server is reachable, look for: control channel established successfully"
}

status_backhaul() {
  echo "=== VERSION ==="
  if [[ -x "$BIN" ]]; then "$BIN" -v || true; else echo "Not installed"; fi
  echo
  echo "=== SERVICE ==="
  systemctl --no-pager --full status backhaul.service || true
  echo
  echo "=== RECENT LOGS ==="
  journalctl -u backhaul.service -n 30 --no-pager || true
}

uninstall_backhaul() {
  local answer
  read -r -p "Remove Backhaul binary, config and systemd service? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { info "Cancelled."; return; }

  systemctl disable --now backhaul.service 2>/dev/null || true
  rm -f "$SERVICE"
  rm -f "$BIN"
  rm -rf "$CONF_DIR"
  systemctl daemon-reload
  systemctl reset-failed backhaul.service 2>/dev/null || true
  ok "Backhaul removed. Firewall rules were left unchanged intentionally."
}

menu() {
  cat <<'EOF'

Backhaul Universal Installer
----------------------------
1) Install/configure IRAN server
2) Install/configure FOREIGN client
3) Show status and logs
4) Uninstall
0) Exit
EOF

  local choice
  read -r -p "Choose: " choice
  case "$choice" in
    1)
      install_backhaul
      setup_server
      ;;
    2)
      install_backhaul
      setup_client
      ;;
    3)
      status_backhaul
      ;;
    4)
      uninstall_backhaul
      ;;
    0)
      exit 0
      ;;
    *)
      die "Invalid choice."
      ;;
  esac
}

main() {
  need_root
  need_systemd
  install_packages
  menu
}

main "$@"
