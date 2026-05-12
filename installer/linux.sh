#!/usr/bin/env bash
# CoreDNS (aleskxyz) Linux install — download binary, /etc/coredns, systemd, resolv.conf.
# Requires root.
#
# Remote (release branch):
#   curl -fsSL 'https://raw.githubusercontent.com/aleskxyz/coredns/refs/heads/release/installer/linux.sh' | sudo bash
#   curl -fsSL 'https://raw.githubusercontent.com/aleskxyz/coredns/refs/heads/release/installer/linux.sh' | sudo bash -s -- --uninstall
#
# From a clone:
#   sudo bash installer/linux.sh
#   sudo bash installer/linux.sh --uninstall
#
# If /usr/local/bin/coredns already reports the same version as VER below, the tarball
# download/extract is skipped (delete the binary or bump VER to force refresh).

set -euo pipefail

# ANSI via $'...' so ESC is a real byte (plain '\033' in quotes prints as visible \033).
readonly CYAN=$'\033[0;36m'
readonly GRAY=$'\033[0;90m'
readonly GRN=$'\033[0;32m'
readonly YLW=$'\033[0;33m'
readonly RED=$'\033[0;31m'
readonly RST=$'\033[0m'

log() { printf '%s%s%s\n' "$CYAN" "[CoreDNS] $*" "$RST"; }
log_gray() { printf '%s%s%s\n' "$GRAY" "[CoreDNS] $*" "$RST"; }
warn() { printf '%s%s%s\n' "$YLW" "[CoreDNS] WARNING: $*" "$RST" >&2; }
die() { printf '%s%s%s\n' "$RED" "[CoreDNS] ERROR: $*" "$RST" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run as root (e.g. sudo bash $0)"
fi

VER='1.14.3'
BIN='/usr/local/bin/coredns'
ETC='/etc/coredns'
RESOLVERS="${ETC}/resolvers"
COREFILE="${ETC}/Corefile"
UNIT='/etc/systemd/system/coredns.service'
STAGE="${TMPDIR:-/tmp}/coredns-linux-install"
TGZ="${TMPDIR:-/tmp}/coredns_${VER}_linux.tgz"

usage() {
  echo "Usage: sudo bash $0 [--uninstall]" >&2
  exit 2
}

UNINSTALL=0
if [[ $# -gt 1 ]]; then
  usage
fi
case "${1:-}" in
  '' ) ;;
  --uninstall|-uninstall) UNINSTALL=1 ;;
  *) usage ;;
esac

systemd_unit() {
  cat <<'UNITEOF'
[Unit]
Description=CoreDNS DNS server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=coredns
Group=coredns
ExecStart=/usr/local/bin/coredns -conf /etc/coredns/Corefile
Restart=on-failure
RestartSec=2
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/coredns
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNITEOF
}

write_resolvers() {
  cat >"$RESOLVERS" <<'EOF'
nameserver 194.225.152.10
nameserver 194.225.62.80
nameserver 217.218.127.127
nameserver 217.218.155.155
nameserver 2.188.21.100
nameserver 2.188.21.120
nameserver 2.188.21.190
nameserver 2.188.21.230
nameserver 2.188.21.240
nameserver 2.188.21.90
nameserver 2.189.44.44
nameserver 46.209.157.19
nameserver 95.38.102.86
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
}

write_corefile() {
  cat >"$COREFILE" <<'EOF'
.:53 {
    bind 127.0.0.153

    cache 3600 {
        success 65536 3600
        denial 65536 1800
        serve_stale 720h immediate
        prefetch 2 1m 20%
        servfail 5s
    }

    fanout . /etc/coredns/resolvers {
        race
        race-continue-on-error
        attempt-count 0
        timeout 5s
    }

    log
    errors
}
EOF
}

stop_coredns_for_binary_update() {
  if [[ -f "$UNIT" ]] && systemctl is-active --quiet coredns.service 2>/dev/null; then
    log 'Stopping coredns.service so the binary can be replaced...'
    systemctl stop coredns.service
  fi
}

remove_systemd_unit() {
  if [[ -f "$UNIT" ]]; then
    log 'Stopping and disabling coredns.service...'
    systemctl disable --now coredns.service 2>/dev/null || true
    systemctl stop coredns.service 2>/dev/null || true
    rm -f "$UNIT"
    systemctl daemon-reload
    log_gray 'Removed systemd unit.'
  fi
}

binary_reports_ver() {
  [[ -x "$BIN" ]] || return 1
  local out
  out="$("$BIN" -version 2>&1)" || return 1
  [[ "$out" == *"$VER"* ]]
}

