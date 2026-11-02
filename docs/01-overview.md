# 01 · 目标、硬件与方案选型

## 目标

把一支 128GB USB 3.0 闪存盘做成随身 Linux：

- 开机直接进中文桌面，自带 fcitx5 输入法
- 可以长期安装软件（不是重启就丢的 live 系统）
- 预装 OpenCode、Remmina、星火应用商店
- UEFI 和 Legacy BIOS 都能启动
- 在 Windows 上还能读写 U 盘里的共享分区

## 硬件与镜像

| 项目 | 配置 |
|---|---|
| CPU | Intel i5-8400 |
| 核显 | Intel UHD Graphics 630（显示器接 DP-2） |
| 独显 | NVIDIA GTX 1060 3GB（本方案未使用） |
| 内存 | 15GB |
| U 盘 | ASolid 128GB，USB 3.0 5Gbps |
| 主机系统 | Linux Mint 22.3（Cubic 定制版） |
| 目标镜像 | `linuxmint-22.3-xfce-64bit-lite.iso`，2.5GB |

镜像内部情况（实际解包核对）：

- Linux Mint 22.3 Xfce 64-bit，kernel `6.14.0-37-generic`
- squashfs 约 2.19GB
- 已内置 `zh_CN.UTF-8`、fcitx5、拼音/五笔、Noto CJK、Firefox 中文包
- `/etc/skel` 已带 fcitx5 配置和 `.xinputrc`，新用户登录即生效
- 带 `ubiquity` 安装器、`gparted`、GRUB、shim
- **没有** Remmina/FreeRDP，**没有** git/node，需要额外安装

## 三种方案对比

| 方案 | 原理 | 优点 | 缺点 |
|---|---|---|---|
| A. Ventoy + 持久化 | Ventoy 引导 ISO，`casper-rw` 文件保存改动 | 快、可多 ISO、可回退 | 内核固定为 ISO 内的版本；overlay 性能一般 |
| B. 完整安装 | 把 squashfs 展开成正常系统，装 GRUB | 原生 ext4 性能、可升级内核、最稳 | 步骤多，需要处理 GRUB/权限 |
| C. 手动持久 live | GRUB loopback + 独立 `casper-rw` 分区 | 持久分区大，不依赖 Ventoy | 引导需手工维护，内核仍固定 |

最终选择 **B 完整安装**，原因：

1. 要长期安装 OpenCode、星火商店、开发工具，完整系统更合适；
2. 可以正常 `apt upgrade` 和换内核；
3. ext4 原生文件系统比“exFAT 上的 loop 文件 + overlay”快；
4. 双启动和 Secure Boot 可以一次配置好。

## 最终形态

- UEFI：`EFI/BOOT/BOOTX64.EFI`（shim）+ 签名 GRUB
- Legacy BIOS：MBR + 1MB bios_grub 分区
- 中文桌面 + fcitx5
- OpenCode 2.2.5
- Remmina + FreeRDP 3
- 星火应用商店 5.3.2
- `/data` exFAT 共享分区

下一篇：[02 · 分区布局](02-partition-plan.md)
