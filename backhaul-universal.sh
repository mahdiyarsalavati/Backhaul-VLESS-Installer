#!/usr/bin/env bash
# Backhaul + VLESS Tunnel Installer
# ----------------------------------------------------------------------------
# Architecture:
#
#   [ VLESS client ] --> [ Iran relay, public ] == Backhaul tunnel ==> [ Foreign server ]
#                                                                          |
#                                                                    Xray VLESS+REALITY
#                                                                    bound to 127.0.0.1
#
# The FOREIGN server runs Xray with a VLESS+REALITY inbound that is only
# reachable from localhost. The IRAN server runs the Backhaul "server" role,
# exposes a public port, and forwards it over the tunnel to the foreign
# server's local Xray port. The FOREIGN server also runs the Backhaul
# "client" role, which dials out to the Iran server.
#
# Because the two machines are independent and this script has no channel
# between them, the foreign step prints a compact "bundle" (its VLESS
# credentials, base64-encoded) that you paste into the Iran step. The Iran
# step then builds the final, ready-to-import VLESS URL itself -- you never
# hand-edit or paste a VLESS URL.
#
# Recommended order (also shown in the script's Help page):
#   1. Foreign server -> option 1 (installs Xray + VLESS/REALITY, prints bundle)
#   2. Iran server     -> option 2 (installs Backhaul, paste the bundle,
#                          choose tunnel transport, prints the final VLESS URL)
#   3. Foreign server  -> option 3 (installs Backhaul client using the
#                          address/token printed in step 2)
#
# Design notes / trade-offs (documented here for whoever maintains this):
#   * VLESS layer is always REALITY over raw TCP -- the fastest, lowest-CPU,
#     cert-free option, and immune to TLS fingerprinting. This is why
#     "maximum bandwidth / minimum CPU" and "WebSocket support" don't
#     conflict: the WebSocket choice below applies only to the Backhaul
#     tunnel itself (Iran<->Foreign), not to the VLESS protocol.
#   * Backhaul tunnel transport is either raw TCP (fastest, recommended when
#     nothing is filtering the Iran<->Foreign link) or WebSocket, optionally
#     fronted by Cloudflare with a domain, for when the relay link itself
#     needs to look like ordinary web traffic.
#   * WSS (secure WebSocket) uses a self-signed certificate generated on the
#     Iran server. Backhaul's own README documents self-signed certs for wss
#     without mentioning verification, but this isn't 100% guaranteed across
#     versions -- if the control channel refuses to connect, switch to plain
#     WS + Cloudflare "Flexible" SSL instead (no certificate involved at all).
#   * connection_pool / aggressive_pool trade CPU and idle resource usage
#     against burst throughput and resilience; there is no single setting
#     that simultaneously minimizes CPU *and* maximizes bandwidth, so the
#     client step asks and explains the trade-off instead of guessing.
# ----------------------------------------------------------------------------
set -Eeuo pipefail

APP_TITLE="Backhaul + VLESS Tunnel Installer"

BIN="/usr/local/bin/backhaul"
CONF_DIR="/etc/backhaul"
CONF="$CONF_DIR/config.toml"
SERVICE="/etc/systemd/system/backhaul.service"
OFFICIAL_REPO="Musixal/Backhaul"
BASE_URL="https://github.com/${OFFICIAL_REPO}/releases/latest/download"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF="$XRAY_CONF_DIR/config.json"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

TLS_DIR="$CONF_DIR/tls"

C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

info() { printf "${C_CYAN}==>${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}OK${C_RESET}  %s\n" "$*"; }
warn() { printf "${C_YELLOW}!!${C_RESET}  %s\n" "$*"; }
die()  { printf "${C_RED}ERROR:${C_RESET} %s\n" "$*" >&2; exit 1; }

trap 'printf "\n${C_RED}ERROR:${C_RESET} failed at line %s\n" "$LINENO" >&2' ERR

# ------------------------------------------------------------------ UI ----

page() {
  local subtitle="${1:-}" step="${2:-}"
  clear 2>/dev/null || true
  printf "${C_CYAN}${C_BOLD}"
  printf '╔════════════════════════════════════════════════════════════╗\n'
  printf '║  %-58s║\n' "$APP_TITLE"
  [[ -n "$step" ]] && printf '║  %-58s║\n' "$step"
  printf '╚════════════════════════════════════════════════════════════╝\n'
  printf "${C_RESET}\n"
  if [[ -n "$subtitle" ]]; then
    printf "${C_YELLOW}»${C_RESET} %s\n\n" "$subtitle"
  fi
}

