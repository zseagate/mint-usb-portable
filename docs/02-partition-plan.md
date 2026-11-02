# 02 · 分区布局与 fstab

## GPT 布局

目标盘 117.2GiB（标称 128GB），采用 GPT：

| 分区 | 大小 | 类型 | 格式/标签 | 挂载点 | 用途 |
|---|---|---|---|---|---|
| `sdX1` | 1MiB | EF02 | 无 | - | bios_grub，Legacy BIOS 放 core.img |
| `sdX2` | 1GiB | EF00 | FAT32 `MINTESP` | `/boot/efi` | UEFI 引导 |
| `sdX3` | 90GiB | 8300 | ext4 `MINTROOT` | `/` | 系统与用户数据 |
| `sdX4` | 剩余（约 26GiB） | 0700 | exFAT `SHARE` | `/data` | Windows/macOS 共享 |

创建命令（脚本内部）：

```bash
sgdisk --zap-all /dev/sdX
sgdisk \
  -n 1:0:+1M   -t 1:ef02 -c 1:bios_grub \
  -n 2:0:+1G   -t 2:ef00 -c 2:MINTESP \
  -n 3:0:+90G  -t 3:8300 -c 3:MINTROOT \
  -n 4:0:0     -t 4:0700 -c 4:SHARE \
  /dev/sdX

mkfs.vfat -F32 -n MINTESP  /dev/sdX2
mkfs.ext4 -F -L MINTROOT -m 1 /dev/sdX3
mkfs.exfat -n SHARE /dev/sdX4
```

## fstab

全部使用 UUID，换机器后 `/dev/sdX` 名字变化也不影响：

```fstab
UUID=<root-uuid>  /          ext4  defaults,noatime,errors=remount-ro  0 1
UUID=<esp-uuid>   /boot/efi  vfat  umask=0077,shortname=winnt           0 2
UUID=<data-uuid>  /data      exfat defaults,nofail,noatime,uid=1000,gid=1000,umask=022 0 0
```

说明：

- `noatime` 减少 U 盘写入。
- `/data` 用 `nofail`，即使 exFAT 挂载失败也不阻塞开机。
- `uid/gid` 在安装完成后会按实际用户 UID 自动替换（默认 `1000`）。
- 根分区 `-m 1` 只保留 1% 给 root，避免默认 5% 浪费。

## 为什么 ESP 给 1GB

- 内核 `vmlinuz` 约 15MB
- initramfs 约 80MB
- GRUB、shim、字体、主题
- 留出多内核和 fallback initrd 的空间

64MB 的 ESP 在多内核场景会很快不够。

## UEFI 与 Secure Boot

- 使用 `grub-install --target=x86_64-efi --uefi-secure-boot --no-nvram`
- 会安装 shim + 签名的 `grubx64.efi`
- 同时把 `EFI/ubuntu` 镜像到 `EFI/BOOT`，并把 shim 复制为 `BOOTX64.EFI`
- 这样任意 UEFI 都能从可移动路径启动，不依赖 NVRAM 启动项
- Secure Boot 开启的机器理论上可以直接启动；若固件不认，关闭 Secure Boot 即可

## Legacy BIOS

- `grub-install --target=i386-pc --boot-directory=/boot /dev/sdX`
- 依赖 1MB 的 `bios_grub` 分区
- 老机器在启动菜单里选普通 USB 项即可

## 数据分区

- exFAT，Windows 和 macOS 默认可读写
- 自动挂载到 `/data`
- 适合放 ISO、安装包、项目归档、跨系统文件
- 不建议把 Linux 家目录放这里（权限/符号链接不兼容）

下一篇：[03 · 完整构建流程](03-build.md)
