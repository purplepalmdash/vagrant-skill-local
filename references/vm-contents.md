# VM Contents Reference

What the lifecycle-profile VM contains, and what it deliberately does not.

## Installed Software

Baseline only — enough to drive the VM over SSH with full sudo, plus
debugging and network tooling. No language toolchains, no container runtime.

| Tool | Install Method | Notes |
|------|----------------|-------|
| Ubuntu | 24.04 LTS (base box `bento/ubuntu-24.04`) | amd64 or arm64 |
| rsync | apt-get | Required by the rsync shared-folder strategy |
| curl, git, jq | apt-get | Baseline |
| ca-certificates, gnupg | apt-get | For on-demand package installs |
| iptables, netfilter-persistent | apt-get | Firewall work inside the VM only |
| iproute2, net-tools, dnsutils | apt-get | `ip`, `ifconfig`/`netstat`, `dig` |
| procps, strace, util-linux | apt-get | Debugging |
| QEMU + libvirt in guest | apt-get, **opt-in** | Only with `INSTALL_KVM_TOOLS=1` and `/dev/kvm` present |

## Deliberately Not Installed

The provisioner installs none of these. Add them in the consumer project's own
provision block, or install inside a live VM on demand.

| Tool | Why it is out |
|------|---------------|
| Docker / containerd | Heavy, pulls an apt repo, and its verification needs image pulls — unreliable from a restricted network |
| Go | Toolchain is the project's choice of version and proxy |
| mage | Only useful with Go |
| Language runtimes (Node, Python, …) | Consumer-specific |

To add one, extend the provision block:

```ruby
config.vm.provision "shell", privileged: true, inline: <<-SHELL
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq python3 python3-pip   # example
SHELL
```

## Filesystem Layout

| Path | Contents |
|------|----------|
| `/project` | Consumer project, rsynced from host (`PROJECT_SRC`) |
| `/vagrant-scripts` | This skill's directory, rsynced (`SKILL.md`, `scripts/`, `examples/`) |
| `/vagrant` | **Disabled** — the implicit folder is NFS on libvirt |
| `/vagrant-scripts/scripts/setup.sh` | Baseline provisioner |
| `/vagrant-scripts/scripts/verify.sh` | Readiness checks (14 checks) |
| Data disk (second virtio disk) | 40G qcow2 added by the libvirt provider for build artifacts |

## Networking

- libvirt default network: NAT, guest gets `192.168.121.x`, host bridge `192.168.121.1`
- NIC model pinned to `virtio`
- Host port forwarding and public networks work as in any Vagrant setup
- The VM's iptables are its own; the host firewall is never touched

## Virtualization

| Feature | Linux + libvirt | Mac + Parallels | VirtualBox |
|---------|:-:|:-:|:-:|
| Nested KVM (`/dev/kvm` in guest) | Yes (`host-passthrough`, `nested = true`) | No | Limited |
| QEMU/libvirt in guest | with `INSTALL_KVM_TOOLS=1` | No | No |
| Disk | qcow2 + 40G data disk | Parallels disk | VDI |

Verify nested KVM from the host:

```bash
test -e /dev/kvm && echo "host KVM OK"
vagrant ssh -c "test -e /dev/kvm && echo 'nested KVM OK'"
```

## apt Sources

`scripts/setup.sh` rewrites the guest's `URIs:` lines in
`/etc/apt/sources.list.d/ubuntu.sources` to `APT_MIRROR` (default
`https://mirrors.ustc.edu.cn`), stamped at `/etc/vagrant-skill-apt-mirror.stamp`
so re-runs are no-ops. Restore upstream sources with:

```bash
APT_MIRROR="" vagrant provision
```

## Readiness Checks

`scripts/verify.sh` runs after setup and reports PASS/FAIL/SKIP:

- provisioner runs as root; OS identity
- `vagrant` user exists and has **passwordless sudo**
- rsync present; no NFS client dependency in the way
- baseline tooling: git, curl, jq, strace
- network tooling: iptables (rules readable), ip, dig
- KVM: present → PASS, absent → SKIP; QEMU/libvirt are optional (opt-in)
- `/project` synced → PASS, else SKIP

Any FAIL exits non-zero, which fails the `vagrant up`.
