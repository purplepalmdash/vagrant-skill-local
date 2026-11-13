---
name: vagrant
description: >-
  Disposable Ubuntu VMs driven from the host — boot, drive over SSH with full
  sudo, sync files, halt, bring back up, and destroy. Use when you need an
  isolated sandbox to build, test, run privileged commands (sudo, iptables,
  systemd), or break things without affecting the host. Use when the user says
  "spin up a VM", "test in isolation", "run with sudo", "try something
  dangerous", "set up a dev environment", "clean environment", "start/stop the
  sandbox", or needs root access, network testing, or safe experimentation.
  Linux/libvirt tuned: no NFS server, no Docker, no Go in the guest.
license: Apache-2.0
compatibility: >-
  Requires the vagrant binary and a provider: libvirt (Linux — this profile's
  default), Parallels (Mac Apple Silicon), or VirtualBox (cross-platform).
  Guest needs no network service beyond apt. Designed for terminal-based AI
  agents and interactive developer use.
allowed-tools: "Bash(vagrant:*) Bash(bats:*) Read Write"
metadata:
  author: jpoley
  version: "0.8.0"
  category: infrastructure
  tags: [vm, sandbox, testing, devops, isolation, kvm, lifecycle]
  openclaw:
    requires:
      bins:
        - vagrant
      anyBins:
        - virsh
        - VBoxManage
        - prlctl
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Execution Instructions

This skill is a **VM lifecycle driver**. It boots a disposable Ubuntu 24.04 VM,
gives you unrestricted root inside it over SSH, syncs a project in, and tears
the whole thing down. All privileged operations (sudo, iptables, systemd,
kernel modules) happen inside the VM — the host is never modified.

**Scope of this profile: start, drive, halt, bring back up, destroy.** The VM
ships with a small baseline (rsync, curl, git, jq, iptables, ip, dig, strace).
It does **not** install Docker, Go, mage, or any language toolchain — that is
the consumer project's job (add it in the Vagrantfile's provision block, or
install it inside the VM on demand).

**You (the agent) should NEVER need host-level sudo.** Get root by running
commands inside the VM.

### Prerequisites

```bash
command -v vagrant                       # the binary

command -v virsh                         # libvirt (Linux — this host's provider)
vagrant plugin list | grep libvirt       # vagrant-libvirt plugin
command -v prlctl                        # Parallels (Mac Apple Silicon)
command -v VBoxManage                    # VirtualBox (fallback)

vagrant box list                         # base box must be cached: bento/ubuntu-24.04
```

On Ubuntu 24.04 the libvirt daemon is **socket-activated**: `systemctl is-active
libvirtd` reports `inactive` even when everything works. Probe with the client
instead of trusting the service state:

```bash
virsh -c qemu:///system list --all       # returns a table => provider is usable
```

See [references/platform-setup.md](references/platform-setup.md) for provider
installation on each platform.

---

## Core Workflow

### Step 1: Create a Vagrantfile in the User's Project

If the user's project does not already have a `Vagrantfile`, you MUST create a
real, working one in their project directory — not a template: it has to work
end-to-end with `vagrant up`.

Requirements for the Vagrantfile you create:
- Base box: `bento/ubuntu-24.04`
- Sync the project into the VM: `config.vm.synced_folder ".", "/project", type: "rsync"`
- Declare all three providers so the file works on any host
- Provision with the tools the project actually needs — inspect the project
  first (`go.mod`, `package.json`, `requirements.txt`, `Makefile`, `Dockerfile`)
  and add only those. Do not leave placeholder comments in the final file.
- `set -euo pipefail` in provisioning scripts, and make provisioning idempotent
- Never rely on NFS shared folders (see Troubleshooting)

Base Vagrantfile (customize the provisioning block for the project):

```ruby
# -*- mode: ruby -*-
# Vagrantfile — disposable dev/test VM

VM_CPUS   = Integer(ENV["VM_CPUS"]   || 4)
VM_MEMORY = Integer(ENV["VM_MEMORY"] || 4096)

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-24.04"
  config.vm.box_check_update = false
  config.vm.hostname = "dev"
  config.vm.boot_timeout = 300
  config.ssh.forward_agent = true

  # rsync, not NFS: libvirt defaults to NFS, which needs an NFS server on the
  # host (rpc.mountd + nfsd). A failed NFS mount aborts provisioning.
  config.vm.synced_folder ".", "/project", type: "rsync",
    rsync__exclude: [".git/", "node_modules/", "vendor/", ".vagrant/",
                     "bin/", "dist/", "build/", ".next/"]

  # The implicit /vagrant folder is NFS on libvirt — disable it.
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
    lv.qemu_use_session = false      # talk to the system daemon, not the session URI
  end

  config.vm.provider "virtualbox" do |vb|
    vb.cpus   = VM_CPUS
    vb.memory = VM_MEMORY
    vb.customize ["modifyvm", :id, "--nested-hw-virt", "on"]
  end

  # CUSTOMIZE THIS: inspect go.mod / package.json / requirements.txt / Makefile
  # and install what the project needs. Keep it idempotent.
  config.vm.provision "shell", privileged: true, inline: <<-SHELL
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl git jq rsync
    echo "VM ready — project synced at /project"
  SHELL
end
```

