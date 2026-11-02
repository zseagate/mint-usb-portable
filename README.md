# Linux Mint 22.3 随身 U 盘

把 Linux Mint 22.3 完整安装到一支 128GB USB 3.0 闪存盘上，做成可随身携带的中文 Linux 工作环境。

> 这不是 `dd` / Rufus / Ventoy 的 live USB，而是**完整安装**：有正常用户、可 `apt upgrade`、可换内核、可长期安装软件。

## 功能

- UEFI + Legacy BIOS 双启动（UEFI 带 shim + 签名 GRUB，支持 Secure Boot 的机器）
- 中文 locale（`zh_CN.UTF-8`）+ fcitx5 拼音/五笔，登录即用
- [OpenCode 2](https://opencode.ai/)（独立二进制，装在 `~/.opencode/bin`）
- Remmina + FreeRDP 3，可远程 Windows 桌面（RDP/VNC）
- [星火应用商店](https://www.spark-app.store/) 5.3.2
- exFAT 数据分区，Windows/macOS 可直接读写
- 针对 U 盘的性能调优：禁用开机索引/更新定时器、限制日志、降低脏页、USB 调度器与自动休眠

## 目录

```
.
├── README.md
├── LICENSE
├── docs/
│   ├── 01-overview.md          # 目标、硬件、方案选型
│   ├── 02-partition-plan.md    # 分区布局与 fstab
│   ├── 03-build.md             # 完整构建流程
│   ├── 04-pitfalls.md          # 踩坑记录（黑屏/DNS/卡顿/星火依赖…）
│   ├── 05-verification.md      # 首次启动验收清单
│   ├── 06-performance.md       # U 盘性能优化说明
│   └── 07-faq.md               # 常见问题
├── scripts/
│   ├── install-mint-usb.sh     # 主安装脚本（分区 + chroot + GRUB + 优化）
│   ├── install-spark-store.sh  # 安装星火应用商店
│   └── tune-usb-performance.sh # 对已装好的 U 盘重新应用性能优化
└── configs/
    ├── 99-usb-journald.conf
    ├── 99-usb-performance.conf
    ├── 60-usb-iosched.rules
    └── grub-usb-params.txt
```

## 快速开始

### 1. 准备文件

把以下文件放到仓库根目录（或通过环境变量指定路径）：

- `linuxmint-22.3-xfce-64bit-lite.iso`（约 2.5GB）
- `opencode2.tgz`（可选；脚本缺失时会自动下载 OpenCode 2.2.5）
- `spark-store_5.3.2_amd64.deb`（可选；星火脚本缺失时会自动下载）

### 2. 确认目标盘

```bash
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,MOUNTPOINT
```

脚本默认 `DEV=/dev/sdb`，会校验目标必须是 USB 整盘，并且不是当前根分区所在磁盘。

### 3. 只检查，不写盘

```bash
sudo DEV=/dev/sdb bash scripts/install-mint-usb.sh --check
```

### 4. 开始制作

```bash
sudo DEV=/dev/sdb bash scripts/install-mint-usb.sh
```

会要求输入 `WIPE` 和新用户密码。默认：

| 项目 | 默认值 |
|---|---|
| 用户名 | `mint` |
| 主机名 | `mint` |
| 时区 | `Asia/Shanghai` |
| root 分区 | 90GB |
| 文件系统 | ext4 / FAT32 / exFAT |

> ⚠️ 会清空目标 U 盘。请先备份数据，并反复确认 `DEV`。

### 5. 安装星火应用商店（可选）

```bash
sudo DEV=/dev/sdb bash scripts/install-spark-store.sh
```

### 6. 重新应用性能优化（可选）

```bash
sudo DEV=/dev/sdb bash scripts/tune-usb-performance.sh
```

## 分区布局

| 分区 | 大小 | 格式 | 用途 |
|---|---|---|---|
| `sdX1` | 1MB | 无 | bios_grub（Legacy BIOS） |
| `sdX2` | 1GB | FAT32 `MINTESP` | `/boot/efi` |
| `sdX3` | 90GB | ext4 `MINTROOT` | `/` |
| `sdX4` | 剩余 | exFAT `SHARE` | `/data`，Windows 可读写 |

所有挂载使用 UUID，换机器后设备名变化不影响启动。

## 踩坑速查

| 现象 | 原因 | 修复 |
|---|---|---|
| 开机一直黑屏 | LightDM 的 `/var/lib/lightdm` 是 `root:root 750`，greeter 写不了 `.Xauthority` | `chown lightdm:lightdm /var/lib/lightdm && chmod 700` |
| chroot 里 apt 无法解析域名 | 宿主机用 systemd-resolved，chroot 里写了公网 DNS 但网络策略不允许 | chroot 的 `/etc/resolv.conf` 用 `nameserver 127.0.0.53` |
| 键鼠卡顿 | `apt-daily` / `plocate` 定时器在开机后立即运行，持续抢 U 盘 I/O | 禁用定时器 + 限制日志 + 调脏页 + USB 调度器/自动休眠 |
| 星火商店装不上 | `spark-store` 已解包，但 `aria2 → libaria2-0 → libcares2` 依赖链断了 | `apt-get update && apt-get -f install -y` |
| GRUB 菜单显示 Ubuntu | 定制 ISO 的 `50_linuxmint.cfg` 写死 `GRUB_DISTRIBUTOR="Ubuntu"` | 改成 `Linux Mint` 后 `update-grub` |
| `wipefs: 设备或资源忙` | udisks2/FUSE 还挂着旧分区 | `umount -R` / `umount -l`，确认无挂载后再写 |
| Windows 家庭版连不上 RDP | 家庭版默认没有 RDP 服务端 | 用专业版/企业版，或改用 RustDesk/ToDesk |

详细过程见 [docs/04-pitfalls.md](docs/04-pitfalls.md)。

## 验收

首次启动后：

```bash
locale                 # zh_CN.UTF-8
fcitx5-diagnose        # 输入法自检
opencode --version     # 2.2.5
remmina                # 远程桌面
spark-store            # 星火应用商店
```

完整清单见 [docs/05-verification.md](docs/05-verification.md)。

## 性能边界

普通 USB 闪存盘的随机写远低于 SSD。即使做了优化，首次 `apt upgrade`、大项目编译、浏览器大量缓存时仍可能卡顿。

- 建议插 **USB 3.0 蓝色接口**，不要接 Hub
- 长期当开发盘用，建议换 **USB 3.2 固态 U 盘 / 移动 SSD**
- 自动更新定时器默认已禁用，需要时手动打开更新管理器

## 免责声明

本项目是个人制作记录，脚本会**清空目标磁盘**。请先在备用 U 盘上测试，确认 `DEV` 无误后再操作。因误写磁盘、数据丢失或硬件兼容性造成的问题，作者不承担责任。

## License

[MIT](LICENSE)