press_enter() { local _x; read -r -p "Press Enter to continue..." _x || true; }

confirm() {
  local prompt="$1" def="${2:-Y}" ans hint
  hint="[Y/n]"; [[ "$def" == "N" ]] && hint="[y/N]"
  read -r -p "${prompt} ${hint}: " ans
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

# select_choice <resultvar> <title> <option1> [option2] ...
# NOTE: the input variable below is deliberately named "_sc_input" (not
# "choice") so it can never collide with a caller passing a result
# variable literally named "choice" (pick_port does this) -- with
# bash's dynamic scoping, `printf -v "$__var"` resolves to the nearest
# variable of that name, which would otherwise be this function's own
# local instead of the caller's, silently discarding the selection (or,
# on some bash builds, tripping "unbound variable" under `set -u`).
select_choice() {
  local __var="$1" title="$2"; shift 2
  local -a opts=("$@")
  local i _sc_input
  echo
  info "$title"
  for i in "${!opts[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${opts[$i]}"
  done
  while true; do
    read -r -p "Choose [1-${#opts[@]}]: " _sc_input
    if [[ "$_sc_input" =~ ^[0-9]+$ ]] && ((_sc_input >= 1 && _sc_input <= ${#opts[@]})); then
      printf -v "$__var" '%s' "$_sc_input"
      return
    fi
    warn "Invalid choice."
  done
}

# ------------------------------------------------------------ system ------

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

# True (0) if the port is free, or only held by our own backhaul/xray process.
is_port_free() {
  local port="$1" lines
  lines="$(ss -H -lntp 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p {print}' || true)"
  [[ -z "$lines" ]] && return 0
  [[ "$lines" == *'"backhaul"'* || "$lines" == *'"xray"'* ]] && return 0
  return 1
}

# auto_pick_port <mode>   mode: any | cf-https | cf-http
auto_pick_port() {
  local mode="$1" p tries=0
  case "$mode" in
    cf-https)
      for p in 443 2053 2083 2087 2096 8443; do
        is_port_free "$p" && { echo "$p"; return 0; }
      done
      ;;
    cf-http)
      for p in 80 8080 8880 2052 2082 2086 2095; do
        is_port_free "$p" && { echo "$p"; return 0; }
      done
      ;;
    *)
      while ((tries < 300)); do
        p=$(( (RANDOM % 40000) + 20000 ))
        is_port_free "$p" && { echo "$p"; return 0; }
        ((tries++))
      done
      ;;
  esac
  return 1
}

# pick_port <resultvar> <label> <default> [mode: any|cf-https|cf-http]
pick_port() {
  local __var="$1" label="$2" default="$3" mode="${4:-any}"
  local _pp_choice _pp_port allowed_desc="" allowed_list=""
  case "$mode" in
    cf-https) allowed_desc=" (Cloudflare-proxied HTTPS ports only)"; allowed_list=" 443 2053 2083 2087 2096 8443 " ;;
    cf-http)  allowed_desc=" (Cloudflare-proxied HTTP ports only)";  allowed_list=" 80 8080 8880 2052 2082 2086 2095 " ;;
  esac
  echo
  printf "%s%s\n" "$label" "$allowed_desc"
  select_choice _pp_choice "Port selection" \
    "Auto — find the best free port for me (recommended)" \
    "Manual — I'll type the port"
  if [[ "$_pp_choice" == "1" ]]; then
    _pp_port="$(auto_pick_port "$mode")" || die "Could not find a free port automatically. Try manual selection."
    ok "Auto-selected port: ${_pp_port}"
  else
    while true; do
      read -r -p "Enter port [${default}]: " _pp_port
      _pp_port="${_pp_port:-$default}"
      if ! valid_port "$_pp_port"; then
        warn "Enter a number from 1 to 65535."
        continue
      fi
      if [[ -n "$allowed_list" ]] && [[ "$allowed_list" != *" ${_pp_port} "* ]]; then
        warn "That port is not in Cloudflare's proxied list:${allowed_list}"
        continue
      fi
      if ! is_port_free "$_pp_port"; then
        warn "Port ${_pp_port} is already in use. Choose another."
        continue
      fi
      break
    done
  fi
  printf -v "$__var" '%s' "$_pp_port"
}