map_arch() {
  local a
  a="$(uname -m)"
  case "$a" in
    x86_64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv6l) echo arm ;;
    riscv64) echo riscv64 ;;
    ppc64le) echo ppc64le ;;
    s390x) echo s390x ;;
    mips) echo mips ;;
    mips64) echo mips64le ;;
    *) die "unsupported uname -m: $a" ;;
  esac
}

if [[ "$UNINSTALL" -eq 1 ]]; then
  log 'Uninstall: stopping service, removing unit, binary, config, temp files, user coredns...'

  remove_systemd_unit

  if [[ -L /etc/resolv.conf ]]; then
    log_gray 'Leaving /etc/resolv.conf unchanged (symlink; not modified on uninstall).'
  elif [[ -f /etc/resolv.conf ]] && grep -q '127.0.0.153' /etc/resolv.conf; then
    log 'Replacing /etc/resolv.conf (grep found 127.0.0.153); clearing chattr -i if set...'
    chattr -i /etc/resolv.conf 2>/dev/null || true
    log 'Writing /etc/resolv.conf to use 217.218.127.127 and 217.218.155.155...'
    cat >/etc/resolv.conf <<'RESOLVUN'
nameserver 217.218.127.127
nameserver 217.218.155.155
RESOLVUN
  else
    log_gray 'Leaving /etc/resolv.conf unchanged (no nameserver 127.0.0.153, or file missing).'
  fi

  rm -rf "$ETC"
  rm -f "$BIN"
  rm -rf "$STAGE" "$TGZ" "${TMPDIR:-/tmp}/coredns" 2>/dev/null || true

  if getent passwd coredns &>/dev/null; then
    if userdel coredns 2>/dev/null; then
      log_gray 'Removed user coredns.'
    else
      warn 'Could not remove user coredns (in use?); remove manually: userdel coredns'
    fi
  fi

  printf '%s%s%s\n' "$GRN" '[CoreDNS] Uninstall finished.' "$RST"
  exit 0
fi

log "Setup starting (CoreDNS $VER)."

CARCH="$(map_arch)"
URL="https://raw.githubusercontent.com/aleskxyz/coredns/refs/heads/release/v${VER}/coredns_${VER}_linux_${CARCH}.tgz"

install -d -m 0755 "$ETC"

getent passwd coredns &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin coredns

skip_bin=0
if binary_reports_ver; then
  log_gray "Binary already present and reports $VER; skipping download and install."
  skip_bin=1
else
  stop_coredns_for_binary_update

  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  log "Downloading: $URL"
  if ! curl -fsSL -o "${TGZ}.part" "$URL"; then
    rm -f "${TGZ}.part"
    die 'Download failed (curl).'
  fi
  mv -f "${TGZ}.part" "$TGZ"
  log_gray "Saved: $TGZ"

  log 'Extracting tarball...'
  tar -xzf "$TGZ" -C "$STAGE"
  staged="${STAGE}/coredns"
  [[ -f "$staged" ]] || die "Tarball did not contain coredns at top level: $staged"

  log "Installing binary to $BIN"
  install -m 0755 "$staged" "$BIN"
  log 'Binary version:'
  "$BIN" -version || true
  rm -f "$TGZ"
  rm -rf "$STAGE"
fi

log "Writing resolvers: $RESOLVERS"
write_resolvers

log "Writing Corefile: $COREFILE"
write_corefile

chown -R coredns:coredns "$ETC"

log 'Config file paths:'
log_gray "  Resolvers: $RESOLVERS"
log_gray "  Corefile:  $COREFILE"

log 'Writing systemd unit...'
systemd_unit >"$UNIT"
systemctl daemon-reload
systemctl enable coredns.service
log 'Starting/restarting coredns.service...'
systemctl restart coredns.service

log 'Service status:'
systemctl --no-pager status coredns.service || true

log 'Setting /etc/resolv.conf to use CoreDNS (127.0.0.153) and immutable flag...'
if [[ -L /etc/resolv.conf ]]; then
  warn '/etc/resolv.conf is a symlink; removing symlink and replacing with a regular file.'
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/resolv.conf
fi
chattr -i /etc/resolv.conf 2>/dev/null || true
cat >/etc/resolv.conf <<'EOF'
nameserver 127.0.0.153
EOF
chattr +i /etc/resolv.conf

printf '%s%s%s\n' "$GRN" '[CoreDNS] Setup finished.' "$RST"
