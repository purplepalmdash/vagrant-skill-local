# -*- mode: ruby -*-
# vagrant-skill — Disposable dev/test VM
#
# Gives AI agents (Claude Code, OpenClaw) and humans full sudo in a
# disposable VM to build, test, and break things without host risk.
#
# Providers (auto-detected by Vagrant, or force with --provider / VM_PROVIDER):
#   - libvirt    (Linux — preferred, nested KVM for microVM testing)
#   - parallels  (Mac Apple Silicon — recommended for M1/M2/M3/M4)
#   - virtualbox (Linux, Mac Intel, Windows — NOT recommended on Apple Silicon)
#
# Local (Linux + libvirt + CN network) profile — see references/local-linux-libvirt.md
#   Every host-specific choice is env-gated so the file stays portable upstream:
#     VM_PROVIDER=libvirt        force provider (default: auto-detect)
#     SYNCED_FOLDER_TYPE=rsync   NFS needs an NFS server on the host (rpc.mountd +
#                                nfsd). Linux/libvirt hosts commonly lack it, and a
#                                failed NFS mount aborts provisioning. Default: rsync.
#     APT_MIRROR=https://mirrors.ustc.edu.cn   guest apt sources (set APT_MIRROR=""
#                                for upstream sources on non-CN hosts)
#     INSTALL_KVM_TOOLS=1        install qemu-kvm + libvirt inside the VM
#
# Syncs a project directory into the VM. Set PROJECT_SRC to override:
#   PROJECT_SRC=~/myproject vagrant up
#
# Usage:
#   vagrant up                    # provision + verify
#   vagrant ssh                   # interactive shell (full sudo)
#   vagrant ssh -c "sudo ..."    # run commands from host (agent workflow)
#   vagrant destroy -f            # tear down and start fresh
#   vagrant provision             # re-run setup + verify without rebuild
#   vagrant rsync                 # push host edits into the VM

# ─── Project source resolution ───────────────────────────────────────────────
# Priority: PROJECT_SRC env var > parent directory with go.mod/package.json > none
SCRIPT_DIR = File.dirname(File.expand_path(__FILE__))
PROJECT_SRC = if ENV["PROJECT_SRC"]
    ENV["PROJECT_SRC"]
  elsif File.exist?(File.join(SCRIPT_DIR, "..", "go.mod")) ||
        File.exist?(File.join(SCRIPT_DIR, "..", "package.json")) ||
        File.exist?(File.join(SCRIPT_DIR, "..", "Makefile"))
    File.expand_path(File.join(SCRIPT_DIR, ".."))
  else
    nil
  end

if PROJECT_SRC
  puts "Project source: #{PROJECT_SRC}"
else
  puts "No project source detected (set PROJECT_SRC to sync a project into the VM)"
end

# ─── VM Configuration ────────────────────────────────────────────────────────
# Unique per-checkout slug for libvirt domain naming (see the libvirt provider).
VM_SLUG = File.basename(SCRIPT_DIR).gsub(/[^A-Za-z0-9]/, "_")

VM_CPUS   = Integer(ENV["VM_CPUS"]   || 4)
VM_MEMORY = Integer(ENV["VM_MEMORY"] || 4096)
VM_NAME   = ENV["VM_NAME"] || "vagrant-skill-dev"

# Shared-folder mechanism. NFS is the provider default on libvirt and fails on
# hosts without an NFS server; rsync needs nothing on the host.
SYNC_TYPE = ENV["SYNCED_FOLDER_TYPE"] || "rsync"
RSYNC_EXCLUDE = [
  ".git/", "node_modules/", "vendor/", "bin/", "dist/",
  "build/", ".next/", "coverage.out", "coverage.html",
]

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-24.04"
  config.vm.box_check_update = false
  config.vm.hostname = VM_NAME
  config.vm.boot_timeout = 300
  config.ssh.forward_agent = true

  # Pin the provider when VM_PROVIDER is set (CI/agent runs, multi-provider hosts).
  config.vm.provider ENV["VM_PROVIDER"] if ENV["VM_PROVIDER"]

  # ─── Provider: libvirt (Linux — preferred, nested KVM) ──────────────────
  # Install: apt-get install vagrant-libvirt (or vagrant plugin install vagrant-libvirt)
  config.vm.provider "libvirt" do |lv|
    lv.cpus   = VM_CPUS
    lv.memory = VM_MEMORY
    lv.cpu_mode = "host-passthrough"   # nested KVM
    lv.nested = true
    # Domain prefix must be unique per checkout, or two copies of this repo
    # claim the same libvirt domain. Derived from the directory name; override
    # with VM_PREFIX. Changing the prefix renames the domain (destroy + up).
    lv.default_prefix = ENV["VM_PREFIX"] || "vagrant_skill_#{VM_SLUG}_"
    lv.nic_model_type = "virtio"
    # qemu:///system (not the session URI): the plugin talks to the system
    # daemon, which is socket-activated on Ubuntu 24.04 — `systemctl is-active
    # libvirtd` shows "inactive" until a client connects, so probe with virsh.
    lv.qemu_use_session = false
    # Extra data disk for Docker images/build caches (box root is tight).
    lv.storage :file, size: "40G", type: "qcow2"
  end

  # ─── Provider: Parallels (Mac Apple Silicon — recommended) ───────────────
  # Install: brew install --cask parallels && vagrant plugin install vagrant-parallels
  config.vm.provider "parallels" do |prl|
    prl.cpus   = VM_CPUS
    prl.memory = VM_MEMORY
    prl.name   = VM_NAME
    prl.update_guest_tools = true
  end

  # ─── Provider: VirtualBox (Linux, Mac Intel, Windows) ───────────────────
  # WARNING: VirtualBox on Apple Silicon is experimental and very slow.
  #          Use Parallels on Mac M-series instead.
  config.vm.provider "virtualbox" do |vb|
    vb.cpus   = VM_CPUS
    vb.memory = VM_MEMORY
    vb.customize ["modifyvm", :id, "--nested-hw-virt", "on"]
    vb.name = VM_NAME
  end

  # ─── Sync project source (if detected) ──────────────────────────────────
  if PROJECT_SRC
    config.vm.synced_folder PROJECT_SRC, "/project",
      type: SYNC_TYPE, rsync__exclude: RSYNC_EXCLUDE
  end

  # Sync vagrant-skill scripts into the VM.
  # type is env-gated (see SYNC_TYPE): libvirt defaults to NFS, which needs a
  # host NFS server (rpc.mountd + nfsd). A failed NFS mount aborts provisioning.
  config.vm.synced_folder ".", "/vagrant-scripts",
    type: SYNC_TYPE, rsync__exclude: RSYNC_EXCLUDE + [".vagrant/"]

  # Never let the provider create the implicit /vagrant folder — on libvirt it
  # is NFS by default and adds the same host-side dependency.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # ─── Provision: install deps ─────────────────────────────────────────────
  # Extra env vars reach the guest provisioner (CN mirrors, Go version, ...).
  config.vm.provision "setup", type: "shell" do |s|
    s.path = "scripts/setup.sh"
    s.privileged = true
    s.env = {
      "APT_MIRROR"        => ENV["APT_MIRROR"]     || "https://mirrors.ustc.edu.cn",
      "INSTALL_KVM_TOOLS" => ENV["INSTALL_KVM_TOOLS"] || "0",
    }
  end

  # ─── Provision: verify everything works ──────────────────────────────────
  config.vm.provision "verify", type: "shell" do |s|
    s.path = "scripts/verify.sh"
    s.privileged = true
  end
end