backup_existing() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a "$file" "${file}.bak.${stamp}"
    warn "Existing file backed up to ${file}.bak.${stamp}"
  fi
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

# --------------------------------------------------------- kernel tuning --

tune_kernel() {
  info "Applying network/kernel optimizations for max throughput / min latency / low CPU..."
  modprobe tcp_bbr >/dev/null 2>&1 || true

  cat > /etc/sysctl.d/99-backhaul-tunnel.conf <<'EOF'
# Installed by the Backhaul + VLESS Tunnel Installer.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
fs.file-max = 1048576
EOF
  sysctl --system >/dev/null 2>&1 \
    || warn "Some sysctl settings could not be applied (read-only in a container, perhaps). Continuing."

  cat > /etc/security/limits.d/99-backhaul-tunnel.conf <<'EOF'
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    ok "BBR congestion control is active."
  else
    warn "BBR did not activate (unsupported kernel?) — falling back to the default congestion control."
  fi
}

# ------------------------------------------------------------- backhaul --

install_backhaul() {
  if [[ -x "$BIN" ]]; then
    ok "Backhaul already installed: $("$BIN" -v 2>&1 | head -n1)"
    return
  fi
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

# ----------------------------------------------------------------- xray --

install_xray() {
  # -u root: the official installer defaults to running Xray as the
  # unprivileged "nobody" user, which cannot read our chmod 600 config
  # (it holds the REALITY private key). Always (re)install as root so
  # an existing "nobody"-owned install gets repaired too -- this is
  # idempotent and safe to re-run.
  info "Installing/updating Xray-core (official XTLS installer, running as root)..."
  bash -c "$(curl -fL "$XRAY_INSTALL_URL")" @ install -u root || die "Xray installation failed."
  [[ -x "$XRAY_BIN" ]] || die "Xray binary not found after installation."

  mkdir -p /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
  systemctl daemon-reload
  ok "Installed $("$XRAY_BIN" version 2>&1 | head -n1)"
}

xray_x25519() {
  local out priv pub
  out="$("$XRAY_BIN" x25519 2>&1)"
  priv="$(printf '%s\n' "$out" | grep -i 'priv' | head -n1 | awk '{print $NF}')"
  pub="$(printf '%s\n' "$out" | grep -i 'pub' | head -n1 | awk '{print $NF}')"
  [[ -n "$priv" && -n "$pub" ]] || die "Could not parse 'xray x25519' output:
$out"
  printf '%s %s' "$priv" "$pub"
}

write_xray_reality_config() {
  local uuid="$1" priv="$2" sid="$3" sni="$4" listen_port="$5"
  mkdir -p "$XRAY_CONF_DIR"
  cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${listen_port},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${uuid}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${sni}:443",
          "xver": 0,
          "serverNames": [ "${sni}" ],
          "privateKey": "${priv}",
          "shortIds": [ "${sid}" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
  chmod 600 "$XRAY_CONF"
}

generate_self_signed_cert() {
  local domain="$1"
  mkdir -p "$TLS_DIR"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$TLS_DIR/server.key" -out "$TLS_DIR/server.crt" \
    -days 3650 -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" \
    >/dev/null 2>&1 || die "Failed to generate a self-signed certificate."
  chmod 600 "$TLS_DIR/server.key"
  ok "Self-signed certificate generated for ${domain} (valid 10 years)."
}

# --------------------------------------------------------------- bundle --
# A tiny, versioned, base64 envelope carrying the foreign server's VLESS
# credentials so the Iran step never has to ask the user to hand-build a
# VLESS URL.

encode_bundle() {
  printf 'BHV1|%s|%s|%s|%s|%s' "$1" "$2" "$3" "$4" "$5" | openssl base64 -A
}

decode_bundle() {
  local raw
  raw="$(printf '%s' "$1" | tr -d '[:space:]' | openssl base64 -d -A 2>/dev/null)" || return 1
  [[ "$raw" == BHV1\|* ]] || return 1
  printf '%s' "$raw"
}

build_vless_url() {
  local uuid="$1" hostport_str="$2" pbk="$3" sid="$4" sni="$5" remark="$6"
  printf 'vless://%s@%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s' \
    "$uuid" "$hostport_str" "$sni" "$pbk" "$sid" "$remark"
}

show_dns_record() {
  local domain="$1" ip="$2" proxied="$3"
  echo
  info "Add this DNS record in your Cloudflare dashboard:"
  printf "  Type:    A\n"
  printf "  Name:    %s\n" "$domain"
  printf "  Content: %s\n" "$ip"
  printf "  Proxy:   %s\n" "$([[ "$proxied" == y ]] && echo 'Proxied (orange cloud)' || echo 'DNS only (grey cloud)')"
  printf "  TTL:     Auto\n"
}

# choose_transport sets: TRANSPORT, TUN_PORT, DOMAIN, CF_PROXIED
choose_transport() {
  local t s
  select_choice t "Backhaul tunnel transport (Iran <-> Foreign link)" \
    "Raw TCP — fastest, lowest CPU (recommended unless this link is filtered)" \
    "WebSocket — disguises the tunnel as web traffic, can be fronted by Cloudflare"

  if [[ "$t" == "1" ]]; then
    TRANSPORT="tcp"
    DOMAIN=""
    CF_PROXIED="n"
    pick_port TUN_PORT "Backhaul tunnel port" "12000" any
    return
  fi

  select_choice s "WebSocket mode" \
    "Plain WS + Cloudflare 'Flexible' SSL — simplest, no certificate needed (recommended)" \
    "WSS (TLS) with a self-signed certificate + Cloudflare 'Full' SSL"
  if [[ "$s" == "1" ]]; then TRANSPORT="ws"; else TRANSPORT="wss"; fi

  while true; do
    read -r -p "Domain to front the tunnel (e.g. relay.example.com): " DOMAIN
    toml_safe_host "$DOMAIN" && break
    warn "Enter a plain domain name (no quotes, backslashes, or blank)."
  done

  if confirm "Will this domain be Proxied (orange cloud) in Cloudflare?" "Y"; then
    CF_PROXIED="y"
    if [[ "$TRANSPORT" == "wss" ]]; then
      pick_port TUN_PORT "Backhaul tunnel port" "443" cf-https
    else
      pick_port TUN_PORT "Backhaul tunnel port" "8080" cf-http
    fi
  else
    CF_PROXIED="n"
    pick_port TUN_PORT "Backhaul tunnel port" "443" any
  fi

  [[ "$TRANSPORT" == "wss" ]] && generate_self_signed_cert "$DOMAIN"
}

# ----------------------------------------------------- foreign / exit -----

setup_foreign_exit() {
  page "Foreign server — install VLESS (REALITY) exit node" "STEP 1 of 3"
  cat <<'EOF'
This installs Xray-core (the official XTLS build, at /usr/local/bin/xray
and /usr/local/etc/xray/config.json) and creates a VLESS + REALITY inbound
bound to 127.0.0.1 only. It stays unreachable from the internet until you
finish Step 2 (Iran) and Step 3 (connect this server to it).
EOF
  echo
  press_enter

  if [[ -f "$XRAY_CONF" ]]; then
    page "Existing Xray config found" "STEP 1 of 3"
    warn "A file already exists at ${XRAY_CONF}."
    echo "Continuing will REPLACE it with a single VLESS+REALITY inbound."
    echo
    echo "If this server runs 3x-ui, x-ui, or another panel: that panel"
    echo "manages its OWN Xray under a different path (e.g. /usr/local/x-ui/)"
    echo "and is not touched by this — but if you'd rather reuse an inbound"
    echo "you already created there instead of running a second Xray here,"
    echo "cancel now and use it on the Iran server (Step 2) by choosing"
    echo "manual entry instead of pasting a bundle: it just needs the"
    echo "UUID, REALITY public key, short ID, SNI, and local port from your"
    echo "existing inbound."
    echo
    confirm "Overwrite ${XRAY_CONF} and continue?" "N" || { info "Cancelled — nothing was changed."; return; }
  fi

  install_packages
  install_xray

  page "Choose a REALITY camouflage site" "STEP 1 of 3"
  local site_choice sni
  select_choice site_choice "Which real HTTPS site should REALITY impersonate?" \
    "www.microsoft.com (recommended)" \
    "www.amazon.com" \
    "addons.mozilla.org" \
    "www.samsung.com" \
    "Custom domain"
  case "$site_choice" in
    1) sni="www.microsoft.com" ;;
    2) sni="www.amazon.com" ;;
    3) sni="addons.mozilla.org" ;;
    4) sni="www.samsung.com" ;;
    5) while true; do
         read -r -p "Domain (must serve TLS 1.3 + HTTP/2, e.g. a big CDN-backed site): " sni
         toml_safe_host "$sni" && break
         warn "Enter a plain domain name (no quotes, backslashes, or blank)."
       done ;;
  esac

  page "Local listen port" "STEP 1 of 3"
  echo "Xray will listen on 127.0.0.1 only — pick any free local port."
  local local_port
  pick_port local_port "Xray local port" "8443" any

  info "Generating credentials..."
  local uuid priv pub sid
  uuid="$("$XRAY_BIN" uuid)"
  read -r priv pub <<< "$(xray_x25519)"
  sid="$(openssl rand -hex 8)"

  write_xray_reality_config "$uuid" "$priv" "$sid" "$sni" "$local_port"

  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray || {
    journalctl -u xray -n 30 --no-pager >&2
    die "Xray failed to start."
  }
  ok "Xray VLESS+REALITY inbound is running on 127.0.0.1:${local_port}."

  tune_kernel

  local bundle
  bundle="$(encode_bundle "$uuid" "$pub" "$sid" "$sni" "$local_port")"

  mkdir -p "$CONF_DIR"
  cat > "$CONF_DIR/foreign-exit.env" <<EOF