Then **add `.vagrant/` to the user's `.gitignore`** if it is not already there:

```bash
grep -qxF '.vagrant/' .gitignore 2>/dev/null || echo '.vagrant/' >> .gitignore
```

The Vagrantfile itself **should be committed** — it is reusable project
infrastructure. If the user already has a `Vagrantfile`, use it as-is unless
they ask you to modify it.

### Step 2: Boot the VM

```bash
vagrant up                                  # boot + provision + verify
vagrant up --provider=libvirt               # pin the provider
VM_CPUS=8 VM_MEMORY=8192 vagrant up         # sizing
```

### Step 3: Drive It Over SSH

All commands run from the host with `vagrant ssh -c`; no interactive session.

```bash
vagrant ssh -c "whoami; sudo -n id -un"          # identity + sudo
vagrant ssh -c "sudo apt-get install -y <pkg>"   # privileged install
vagrant ssh -c "sudo iptables -L -n"             # firewall inspection
vagrant ssh -c "cd /project && <build cmd>"      # project work
```

### Step 4: Iterate on Code Changes

```bash
vagrant rsync                                # push host edits into the VM
vagrant ssh -c "cd /project && make test"    # re-run
```

### Step 5: Halt, Bring Back Up, Suspend

Halting keeps the disk (provisioned state survives); destroying does not.

```bash
vagrant status            # state of this machine
vagrant halt              # shut down, keep everything
vagrant up                # bring it back up (no reprovision)
vagrant suspend           # save RAM to disk, near-instant resume
vagrant resume
vagrant global-status     # every Vagrant VM on this host
```

### Step 6: Tear Down

```bash
vagrant destroy -f        # remove the VM and its disk completely
```

---

## Testing Patterns

### Pattern: Build-Test-Fix Loop

```bash
vagrant rsync && vagrant ssh -c "cd /project && make build"
vagrant ssh -c "cd /project && make test"
# fix on the host, then repeat
```

### Pattern: Lifecycle Smoke (the fastest proof the skill works)

```bash
vagrant up
vagrant ssh -c "echo SSH_OK; sudo -n id -un"
vagrant halt && vagrant status && vagrant up
vagrant destroy -f
```

`vagrant ssh -c` exiting 0 is the pass criterion.

### Pattern: Network / Firewall Testing

```bash
vagrant ssh -c "sudo iptables -A FORWARD -s 172.16.0.0/24 -j DROP"
vagrant ssh -c "sudo iptables -L -n -v"
vagrant ssh -c "sudo netfilter-persistent save"   # persist inside the VM only
```

### Pattern: systemd Unit Testing

```bash
vagrant ssh -c "sudo cp /project/myservice.service /etc/systemd/system/"
vagrant ssh -c "sudo systemctl daemon-reload && sudo systemctl start myservice"
vagrant ssh -c "systemctl status myservice --no-pager"
vagrant ssh -c "sudo journalctl -u myservice --no-pager"
```

### Pattern: bats End-to-End Tests

