#!/usr/bin/env bats
# Tests for Vagrantfile syntax and configuration.

VAGRANTFILE="$BATS_TEST_DIRNAME/../Vagrantfile"

@test "Vagrantfile exists" {
  [ -f "$VAGRANTFILE" ]
}

@test "Vagrantfile has valid Ruby syntax" {
  ruby -c "$VAGRANTFILE"
}

@test "Vagrantfile configures parallels provider" {
  grep -q 'config.vm.provider "parallels"' "$VAGRANTFILE"
}

@test "Vagrantfile configures libvirt provider" {
  grep -q 'config.vm.provider "libvirt"' "$VAGRANTFILE"
}

@test "Vagrantfile configures virtualbox provider" {
  grep -q 'config.vm.provider "virtualbox"' "$VAGRANTFILE"
}

@test "Vagrantfile warns about VirtualBox on Apple Silicon" {
  grep -q 'Apple Silicon' "$VAGRANTFILE"
}

@test "Vagrantfile uses bento/ubuntu-24.04 box" {
  grep -q 'bento/ubuntu-24.04' "$VAGRANTFILE"
}

@test "Vagrantfile enables nested KVM for libvirt" {
  grep -q 'host-passthrough' "$VAGRANTFILE"
  grep -q 'lv.nested = true' "$VAGRANTFILE"
}

@test "Vagrantfile enables nested VT-x for VirtualBox" {
  grep -q 'nested-hw-virt' "$VAGRANTFILE"
}

@test "Vagrantfile supports PROJECT_SRC env var" {
  grep -q 'PROJECT_SRC' "$VAGRANTFILE"
}

@test "Vagrantfile supports VM_CPUS env var" {
  grep -q 'VM_CPUS' "$VAGRANTFILE"
}

@test "Vagrantfile supports VM_MEMORY env var" {
  grep -q 'VM_MEMORY' "$VAGRANTFILE"
}

@test "Vagrantfile defaults shared folders to rsync (no host NFS server)" {
  grep -q 'SYNCED_FOLDER_TYPE' "$VAGRANTFILE"
  grep -q 'type: SYNC_TYPE' "$VAGRANTFILE"
}

@test "Vagrantfile disables the implicit NFS /vagrant folder" {
  grep -q 'config.vm.synced_folder ".", "/vagrant", disabled: true' "$VAGRANTFILE"
}

@test "Vagrantfile pins libvirt to the system qemu URI" {
  grep -q 'lv.qemu_use_session = false' "$VAGRANTFILE"
}

@test "Vagrantfile supports VM_PROVIDER env var" {
  grep -q 'VM_PROVIDER' "$VAGRANTFILE"
}

@test "Vagrantfile passes APT_MIRROR and INSTALL_KVM_TOOLS to the provisioner" {
  grep -q '"APT_MIRROR"' "$VAGRANTFILE"
  grep -q '"INSTALL_KVM_TOOLS"' "$VAGRANTFILE"
}

@test "Vagrantfile does NOT install Docker or Go" {
  ! grep -q 'docker-ce\|golang\|install_go' "$VAGRANTFILE"
}

@test "Vagrantfile does NOT reference nanofuse" {
  ! grep -qi 'nanofuse' "$VAGRANTFILE"
}

@test "Vagrantfile does NOT reference firecracker" {
  ! grep -qi 'firecracker' "$VAGRANTFILE"
}
