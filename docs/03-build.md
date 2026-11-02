# 03 · 完整构建流程

## 前置条件

- 一支将被**清空**的 U 盘（建议 ≥64GB）
- Linux Mint / Ubuntu 主机（需要 `sgdisk`、`unsquashfs`、`grub-install`、`mkfs.exfat`）
- 网络（chroot 内要装 Remmina、git、星火商店）
- 目标镜像和可选安装包

```bash
sudo apt install -y squashfs-tools gdisk exfatprogs dosfstools
```

## 一键脚本

```bash
sudo DEV=/dev/sdb bash scripts/install-mint-usb.sh --check
sudo DEV=/dev/sdb bash scripts/install-mint-usb.sh
```

脚本流程：

1. **安全校验**：确认 `DEV` 是 USB 整盘、不是根分区所在磁盘。
2. **卸载旧挂载**：`umount -R`，失败再 `umount -l`，确认没有残留挂载。
3. **分区/格式化**：GPT + bios_grub + ESP + ext4 + exFAT。
4. **展开 squashfs**：loop 挂载 ISO，`unsquashfs` 到 ext4 根分区。
5. **写基础配置**：fstab、hostname、hosts、locale、时区、machine-id。
6. **关闭 live 专用服务**：`ubiquity.service`、`casper-md5check.service`。
7. **进入 chroot 安装**：
   - apt 源切换阿里云
   - 安装 Remmina/RDP/VNC、FreeRDP3、git、ripgrep、zram
   - 创建用户，复制 `/etc/skel`（含 fcitx5 配置）
   - 安装 OpenCode 2.2.5 到 `~/.opencode/bin`
   - 修复 LightDM 权限
   - 重建 initramfs
   - 安装 UEFI + BIOS GRUB
   - 写 ESP 引导配置
   - 应用 U 盘性能优化
8. **收尾**：恢复 `resolv.conf` 符号链接、清理临时文件、卸载、`sync`。

## 关键步骤说明

### 展开 squashfs

```bash
mount -o loop,ro linuxmint-22.3-xfce-64bit-lite.iso /mnt/mint-iso
unsquashfs -f -d /mnt/mint-usb-build /mnt/mint-iso/casper/filesystem.squashfs
```

squashfs 是 live 系统，但解包后就是一个完整 rootfs。直接作为安装系统的基础，比走图形安装器更适合脚本化。

### chroot 内 DNS

这是最容易踩的坑之一。详见 [04 · 踩坑记录](04-pitfalls.md#坑-2chroot-里-apt-无法解析域名)。

原则：

- 宿主机用 systemd-resolved（`127.0.0.53`）时，chroot 共享网络命名空间，直接用 `127.0.0.53` 最稳；
- 否则复制宿主 `/etc/resolv.conf` 的上游 DNS；
- 先用 `getent hosts mirrors.aliyun.com` 验证，再跑 apt。

### 用户与中文环境

```bash
useradd -m -U -s /bin/bash -G adm,cdrom,sudo,audio,dip,video,plugdev,render,lpadmin mint
echo 'mint:<password>' | chpasswd
```

`useradd -m` 会复制 `/etc/skel`，镜像里的 fcitx5 配置、`.xinputrc`、Xfce 配置都会进入新用户家目录。

### OpenCode 2

```bash
curl -fsSL https://opencode.ai/v2/install | bash
```

或离线：

```bash
tar xzf opencode2.tgz -C /tmp/oc2 --strip-components=1
install -m 0755 /tmp/oc2/bin/opencode /home/mint/.opencode/bin/opencode
ln -sf /home/mint/.opencode/bin/opencode /usr/local/bin/opencode
```

OpenCode 2 的 Linux 二进制解压后约 242MB，不依赖 node。

### Remmina

```bash
apt-get install -y \
  remmina remmina-plugin-rdp remmina-plugin-vnc remmina-plugin-secret \
  freerdp3-x11 gnome-keyring
```

### GRUB

```bash
# UEFI + Secure Boot
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=ubuntu --uefi-secure-boot --no-nvram

# Legacy BIOS
grub-install --target=i386-pc --boot-directory=/boot /dev/sdX

update-grub
```

ESP 上额外写一个小的 `grub.cfg`，按 root UUID 查找 `/boot/grub/grub.cfg`，这样 shim → GRUB → 系统菜单的链路才完整。

### 星火应用商店

单独脚本：

```bash
sudo DEV=/dev/sdb bash scripts/install-spark-store.sh
```

依赖链是 `spark-store → aria2 → libaria2-0 → libcares2`。如果先 `dpkg -i` 导致 `iU` 半安装状态，用 `apt-get -f install -y` 修复。

下一篇：[04 · 踩坑记录](04-pitfalls.md)
