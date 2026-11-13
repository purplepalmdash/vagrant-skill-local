#!/usr/bin/env bash
# shellcheck source=/dev/null
# setup.sh — minimal baseline provisioner (VM lifecycle profile)
#
# Installs only what a disposable sandbox VM needs to be usable over SSH with
# full sudo, plus a small set of debugging/network tools. No Docker, no Go,
# no mage — this profile exists to boot, drive, and tear down VMs.
#
#   - apt mirror (env-gated; default USTC for CN)
#   - baseline + network/debug tools
#   - KVM tools only when INSTALL_KVM_TOOLS=1 and /dev/kvm exists
#
# Idempotent: safe to re-run. Run as root (Vagrant provisioner handles this).
# Runs on amd64 and arm64 (aarch64) guests.

set -euo pipefail

# ─── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

ARCH=$(uname -m)

# ─── Preflight ───────────────────────────────────────────────────────────────
info "Checking prerequisites..."
[[ $EUID -eq 0 ]] || error "Must run as root"

info "Prerequisites OK: root, arch=$ARCH"

# ─── 0. APT mirror (env-gated; no-op when APT_MIRROR is empty) ─────────────
# Ubuntu 24.04 uses deb822 /etc/apt/sources.list.d/ubuntu.sources pointing at
# archive.ubuntu.com / security.ubuntu.com, which are slow from CN. Only the
# URIs: lines are rewritten, and a stamp file makes re-runs a no-op.
# Keep upstream sources with:  APT_MIRROR="" vagrant provision
configure_apt_mirror() {
    local mirror="${APT_MIRROR:-}"
    if [[ -z "$mirror" ]]; then
        info "APT_MIRROR unset — keeping upstream apt sources"
        return 0
    fi

    local f=/etc/apt/sources.list.d/ubuntu.sources
    local stamp=/etc/vagrant-skill-apt-mirror.stamp
    if [[ ! -f "$f" ]]; then
        warn "$f not found — skipping apt mirror rewrite"
        return 0
    fi
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$mirror" ]]; then
        info "apt mirror already set to $mirror"
        return 0
    fi

    sed -ri "s#^(URIs: *)https?://(archive|security)\.ubuntu\.com/ubuntu/?#\1${mirror}/ubuntu/#" "$f"
    echo "$mirror" > "$stamp"
    info "apt URIs rewritten to ${mirror}/ubuntu/"
}

# ─── 1. Baseline packages ───────────────────────────────────────────────────
# rsync is required by the rsync synced-folder strategy (no host NFS server
# on Linux/libvirt hosts), so it is installed explicitly.
install_system_deps() {
    info "Installing baseline packages (apt-get install is idempotent)..."
    export DEBIAN_FRONTEND=noninteractive
    configure_apt_mirror
    apt-get update -qq
    apt-get install -y -qq \
        rsync \
        curl \
        git \
        jq \
        ca-certificates \
        gnupg \
        iptables \
        netfilter-persistent \
        iptables-persistent \
        dnsutils \
        net-tools \
        iproute2 \
        procps \
        strace \
        util-linux \
        > /dev/null

    info "Baseline packages installed"
}

# ─── 2. KVM tools (opt-in) ─────────────────────────────────────────────────
# Off by default: qemu-kvm + libvirt in the guest is heavy and only needed for
# nested-virtualization work. Enable with:  INSTALL_KVM_TOOLS=1 vagrant up
install_kvm_tools() {
    if [[ "${INSTALL_KVM_TOOLS:-0}" != "1" ]]; then
        info "KVM tools skipped (set INSTALL_KVM_TOOLS=1 to install)"
        return 0
    fi
    if [[ ! -e /dev/kvm ]]; then
        warn "KVM not available (/dev/kvm missing) — skipping KVM tools"
        return 0
    fi

    info "KVM available — installing KVM tools..."
    apt-get install -y -qq qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils > /dev/null
    usermod -aG libvirt vagrant 2>/dev/null || true
    usermod -aG kvm vagrant 2>/dev/null || true

    info "KVM tools installed"
}

# ─── Run ─────────────────────────────────────────────────────────────────────
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "vagrant-skill: baseline setup (lifecycle profile — no Docker/Go/mage)"
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

install_system_deps
install_kvm_tools

info ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Setup complete!"
info ""
info "  Baseline:   rsync, curl, git, jq, iptables, ip, dig, strace"
info "  KVM:        $(test -e /dev/kvm && echo 'passthrough available' || echo 'not available')"
if [[ -d /project ]]; then
    info "  Project:    /project (synced from host)"
fi
info ""
info "Drive this VM from the host with:"
info "  vagrant ssh -c \"sudo <cmd>\""
info "  vagrant rsync && vagrant ssh -c \"cd /project && <cmd>\""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