UUID="${uuid}"
PRIVATE_KEY="${priv}"
PUBLIC_KEY="${pub}"
SHORT_ID="${sid}"
SNI="${sni}"
LOCAL_PORT="${local_port}"
BUNDLE="${bundle}"
EOF
  chmod 600 "$CONF_DIR/foreign-exit.env"

  page "Foreign exit node ready" "STEP 1 of 3 — done"
  ok "VLESS + REALITY is configured and running."
  echo
  printf "UUID:        %s\n" "$uuid"
  printf "Public key:  %s\n" "$pub"
  printf "Short ID:    %s\n" "$sid"
  printf "SNI:         %s\n" "$sni"
  printf "Local port:  %s\n" "$local_port"
  echo
  ok "Foreign bundle — copy this whole line to the Iran server (Step 2):"
  echo
  printf "  %s\n" "$bundle"
  echo
  info "Next: run this script on the IRAN server and choose Step 2."
  press_enter
}

setup_foreign_client() {
  page "Foreign server — connect to Iran relay" "STEP 3 of 3"
  cat <<'EOF'
Run this after Step 2 is complete on the Iran server. You'll need the
remote address, transport, and token printed at the end of Step 2.
EOF
  echo
  press_enter

  install_packages
  install_backhaul

  local remote tsel transport token
  while true; do
    read -r -p "Remote address (host:port from Step 2): " remote
    [[ "$remote" == *:* ]] && break
    warn "Enter it as host:port, e.g. relay.example.com:443"
  done
  select_choice tsel "Transport (must match what Step 2 used)" "tcp" "ws" "wss"
  case "$tsel" in 1) transport="tcp" ;; 2) transport="ws" ;; 3) transport="wss" ;; esac

  while true; do
    read -r -p "Shared token from the Iran server: " token
    valid_token "$token" && break
    warn "Token must be 8-256 chars: letters, numbers, '.', '_', '~' or '-'."
  done

  local cores default_pool pool aggressive
  cores="$(nproc 2>/dev/null || echo 2)"
  default_pool=$(( cores * 4 ))
  ((default_pool < 8)) && default_pool=8
  ((default_pool > 64)) && default_pool=64

  echo
  echo "Connection pool: more connections raise throughput and resilience,"
  echo "at the cost of more RAM/CPU and file descriptors."
  local poolval
  while true; do
    read -r -p "Connection pool [${default_pool}]: " poolval
    poolval="${poolval:-$default_pool}"
    [[ "$poolval" =~ ^[0-9]+$ ]] && ((10#$poolval >= 1 && 10#$poolval <= 1024)) && { pool="$poolval"; break; }
    warn "Enter a number from 1 to 1024."
  done

  if confirm "Keep the pool always warm (aggressive_pool)? Uses more idle CPU/RAM if yes." "N"; then
    aggressive="true"
  else
    aggressive="false"
  fi

  mkdir -p "$CONF_DIR"
  systemctl stop backhaul.service 2>/dev/null || true
  backup_existing "$CONF"

  cat > "$CONF" <<EOF
[client]
remote_addr = "${remote}"
edge_ip = ""
transport = "${transport}"
token = "${token}"
connection_pool = ${pool}
aggressive_pool = ${aggressive}
keepalive_period = 75
nodelay = true
retry_interval = 3
dial_timeout = 10
sniffer = false
web_port = 0
log_level = "warn"
skip_optz = true
EOF
  chmod 600 "$CONF"

  write_service
  tune_kernel
  systemctl restart backhaul.service

  info "Waiting for the control channel to establish..."
  local waited=0 established=""
  while ((waited < 20)); do
    if journalctl -u backhaul.service -n 50 --no-pager 2>/dev/null | grep -qi "control channel established"; then
      established="yes"
      break
    fi
    sleep 1
    ((waited++))
  done

  systemctl is-active --quiet backhaul.service || {
    journalctl -u backhaul.service -n 30 --no-pager >&2
    die "Backhaul client failed to start."
  }

  page "Foreign client connected" "STEP 3 of 3 — done"
  if [[ -n "$established" ]]; then
    ok "Control channel established with the Iran relay."
  else
    warn "Backhaul is running, but 'control channel established' wasn't seen yet."
    warn "Check: journalctl -u backhaul -f"
    if [[ "$transport" == "wss" ]]; then
      warn "If this looks like a TLS error, the Iran relay's self-signed cert may"
      warn "be rejected. Re-run Step 2 there and choose plain WS + Cloudflare"
      warn "Flexible SSL instead."
    fi
  fi
  echo
  info "All three steps are done. Import the VLESS URL printed at the end of Step 2."
  press_enter
}

# -------------------------------------------------------- iran / relay ---

setup_iran_relay() {
  page "Iran server — Backhaul relay" "STEP 2 of 3"
  cat <<'EOF'
This installs Backhaul and turns this server into the public relay.
You need the "foreign bundle" printed at the end of Step 1.
EOF
  echo
  press_enter

  install_packages
  install_backhaul

  page "Foreign bundle" "STEP 2 of 3"
  local bundle raw uuid pub sid sni local_port _tag
  echo "Paste the bundle from Step 1, or leave empty to enter values manually."
  read -r -p "Bundle: " bundle
  if [[ -n "$bundle" ]]; then
    raw="$(decode_bundle "$bundle")" || die "That bundle could not be read — check you copied the whole line."
    IFS='|' read -r _tag uuid pub sid sni local_port <<< "$raw"
  else
    read -r -p "Foreign UUID: " uuid
    read -r -p "Foreign REALITY public key: " pub
    read -r -p "Foreign REALITY short ID: " sid
    read -r -p "Foreign REALITY SNI (camouflage domain): " sni
    prompt_port local_port "Foreign local Xray port" "8443"
  fi
  [[ -n "$uuid" && -n "$pub" && -n "$sid" && -n "$sni" && -n "$local_port" ]] || die "Missing bundle fields."

  page "Tunnel transport" "STEP 2 of 3"
  local TRANSPORT="" DOMAIN="" CF_PROXIED="n" TUN_PORT=""
  choose_transport

  page "Public VLESS port" "STEP 2 of 3"
  echo "This is the port your VLESS clients will connect to directly on this server."
  local listen_port
  pick_port listen_port "Public VLESS port" "443" any
  [[ "$listen_port" != "$TUN_PORT" ]] || die "The public VLESS port and the tunnel port must differ."

  page "Shared token" "STEP 2 of 3"
  local token
  while true; do
    read -r -p "Shared token (Enter = generate a secure one): " token
    [[ -z "$token" ]] && token="$(openssl rand -hex 32)"
    valid_token "$token" && break
    warn "Token must be 8-256 chars: letters, numbers, '.', '_', '~' or '-'."
  done

  local detected public_ip
  detected="$(detect_public_ip)"
  while true; do
    read -r -p "This server's public IP/hostname [${detected:-required}]: " public_ip
    public_ip="${public_ip:-$detected}"
    toml_safe_host "$public_ip" && break
    warn "A valid public IP/hostname is required."
  done

  systemctl stop backhaul.service 2>/dev/null || true
  mkdir -p "$CONF_DIR"
  backup_existing "$CONF"

  local tls_lines=""
  if [[ "$TRANSPORT" == "wss" ]]; then
    tls_lines=$'tls_cert = "'"$TLS_DIR"$'/server.crt"\ntls_key = "'"$TLS_DIR"$'/server.key"'
  fi

  cat > "$CONF" <<EOF
[server]
bind_addr = "0.0.0.0:${TUN_PORT}"
transport = "${TRANSPORT}"
accept_udp = false
token = "${token}"
keepalive_period = 75
nodelay = true
channel_size = 4096
heartbeat = 40
sniffer = false
web_port = 0
log_level = "warn"
skip_optz = true
${tls_lines}

ports = [
    "${listen_port}=127.0.0.1:${local_port}"
]
EOF
  chmod 600 "$CONF"

  write_service
  open_firewall_port "$TUN_PORT"
  open_firewall_port "$listen_port"
  tune_kernel
  systemctl restart backhaul.service
  sleep 1
  systemctl is-active --quiet backhaul.service || {
    journalctl -u backhaul.service -n 30 --no-pager >&2
    die "Backhaul server failed to start."
  }
  ok "Backhaul relay is running."

  local vless_url remote_for_client
  vless_url="$(build_vless_url "$uuid" "$(hostport "$public_ip" "$listen_port")" "$pub" "$sid" "$sni" "Iran-Relay")"
  if [[ -n "$DOMAIN" ]]; then
    remote_for_client="$(hostport "$DOMAIN" "$TUN_PORT")"
  else
    remote_for_client="$(hostport "$public_ip" "$TUN_PORT")"
  fi

  cat > "$CONF_DIR/iran-relay.env" <<EOF
TRANSPORT="${TRANSPORT}"
DOMAIN="${DOMAIN}"
CF_PROXIED="${CF_PROXIED}"
TUN_PORT="${TUN_PORT}"
LISTEN_PORT="${listen_port}"
TOKEN="${token}"
PUBLIC_IP="${public_ip}"
VLESS_URL="${vless_url}"
REMOTE_FOR_CLIENT="${remote_for_client}"
EOF
  chmod 600 "$CONF_DIR/iran-relay.env"

  page "Iran relay ready" "STEP 2 of 3 — done"
  ok "Backhaul relay is running and forwarding to the foreign exit node."

  if [[ -n "$DOMAIN" ]]; then
    show_dns_record "$DOMAIN" "$public_ip" "$CF_PROXIED"
    echo
    if [[ "$TRANSPORT" == "ws" && "$CF_PROXIED" == "y" ]]; then
      warn "In Cloudflare, set SSL/TLS mode to 'Flexible' for this domain."
    elif [[ "$TRANSPORT" == "wss" && "$CF_PROXIED" == "y" ]]; then
      warn "In Cloudflare, set SSL/TLS mode to 'Full' for this domain."
    elif [[ "$TRANSPORT" == "wss" ]]; then
      warn "This uses a self-signed certificate (no Cloudflare proxy). If the"
      warn "tunnel fails to connect in Step 3, re-run this step and choose"
      warn "plain WS + Cloudflare Flexible SSL instead."
    fi
  fi

  echo
  ok "Give these to the FOREIGN server for Step 3:"
  printf "  Remote address : %s\n" "$remote_for_client"
  printf "  Transport      : %s\n" "$TRANSPORT"
  printf "  Token          : %s\n" "$token"
  echo
  ok "Final VLESS URL — import this into your client app:"
  echo
  printf "  %s\n" "$vless_url"
  echo
  info "Next: run this script on the FOREIGN server again and choose Step 3."
  press_enter
}

# --------------------------------------------------------- status/misc ---

status_all() {
  page "Status & logs" ""
  echo "=== Backhaul ==="
  if [[ -x "$BIN" ]]; then "$BIN" -v || true; else echo "Not installed"; fi
  systemctl --no-pager --full status backhaul.service 2>/dev/null || echo "Service not found."
  echo
  echo "=== Xray ==="
  if [[ -x "$XRAY_BIN" ]]; then "$XRAY_BIN" version 2>&1 | head -n1; else echo "Not installed"; fi
  systemctl --no-pager --full status xray.service 2>/dev/null || echo "Service not found."
  echo

  if [[ -f "$CONF_DIR/foreign-exit.env" ]]; then
    echo "=== Saved: this server's Foreign exit config ==="
    grep -v '^PRIVATE_KEY=' "$CONF_DIR/foreign-exit.env"
    echo "(private key hidden — see $CONF_DIR/foreign-exit.env)"
    echo
  fi
  if [[ -f "$CONF_DIR/iran-relay.env" ]]; then
    echo "=== Saved: this server's Iran relay config ==="
    grep -v '^TOKEN=' "$CONF_DIR/iran-relay.env"
    echo "(token hidden — see $CONF_DIR/iran-relay.env)"
    echo
  fi

  echo "=== Recent Backhaul logs ==="
  journalctl -u backhaul.service -n 20 --no-pager 2>/dev/null || true
  echo
  press_enter
}

uninstall_backhaul() {
  confirm "Remove Backhaul binary, config and service?" "N" || { info "Cancelled."; return; }
  systemctl disable --now backhaul.service 2>/dev/null || true
  rm -f "$SERVICE"
  rm -f "$BIN"
  rm -rf "$CONF_DIR"
  systemctl daemon-reload
  systemctl reset-failed backhaul.service 2>/dev/null || true
  ok "Backhaul removed. Firewall rules were left unchanged."
}

uninstall_xray() {
  confirm "Remove Xray binary and config?" "N" || { info "Cancelled."; return; }
  if [[ -x "$XRAY_BIN" ]]; then
    bash -c "$(curl -fL "$XRAY_INSTALL_URL")" @ remove --purge 2>/dev/null || true
  fi
  rm -rf /etc/systemd/system/xray.service.d
  systemctl daemon-reload
  ok "Xray removed."
}

uninstall_menu() {
  page "Uninstall" ""
  local c
  select_choice c "What do you want to remove?" \
    "Backhaul only" "Xray only" "Both Backhaul and Xray" "Cancel"
  case "$c" in
    1) uninstall_backhaul ;;
    2) uninstall_xray ;;
    3) uninstall_backhaul; uninstall_xray ;;
    4) return ;;
  esac
  press_enter
}

