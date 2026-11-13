#!/usr/bin/env bats
# Integration tests — boots a real VM and tests the VM lifecycle the skill
# exists for: boot, drive over SSH with sudo, sync, halt, bring back up,
# destroy. Also asserts the local (Linux/libvirt/CN) profile contract:
# rsync shares (no host NFS server), apt mirror, and NO Docker/Go toolchain.
#
# Run: bats test/integration.bats
# Or:  make test-integration
#
# Nothing here pulls from Docker Hub, Go module proxies, or overseas download
# endpoints. Every assertion is a local signal.

TEST_DIR="/tmp/vagrant-skill-integration-test"
VGR="timeout 900 vagrant"

setup_file() {
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR"

  echo '.vagrant/' > "$TEST_DIR/.gitignore"

  # Minimal project — just enough to test syncing
  cat > "$TEST_DIR/Makefile" << 'EOF'
.PHONY: test
test:
	@echo "tests passed"
EOF

  # Vagrantfile with the local profile — rsync shares, no toolchain
  cat > "$TEST_DIR/Vagrantfile" << 'VEOF'
VM_CPUS   = Integer(ENV["VM_CPUS"]   || 2)
VM_MEMORY = Integer(ENV["VM_MEMORY"] || 2048)

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-24.04"
  config.vm.box_check_update = false
  config.vm.hostname = "integration-test"
  config.vm.boot_timeout = 600
  config.ssh.forward_agent = true

  config.vm.synced_folder ".", "/project", type: "rsync",
    rsync__exclude: [".git/", ".vagrant/"]
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider "parallels" do |prl|
    prl.cpus   = VM_CPUS
    prl.memory = VM_MEMORY
    prl.update_guest_tools = true
  end

  config.vm.provider "libvirt" do |lv|
    lv.cpus   = VM_CPUS
    lv.memory = VM_MEMORY
    lv.cpu_mode = "host-passthrough"
    lv.nested = true
    lv.nic_model_type = "virtio"
    lv.qemu_use_session = false
  end

  config.vm.provider "virtualbox" do |vb|
    vb.cpus   = VM_CPUS
    vb.memory = VM_MEMORY
    vb.customize ["modifyvm", :id, "--nested-hw-virt", "on"]
  end

  # Mirrors scripts/setup.sh (baseline + apt mirror); kept inline so the
  # suite is self-contained and portable.
  config.vm.provision "shell", privileged: true, inline: <<-SHELL
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    sed -ri "s#^(URIs: *)https?://(archive|security)[.]ubuntu[.]com/ubuntu/?#\1https://mirrors.ustc.edu.cn/ubuntu/#" /etc/apt/sources.list.d/ubuntu.sources
    apt-get update -qq
    apt-get install -y -qq rsync curl git jq ca-certificates gnupg iptables netfilter-persistent iptables-persistent dnsutils net-tools iproute2 procps strace util-linux > /dev/null
  SHELL
end
VEOF

  cd "$TEST_DIR"
  $VGR up >/dev/null 2>&1 || true
}

teardown_file() {
  cd "$TEST_DIR"
  $VGR destroy -f >/dev/null 2>&1 || true
  rm -rf "$TEST_DIR"
}

ssh() { $VGR ssh -c "$1" 2>/dev/null; }

# ─── Boot ────────────────────────────────────────────────────────────────────

@test "VM boots and reports running" {
  cd "$TEST_DIR"
  $VGR status 2>/dev/null | grep -q "running"
}

@test "vagrant ssh works (the pass criterion for this skill)" {
  cd "$TEST_DIR"
  run ssh "echo SSH_OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *SSH_OK* ]]
}

@test "vagrant user has passwordless root inside the VM" {
  cd "$TEST_DIR"
  [ "$(ssh 'sudo -n id -un')" = "root" ]
}

@test "guest is the expected Ubuntu 24.04 box" {
  cd "$TEST_DIR"
  ssh 'grep -q "Ubuntu 24.04" /etc/os-release'
}

# ─── Local profile contract ─────────────────────────────────────────────────

@test "shared folder is rsync, not NFS" {
  cd "$TEST_DIR"
  run ssh 'mount | grep -c "type nfs" || true'
  [ "$output" = "0" ]
}

@test "baseline tooling is installed by setup.sh" {
  cd "$TEST_DIR"
  ssh 'for c in rsync git curl jq iptables ip dig strace; do command -v $c >/dev/null || exit 1; done'
}

@test "setup.sh installs NO Docker (lifecycle profile)" {
  cd "$TEST_DIR"
  run ssh 'command -v docker || echo ABSENT'
  [[ "$output" == *ABSENT* ]]
}

@test "setup.sh installs NO Go toolchain (lifecycle profile)" {
  cd "$TEST_DIR"
  run ssh 'test -x /usr/local/go/bin/go && echo PRESENT || echo ABSENT'
  [[ "$output" == *ABSENT* ]]
}

@test "apt mirror was rewritten to APT_MIRROR (default USTC)" {
  cd "$TEST_DIR"
  ssh 'grep -q "mirrors.ustc.edu.cn" /etc/apt/sources.list.d/ubuntu.sources'
}

# ─── Drive + sync loop ──────────────────────────────────────────────────────

@test "project is synced at /project" {
  cd "$TEST_DIR"
  ssh 'test -f /project/Makefile'
}

@test "vagrant rsync pushes host edits into the VM" {
  cd "$TEST_DIR"
  echo "marker-$$" > "$TEST_DIR/sync-marker.txt"
  $VGR rsync >/dev/null 2>&1
  ssh 'grep -q "marker" /project/sync-marker.txt'
}

@test "project work runs inside the VM" {
  cd "$TEST_DIR"
  run ssh 'cd /project && make test'
  [[ "$output" == *"tests passed"* ]]
}

@test "privileged iptables rule can be added and removed" {
  cd "$TEST_DIR"
  ssh 'sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT && sudo iptables -S INPUT | grep -q 8080 && sudo iptables -D INPUT -p tcp --dport 8080 -j ACCEPT'
}

@test "systemd unit can be installed, started, and read from journald" {
  cd "$TEST_DIR"
  ssh 'sudo tee /etc/systemd/system/skill-probe.service >/dev/null << "U"
[Unit]
Description=vagrant-skill probe
[Service]
ExecStart=/bin/sh -c "mkdir -p /var/lib/probe && echo skill-probe > /var/lib/probe/log"
Type=oneshot
U
sudo systemctl daemon-reload && sudo systemctl start skill-probe.service && grep -q skill-probe /var/lib/probe/log'
}

@test "provisioning is idempotent (re-run exits 0)" {
  cd "$TEST_DIR"
  $VGR provision >/dev/null 2>&1
  $VGR provision >/dev/null 2>&1
}

# ─── Halt / bring back up ───────────────────────────────────────────────────

@test "vagrant halt stops the VM" {
  cd "$TEST_DIR"
  $VGR halt >/dev/null 2>&1
  $VGR status 2>/dev/null | grep -qE "poweroff|not running"
}

@test "vagrant up brings it back and SSH works again" {
  cd "$TEST_DIR"
  $VGR up >/dev/null 2>&1
  run ssh "echo SSH_OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *SSH_OK* ]]
}

@test "installed state survives halt and up" {
  cd "$TEST_DIR"
  ssh 'test -f /var/lib/probe/log'   # /tmp is tmpfs on 24.04; assert on the disk
}
