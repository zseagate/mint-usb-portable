# 07 · FAQ

## 为什么不用 Ventoy / Rufus 直接写 ISO？

`dd` / Rufus / Ventoy 默认是 **live 系统**：

- 重启后改动丢失（除非额外配置持久化）
- 内核固定为 ISO 内的版本
- 不能像正常系统一样长期 `apt upgrade`
- 装 OpenCode、星火商店、开发工具后，持久化层会越来越臃肿

完整安装适合“当便携开发机用”的场景。如果只是想临时维护/体验，Ventoy 更合适。

## 能不能装在 64GB U 盘上？

可以，但建议调整：

```bash
sudo ROOT_SIZE=48G DEV=/dev/sdb bash scripts/install-mint-usb.sh
```

64GB 盘扣除 ESP 和 exFAT 数据区后，root 会比较紧张。OpenCode 二进制 242MB、星火商店 326MB，再加上内核/缓存，建议至少 64GB，最好 128GB。

## 为什么数据分区用 exFAT，不用 NTFS？

- exFAT 在 Windows/macOS/Linux 上都能直接读写
- 不需要额外驱动
- 适合放 ISO、安装包、项目归档

Linux 家目录仍然放在 ext4 根分区，避免权限/符号链接问题。

## Secure Boot 开启的机器能启动吗？

脚本安装的是：

- shim（微软签名）
- 签名 GRUB（Canonical 签名）
- 签名内核

理论上支持 Secure Boot。若某台机器固件不认：

1. 进 BIOS 关闭 Secure Boot
2. 或改用 Legacy 启动
3. 检查 `EFI/BOOT/BOOTX64.EFI` 是否存在

## Windows 家庭版能远程桌面吗？

不能作为 RDP **服务端**。Remmina 只是客户端。

可选：

- Windows 专业版/企业版：开启“远程桌面”
- 家庭版：RustDesk、ToDesk、VNC、AnyDesk 等

## 自动更新为什么没了？

为了减少 U 盘 I/O，默认禁用了 `apt-daily` / `plocate` 等定时器。手动更新：

```bash
sudo apt update && sudo apt upgrade
```

或在菜单打开“更新管理器”。

## 如何备份整个 U 盘？

推荐只备份重要数据：

- `/home/mint`（配置、项目）
- `/data`（共享文件）

系统本身可以用脚本重做。整盘镜像备份：

```bash
sudo dd if=/dev/sdb of=mint-usb-backup.img bs=4M status=progress
```

恢复：

```bash
sudo dd if=mint-usb-backup.img of=/dev/sdb bs=4M status=progress
```

> 整盘镜像很大（约 117GB），且恢复到不同容量的 U 盘会失败。

## 如何加全盘加密？

本项目未加密。若需要：

- 安装时使用 LUKS 加密根分区
- 或使用 VeraCrypt 创建加密容器放敏感数据
- 注意：Secure Boot + LUKS + 便携盘会增加启动复杂度

## 换机器后设备名变了怎么办？

fstab 和 GRUB 都使用 UUID，`/dev/sda` / `/dev/sdb` 变化不影响启动。只要：

```bash
blkid
```

能看到对应 UUID 即可。

## 能不能在 U 盘上跑 Docker？

可以，但普通闪存盘会很慢。建议：

- 使用移动 SSD
- 把 Docker 数据目录放到 `/data`（exFAT 不支持，需 ext4 分区）
- 或改用 Podman + 轻量镜像

## 制作失败如何恢复？

U 盘被清空后，旧数据无法恢复。重新制作：

```bash
sudo DEV=/dev/sdb bash scripts/install-mint-usb.sh
```

如果只是想恢复成普通 U 盘：

```bash
sudo wipefs -a /dev/sdb
sudo sgdisk --zap-all /dev/sdb
# 然后重新分区/格式化
```

## 相关链接

- [Linux Mint](https://linuxmint.com/)
- [OpenCode](https://opencode.ai/)
- [Remmina](https://remmina.org/)
- [星火应用商店](https://www.spark-app.store/)
- [项目仓库](https://github.com/zseagate/mint-usb-portable)