Run a [bats-core](https://github.com/bats-core/bats-core) suite against a live
VM as proof. The VM must be up first. bats exits non-zero on any failure —
treat that as a failed run.

```bash
vagrant up
bats test/e2e.bats 2>&1 | tee /tmp/bats-results.txt
vagrant destroy -f
cat /tmp/bats-results.txt
```

`bats` is a host-side tool: `sudo apt-get install -y bats`.

### Pattern: Full Reprovision (Nuclear Option)

```bash
vagrant destroy -f && vagrant up
```

### Rule: Do Not Verify With The Network

Image pulls (`docker run hello-world`), `go install` of remote modules, and
`apt-get` from upstream mirrors can hang for minutes on a restricted network.
Verify with local signals only: binary presence, daemon state, `iptables -L`,
synced file counts. Treat a network-dependent check as inconclusive, not as a
pass.

---

## Configuration

Environment variables, set before `vagrant up`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `VM_CPUS` | 4 | vCPUs |
| `VM_MEMORY` | 4096 | RAM in MB |
| `VM_NAME` | vagrant-skill-dev | VM hostname / domain name |
| `VM_PROVIDER` | auto-detect | Pin the provider (`libvirt` on Linux) |
| `PROJECT_SRC` | auto-detect | Host directory synced to `/project` |
| `SYNCED_FOLDER_TYPE` | rsync | Share mechanism; `nfs` needs a host NFS server |
| `APT_MIRROR` | `https://mirrors.ustc.edu.cn` | Guest apt mirror; `""` = upstream |
| `INSTALL_KVM_TOOLS` | 0 | Set 1 to install qemu-kvm + libvirt in the guest |

```bash
VM_CPUS=8 VM_MEMORY=8192 vagrant up
PROJECT_SRC=~/myapp vagrant up
APT_MIRROR="" vagrant provision        # switch the guest back to upstream apt
```

See [references/vm-contents.md](references/vm-contents.md) for the guest
filesystem and package list.

## Safety Guarantees

- **No host sudo required** — privileged work happens inside the VM
- **Fully disposable** — `vagrant destroy -f` removes the VM and its disk
- **Idempotent provisioning** — `vagrant provision` is safe to re-run
- **Isolated networking** — the VM has its own network stack behind the libvirt NAT
- **Source is rsynced** — the VM gets a copy; your host repo is never modified by the VM
- **No host-side daemons** — no NFS server, no shared folders that need host services
- **Vagrantfile is committed** — reusable across sessions; `.vagrant/` is gitignored

## Examples

### Example 1: Firewall rules without touching the host

1. Create the Vagrantfile (network tools come from the baseline)
2. `vagrant up`
3. `vagrant ssh -c "sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT"`
4. `vagrant ssh -c "sudo iptables -A INPUT -p tcp --dport 0:442 -j DROP"`
5. `vagrant ssh -c "sudo iptables -L -n -v"` — verify
6. `vagrant ssh -c "sudo iptables-save > /project/firewall.rules"` then `vagrant rsync`
7. `vagrant destroy -f` to scrap, or `vagrant halt` to keep for the next session

Result: rules iterated with real iptables; the host network is untouched.

### Example 2: systemd unit file before deploying

1. `vagrant up`
2. `vagrant ssh -c "sudo cp /project/myservice.service /etc/systemd/system/"`
3. `vagrant ssh -c "sudo systemctl daemon-reload && sudo systemctl start myservice"`
4. `vagrant ssh -c "systemctl status myservice --no-pager"`
5. `vagrant ssh -c "sudo journalctl -u myservice --no-pager"`
6. `vagrant destroy -f`

Result: real systemd and journald, zero risk to the host init system.

### Example 3: Long-running work, halted between sessions

1. `vagrant up` → work with `vagrant ssh -c`
2. End of session: `vagrant halt`
3. Next session: `vagrant up` (state and installed packages survive), `vagrant rsync`
4. Done for good: `vagrant destroy -f`

### Example 4: Built-in examples

Two examples live under `examples/` in this skill's directory; each has its own
Vagrantfile, `scripts/provision.sh`, and bats suite:

- `examples/nginx-hardened/` — nginx + hardened iptables (16 tests). **Why a VM:**
  `iptables -P INPUT DROP` on the host locks you out of your own SSH session.
- `examples/windows-systemd-service/` — a Python HTTP server as a real systemd
  unit under a dedicated user (20 tests). **Why a VM:** WSL2 has no real systemd.

```bash
cd examples/<name>
vagrant up
bats test/e2e.bats 2>&1 | tee /tmp/e2e-results.txt
vagrant destroy -f
```

## Troubleshooting

### NFS mount failure on the shared folder

**Error:** `mount.nfs: requested NFS version or transport protocol is not supported`
**Cause:** libvirt defaults shared folders to NFS, and the host has no NFS server
(`rpc.mountd` / `nfsd` absent). The failed mount aborts provisioning.
**Fix:** use rsync — `type: "rsync"` on every `synced_folder`, plus
`config.vm.synced_folder ".", "/vagrant", disabled: true`. Then
`vagrant reload --provision` (changing a synced folder needs a reload;
`vagrant rsync` alone does not reconfigure it).

### libvirt looks "not running"

**Symptom:** `systemctl is-active libvirtd` says `inactive`, `vagrant status`
fails with `Error while connecting to Libvirt ... Timeout was reached`.
**Cause:** Ubuntu 24.04 socket-activates the daemon; the service unit reads
inactive until a client connects. A cold start can also time out once.
**Fix:** probe with `virsh -c qemu:///system list --all`; retry the vagrant
command. `vagrant plugin list` must show `vagrant-libvirt`.

### VM Won't Boot

1. `vagrant plugin list`, `vagrant box list` (the box must be cached)
2. `vagrant up --debug 2>&1 | tail -50`
3. Force the provider: `vagrant up --provider=libvirt`

### Provider Mismatch

1. `vagrant status` / `vagrant global-status --prune`
2. `vagrant up --provider=parallels` (or set `VM_PROVIDER`)

### /project Is Empty Inside The VM

1. `vagrant rsync`
2. Confirm the Vagrantfile has `synced_folder ".", "/project", type: "rsync"`
3. `PROJECT_SRC=<path> vagrant up` when the auto-detect finds no project

### apt Is Slow Or Fails In The Guest

`APT_MIRROR` rewrites the guest's `ubuntu.sources` URIs (default USTC). On a
host with good upstream access, set `APT_MIRROR=""` and re-provision.

### KVM Not Available Inside The VM

1. Host: `test -e /dev/kvm`
2. libvirt provider with `cpu_mode = "host-passthrough"` and `nested = true`
3. Nested KVM is not available on Mac — use a Linux host for that work
4. Guest tools are opt-in: `INSTALL_KVM_TOOLS=1 vagrant up`
