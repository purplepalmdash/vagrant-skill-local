#!/usr/bin/env bash
# shellcheck source=/dev/null
# verify.sh — validate the sandbox VM is ready to be driven over SSH
#
# Lifecycle profile: checks reachability, sudo, baseline tooling, and the
# synced-folder mechanism. No Docker / Go / mage checks — those are not
# installed by this profile, and pulling images from the network is not a
# reliable signal from CN.
#
# Exits non-zero if any critical check fails.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}PASS${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $*"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}SKIP${NC} $*"; WARN=$((WARN + 1)); }

check_cmd() {
    local cmd="$1"
    local label="${2:-$cmd}"
    if command -v "$cmd" &>/dev/null; then
        pass "$label"
    else
        fail "$label"
    fi
}

check_cmd_optional() {
    local cmd="$1"
    local label="${2:-$cmd}"
    if command -v "$cmd" &>/dev/null; then
        pass "$label"
    else
        skip "$label (optional — set INSTALL_KVM_TOOLS=1)"
    fi
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  vagrant-skill: VM readiness verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── 1. Reachability & privileges ───────────────────────────────────────────
echo -e "\n▶ Reachability & privileges"

if [[ $EUID -eq 0 ]]; then
    pass "Provisioner runs as root"
else
    fail "Provisioner runs as root"
fi

. /etc/os-release
pass "OS: ${PRETTY_NAME:-unknown}"

if id vagrant &>/dev/null; then
    pass "vagrant user exists"
    if runuser -u vagrant -- sudo -n id -un 2>/dev/null | grep -qx root; then
        pass "vagrant user has passwordless sudo"
    else
        fail "vagrant user has passwordless sudo"
    fi
else
    fail "vagrant user exists"
fi

# ─── 2. Synced-folder mechanism (rsync-based; no host NFS server) ──────────
echo -e "\n▶ Sync mechanism"

check_cmd rsync "rsync (required by synced folders)"
if ! rpcinfo -p localhost >/dev/null 2>&1 && ! command -v mount.nfs &>/dev/null; then
    pass "No NFS client dependency in the way"
else
    pass "NFS client present (harmless; synced folders use rsync)"
fi

# ─── 3. Baseline tooling ────────────────────────────────────────────────────
echo -e "\n▶ Baseline tooling"

check_cmd git "Git"
check_cmd curl "curl"
check_cmd jq "jq"
check_cmd strace "strace"

# ─── 4. Network tooling ────────────────────────────────────────────────────
echo -e "\n▶ Network tooling"

for cmd in iptables ip dig; do
    check_cmd "$cmd"
done

if iptables -L -n >/dev/null 2>&1; then
    pass "iptables rules readable"
else
    fail "iptables rules readable"
fi

# ─── 5. KVM (optional — depends on host) ───────────────────────────────────
echo -e "\n▶ KVM / nested virtualization"

if [[ -e /dev/kvm ]]; then
    pass "KVM available (/dev/kvm)"
    check_cmd_optional qemu-system-x86_64 "QEMU"
    check_cmd_optional virsh "libvirt"
else
    skip "KVM not available (no nested virt on this host)"
fi

# ─── 6. Project sync ────────────────────────────────────────────────────────
echo -e "\n▶ Project"

if [[ -d /project ]]; then
    file_count=$(find /project -maxdepth 1 -type f | wc -l)
    pass "Project synced at /project ($file_count files in root)"
else
    skip "No project synced (set PROJECT_SRC to sync)"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $WARN${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $FAIL -gt 0 ]]; then
    echo -e "\n${RED}$FAIL checks failed${NC}"
    exit 1
fi

echo -e "\n${GREEN}Sandbox VM is ready — drive it with: vagrant ssh -c \"sudo <cmd>\"${NC}"
