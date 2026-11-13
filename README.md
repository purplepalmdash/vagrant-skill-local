# vagrant-skill（本机调优档 / Linux + libvirt）

一次性 Ubuntu 24.04 虚拟机的**生命周期驱动**技能：启动、通过 SSH 以完整 root 权限操作、同步文件、关停、拉起、销毁。

这不是上游技能的复刻。它按**这台机器实测到的事实**裁剪：只有 libvirt、主机没有 NFS 服务端（现已配好，见下文）、出境网络不稳、`/dev/kvm` 可用。每一条都编成 `Vagrantfile` 里的 env 门控默认值。

- 上游：[daax-dev/vagrant-skill](https://github.com/daax-dev/vagrant-skill)
- 本仓库 = 本档，与上游分歧见[末节](#与上游的分歧)
- 许可：Apache-2.0

## 它做什么，不做什么

| 做 | 不做 |
|---|---|
| `vagrant up` 起机器、`vagrant ssh -c` 在机器里以 root 干活、`vagrant rsync` 推代码、`vagrant halt` 关停、`vagrant up` 拉起、`vagrant destroy -f` 销毁 | 不装 Docker、不装 Go、不装 mage、不装任何语言工具链 —— 那是消费项目自己的 provision 段该干的事 |

VM 里只有基线：`rsync` `curl` `git` `jq` `iptables` `netfilter-persistent` `iproute2` `dnsutils` `net-tools` `procps` `strace` `util-linux`。guest 内的 QEMU/libvirt 是可选的（`INSTALL_KVM_TOOLS=1`）。

## 安装为技能

目录名必须叫 `vagrant`（与 `SKILL.md` 的 `name` 一致，`skills-ref` 校验才过）：

```bash
git clone git@github.com:purplepalmdash/vagrant-skill-local.git ~/.pi/agent/skills/vagrant
```

Claude Code 用 `~/.claude/skills/vagrant`。bats 是**主机**工具：`sudo apt-get install -y bats`。

## 快速上手

```bash
vagrant up                                # 启动 + provision + verify
vagrant ssh -c "sudo -n id -un"           # 机器里拿 root（主机不需要 sudo）
vagrant ssh -c "cd /project && make test"
vagrant rsync                             # 主机改完推进去
vagrant halt                              # 关停，磁盘状态保留
vagrant up                                # 拉起
vagrant status / vagrant global-status
vagrant destroy -f                        # 彻底销毁
```

## 本机实测条件（profile 的每一条都由这些决定）

| 实测到的事实 | 对应处理 |
|---|---|
| 只有 libvirt（`vagrant-libvirt 0.12.2`），无 Parallels/VirtualBox | 文档默认 libvirt；`VM_PROVIDER` 可钉住 |
| 主机曾无 NFS 服务端，`mount.nfs` 中断 provision | 共享目录默认 **rsync**（`SYNCED_FOLDER_TYPE`），并禁用隐式 `/vagrant` |
| libvirtd 是 socket 激活：`systemctl is-active libvirtd` 显示 `inactive` 但 provider 可用 | `lv.qemu_use_session = false`；探活用 `virsh -c qemu:///system list --all`，别看 systemctl |
| box 已缓存 `bento/ubuntu-24.04 (libvirt, 0)` | `vagrant up` 无需下载镜像 |
| 出境网络不稳 | guest apt 默认改写为 `APT_MIRROR=https://mirrors.ustc.edu.cn`（stamp 幂等；`APT_MIRROR=""` 回上游）；**测试里零联网断言** |
| 主机 `/dev/kvm` 存在且 `nested=Y` | `cpu_mode = host-passthrough` + `nested = true`，guest 内 `/dev/kvm` 可见 |
| 同一仓库多份 checkout 会抢同一个 libvirt domain | 域名前缀按 checkout 目录名派生（`VM_PREFIX` 可覆盖） |

## 共享目录：rsync 与 NFS 的实测对比

Vagrant 的 NFS 默认参数是 `vers=3,udp`，**这台机器上挂不上**。从 guest 打主机服务端的参数矩阵：

| 参数 | 结果 |
|---|---|
| `vers=4` / `vers=4.2` | 挂载成功 |
| `vers=3,tcp` | 挂载成功 |
| `vers=3,udp`（Vagrant 默认） | 失败：`an incorrect mount option was specified` |

要让 NFS 可用，主机侧需要（本档作者已配）：

```bash
sudo systemctl enable --now nfs-server rpcbind
# /etc/nfs.conf: [nfsd] udp=y tcp=y vers3=y vers4=y；[mountd] port=20048
sudo systemctl restart nfs-server
```

两条路径的实测结果：

| | rsync（默认） | NFS（`SYNCED_FOLDER_TYPE=nfs`） |
|---|---|---|
| provision 结果 | PASS 15 / FAIL 0 / SKIP 3 | PASS 15 / FAIL 0 / SKIP 3 |
| guest 挂载 | 无（`mount` 里 0 条 nfs） | `type nfs4` |
| 主机新文件何时可见 | `vagrant rsync` **之后** | **立即**，无需 rsync |
| 方向 | **单向**：guest 写的文件主机看不到 | 双向 |
| 吞吐 | 200 MB 推送 3.65 秒 | guest→主机写 691 MB/s（dd 200MB conv=fsync） |
| 主机依赖 | 无 | 需要 nfs-server + rpcbind + nfsd 开 UDP |

默认仍是 rsync：不依赖主机守护进程，符合「主机零改动」的技能边界。要实时双向就切 NFS。

## 配置项

| 变量 | 默认 | 作用 |
|---|---|---|
| `VM_CPUS` | 4 | vCPU |
| `VM_MEMORY` | 4096 | 内存 MB |
| `VM_NAME` | vagrant-skill-dev | 主机名 |
| `VM_PROVIDER` | 自动探测 | 钉住 provider |
| `PROJECT_SRC` | 自动探测 | 同步到 `/project` 的目录 |
| `SYNCED_FOLDER_TYPE` | rsync | 共享方式，`nfs` 需主机 NFS 服务端 |
| `NFS_VERSION` / `NFS_UDP` | `4.2` / 关 | 仅当 `SYNCED_FOLDER_TYPE=nfs` |
| `APT_MIRROR` | USTC | guest apt 源；`""` = 上游 |
| `INSTALL_KVM_TOOLS` | 0 | 置 1 在 guest 内装 qemu-kvm + libvirt |
| `VM_PREFIX` | 按目录派生 | libvirt 域名前缀 |

## 验证方法

```bash
make lint                                                      # shellcheck + ruby -c
bats test/scripts.bats test/skill.bats test/vagrantfile.bats   # 单元
vagrant up && vagrant ssh -c "echo SSH_OK; sudo -n id -un"     # 判据：ssh 返回 0
bats test/integration.bats                                     # 生命周期套件（真起机器）
```

本机实跑结果：单元 **74 通过 / 0 失败**；生命周期集成 **18 通过 / 0 失败**（up → ssh → sudo → 无 NFS 挂载 → 基线 → 无 docker → 无 go → apt mirror → `/project` 同步 → rsync 推送 → VM 内 `make` → iptables 增删 → systemd+journald → provision 幂等×2 → halt → 拉起 → 状态存活 → destroy）；`shellcheck` 干净；`ruby -c` ×3 通过。

**不要用联网动作做验证**：`docker run hello-world`、远程 `go install`、上游 apt 源都可能长时间卡住，卡住不等于通过。只认本地信号：二进制存在、守护进程状态、`iptables -L`、同步文件计数。

## 已知坑（都是踩过的）

- **`vagrant destroy -f` 可能抛栈**：最后一台用 `vagrant-libvirt` 私有网络的机器销毁时插件会自删该网络，随后查 IP 就报 `Network not found: vagrant-libvirt`。绕过：`virsh -c qemu:///system destroy <域名>` + `virsh -c qemu:///system undefine <域名>`，再清 `.vagrant/`。网络会在下次 `vagrant up` 自动重建。
- **附加数据盘会破坏 destroy 幂等**：`lv.storage :file` 加的盘在 destroy 后残留，下次同域名 up 报 `storage volume ... exists already`。本档**不加**附加盘。
- **删 libvirt 卷要按域名精确匹配**：用 `awk '/vagrant/'` 这类子串过滤会连 box 的拷贝卷一起删。
- **改 `synced_folder` 需要 `vagrant reload --provision`**，单跑 `vagrant rsync` 不会重配挂载。
- 主机 NFS 配置回滚：`sudo systemctl disable --now nfs-server`（备份 `/etc/nfs.conf.vagrant-skill.bak`）。

## 与上游的分歧

本档相对上游 `daax-dev/vagrant-skill`：

- `scripts/setup.sh` 删掉 Docker / Go / mage 三段安装
- `scripts/verify.sh` 删掉 Docker / Go / mage 检查，改为就绪检查（含免密 sudo），且**零联网断言**
- `Vagrantfile`：rsync 默认、禁隐式 `/vagrant`、NFS 版本参数、域名前缀按 checkout 派生、不加附加盘
- `SKILL.md` 重写为生命周期驱动
- `examples/mac-docker-compose/` 删除（依赖 Docker）
- `README.md` 换成本中文档
- `test/` 断言改为「装了 rsync、**没装** Docker/Go/mage」，`integration.bats` 重写为生命周期套件

因此**不建议合入上游 main**；它作为本机/私有分发。