help_page() {
  page "Setup order & architecture" ""
  cat <<'EOF'
  [ VLESS client ] --> [ Iran relay, public ] == Backhaul tunnel ==> [ Foreign server ]
                                                                          |
                                                                    Xray VLESS+REALITY
                                                                    (127.0.0.1 only)

Recommended order:

  1. On the FOREIGN server: menu option 1
     Installs Xray and a VLESS+REALITY inbound. Prints a "bundle" string —
     copy the whole line.

  2. On the IRAN server: menu option 2
     Installs Backhaul, asks you to paste the bundle from step 1, lets you
     choose the tunnel transport (raw TCP, or WebSocket fronted by
     Cloudflare), and prints the final VLESS URL plus the values you need
     for step 3.

  3. Back on the FOREIGN server: menu option 3
     Installs the Backhaul client using the address/transport/token
     printed in step 2.

  4. Import the VLESS URL from step 2 into your VLESS client app.

Why this order: the foreign server must generate its VLESS credentials
before the Iran server can build a working VLESS URL and port mapping, and
the foreign server needs the token/address the Iran server assigns before
it can dial in.

Tuning applied automatically at every step: BBR congestion control, tuned
socket buffers and backlog, raised file-descriptor limits, TCP_NODELAY,
and a plain (mux-free) transport by default to keep CPU overhead low.
Connection-pool size (Step 3) is the one deliberate manual trade-off:
larger pools raise throughput and resilience at the cost of idle CPU/RAM,
so the script asks instead of guessing.
EOF
  echo
  press_enter
}

# ------------------------------------------------------------------ menu -

menu() {
  page "" ""
  cat <<'EOF'
Recommended order: 1 -> 2 -> 3

  1) STEP 1 — Foreign server: install VLESS (REALITY) exit node
  2) STEP 2 — Iran server: install Backhaul relay
  3) STEP 3 — Foreign server: connect to Iran relay (Backhaul client)
  4) Re-apply network optimization only
  5) Status & logs
  6) Uninstall
  7) Help — setup order & architecture
  0) Exit
EOF
  local choice
  read -r -p "Choose: " choice
  case "$choice" in
    1) setup_foreign_exit ;;
    2) setup_iran_relay ;;
    3) setup_foreign_client ;;
    4) tune_kernel; press_enter ;;
    5) status_all ;;
    6) uninstall_menu ;;
    7) help_page ;;
    0) exit 0 ;;
    *) warn "Invalid choice."; sleep 1 ;;
  esac
}

main() {
  need_root
  need_systemd
  install_packages
  while true; do
    menu
  done
}

main "$@"
