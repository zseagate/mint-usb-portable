# 04 · 踩坑记录

这篇是整个项目最有价值的部分。按实际发生顺序记录：现象 → 日志 → 根因 → 修复。

---

## 坑 1：第一次启动一直黑屏

### 现象

GRUB 正常，内核正常启动，但屏幕一直黑，没有登录界面。

### 日志

挂载 U 盘后看 `/var/log/lightdm/lightdm.log`：

```text
DEBUG: Seat seat0: Session pid=2338: Running command
  /usr/lib/lightdm/lightdm-greeter-session /usr/sbin/slick-greeter
DEBUG: Greeter closed communication channel
DEBUG: Session pid=2338: Exited with return value 1
DEBUG: Seat seat0: Stopping; failed to start a greeter
DEBUG: Display manager stopped
DEBUG: Exiting with return value 1
```

再看 `seat0-greeter.log`：

```text
Error writing X authority: Failed to open X authority
/var/lib/lightdm/.Xauthority: Permission denied
```

Xorg 日志里没有任何 `(EE)`，说明显卡和 X 本身没问题。

### 根因

live 镜像里的 `/var/lib/lightdm` 是：

```text
drwxr-x--- root root /var/lib/lightdm
```

但安装后的 greeter 以 `lightdm` 用户运行，需要在这个目录写 `.Xauthority`。写不进去 → greeter 退出 → LightDM 停止 → 黑屏。

### 修复

```bash
chown lightdm:lightdm /var/lib/lightdm
chmod 700 /var/lib/lightdm
rm -f /var/lib/lightdm/.Xauthority

mkdir -p /var/lib/lightdm-data/lightdm
chown lightdm:lightdm /var/lib/lightdm-data/lightdm
chmod 770 /var/lib/lightdm-data/lightdm
```

验证：

```bash
su -s /bin/sh lightdm -c 'touch /var/lib/lightdm/.Xauthority && rm -f /var/lib/lightdm/.Xauthority'
```

脚本里已内置这段修复。

---

## 坑 2：chroot 里 apt 无法解析域名

### 现象

```text
Err:1 https://mirrors.aliyun.com/ubuntu noble InRelease
  Could not resolve 'mirrors.aliyun.com'
E: Package 'git' has no installation candidate
```

### 根因

宿主机使用 systemd-resolved，`/etc/resolv.conf` 指向 `127.0.0.53`。chroot 里如果写公网 DNS（223.5.5.5 等），在当前网络策略下可能解析不了；而 chroot 与宿主机共享网络命名空间，`127.0.0.53` 是可达的。

### 修复

chroot 内使用真实文件（不是符号链接）：

```bash
rm -f /mnt/mint-usb-build/etc/resolv.conf
printf 'nameserver 127.0.0.53\noptions edns0 trust-ad\n' \
  > /mnt/mint-usb-build/etc/resolv.conf

chroot /mnt/mint-usb-build getent hosts mirrors.aliyun.com
```

脚本会自动判断：宿主机用 `127.0.0.53` 就复用，否则复制宿主机上游 DNS。

> 提示：不要在没有验证 DNS 的情况下直接跑 `apt-get update`，否则会留下空的/旧的包索引，后面安装依赖时会报“没有安装候选”。

---

## 坑 3：`wipefs: 设备或资源忙`

### 现象

```text
wipefs: 探测初始化失败: /dev/sdb: 设备或资源忙
```

### 根因

U 盘旧分区被 udisks2 / FUSE（ntfs-3g、btrfs）自动挂载，普通 `umount` 可能失败。

### 修复

```bash
sudo umount -R /media/gw/linux-lab-disk 2>/dev/null || sudo umount -l /media/gw/linux-lab-disk
sudo umount -R /media/gw/writable 2>/dev/null || sudo umount -l /media/gw/writable

lsblk -o NAME,FSTYPE,LABEL,MOUNTPOINT /dev/sdb
```

确认 `MOUNTPOINT` 全空后再分区。脚本里也加了校验：仍有挂载就直接退出，不会继续 `wipefs`。

---

## 坑 4：进桌面后键鼠卡顿

### 现象

能进桌面，但鼠标移动、键盘输入有明显延迟，像系统在后台忙。

### 日志

`/var/log/syslog` 里看到：

```text
apt-daily.timer: Not using persistent file timestamp ... as it is in the future.
Started apt-daily.timer - Daily apt download activities.
Started apt-daily-upgrade.timer ...
Started plocate-updatedb.timer ...
```

同时 USB 键鼠本身没有任何 `reset` / `error`，说明不是输入设备驱动坏了。

### 根因

- `apt-daily`、`apt-daily-upgrade`、`plocate-updatedb` 的持久化时间戳在“未来”，开机后 systemd 认为错过了执行时间，**立即启动**；
- 这些任务会大量读 apt 索引、扫描文件系统，U 盘随机 I/O 很慢，直接拖慢整个桌面；
- journald 默认按根分区 10% 使用空间，90GB 根分区可能写很多日志；
- 大块脏页回写也会造成周期性卡顿。

### 修复

```bash
# 禁用开机索引/自动更新定时器
for t in apt-daily.timer apt-daily-upgrade.timer motd-news.timer \
         plocate-updatedb.timer man-db.timer e2scrub_all.timer \
         fwupd-refresh.timer fstrim.timer; do
  sudo rm -f /etc/systemd/system/timers.target.wants/$t
  sudo rm -f /etc/systemd/system/$t
done

# 限制 journald
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-usb.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=20M
RuntimeMaxUse=64M
EOF

# 降低脏页阈值
sudo tee /etc/sysctl.d/99-usb-performance.conf >/dev/null <<'EOF'
vm.swappiness=100
vm.dirty_background_bytes=33554432
vm.dirty_bytes=134217728
vm.dirty_expire_centisecs=3000
vm.dirty_writeback_centisecs=3000
EOF

# USB 存储调度器
sudo tee /etc/udev/rules.d/60-usb-iosched.rules >/dev/null <<'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="none"
EOF

# 禁用 USB 自动休眠
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 usbcore.autosuspend=-1"/' /etc/default/grub

# 关闭 mintupdate / mintreport 登录自启
sudo sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=false/' \
  /etc/xdg/autostart/mintupdate.desktop /etc/xdg/autostart/mintreport.desktop

sudo update-grub
```

如果还卡，可以关闭 Xfce 合成器：

```bash
xfconf-query -c xfwm4 -p /general/use_compositing -s false
```

> 自动更新定时器禁用后，需要手动打开“更新管理器”或在终端 `sudo apt update && sudo apt upgrade`。

---

## 坑 5：星火应用商店装不上（依赖链断）

### 现象

```text
spark-store : 依赖: aria2 但是它还没有被安装
aria2 : 依赖: libaria2-0 ... 但是它将不会被安装
libaria2-0 : 依赖: libcares2 ... 但是它将不会被安装
```

`dpkg -l spark-store` 显示：

```text
iU  spark-store  5.3.2  amd64  Spark Store
```

`iU` = 已解包但未配置。

### 根因

- 镜像里的 apt 索引是旧的，第一次安装时找不到 `libcares2`；
- `apt-get install ./spark-store.deb` 先解包了 `spark-store`，依赖失败后留下半安装状态；
- 之后即使包索引更新，apt 也会一直尝试修复这个半安装包，导致连锁失败。

### 修复

先刷新索引，再让 apt 修复：

```bash
sudo apt-get update
sudo apt-get -f install -y
sudo apt-get install -y aria2
```

`apt-get -f install` 会自动安装 `libcares2`、`libaria2-0`、`aria2`，并配置 `spark-store`。

验证：

```bash
dpkg -s spark-store | grep -E '^(Package|Version|Status):'
command -v spark-store
ls /usr/share/applications/ | grep -i spark
```

脚本 `scripts/install-spark-store.sh` 已按这个顺序处理。

---

## 坑 6：GRUB 菜单显示 “Ubuntu”

### 现象

启动菜单显示：

```text
Ubuntu
Ubuntu, with Linux 6.14.0-37-generic
```

### 根因

定制 ISO 的 `/etc/default/grub.d/50_linuxmint.cfg` 里写的是：

```bash
GRUB_DISTRIBUTOR="Ubuntu"
```

### 修复

```bash
sudo sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Linux Mint"/' \
  /etc/default/grub.d/50_linuxmint.cfg
sudo update-grub
```

菜单会变成 `Linux Mint GNU/Linux`。纯显示问题，不影响启动。

---

## 坑 7：Secure Boot 机器不启动

### 现象

在开启 Secure Boot 的机器上，选 U 盘后直接回到 BIOS，或报安全启动错误。

### 根因

UEFI 只认签名的 `BOOTX64.EFI`。如果只安装了未签名的 GRUB，或者 shim 没有一起复制，就会被固件拒绝。

### 修复

脚本使用：

```bash
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=ubuntu --uefi-secure-boot --no-nvram
```

并额外：

- 把 `EFI/ubuntu` 镜像到 `EFI/BOOT`
- 把 `shimx64.efi` 复制为 `BOOTX64.EFI`
- 复制 `mmx64.efi`、`fbx64.efi`、`BOOTX64.CSV`
- 在 `EFI/ubuntu/grub.cfg` 和 `EFI/BOOT/grub.cfg` 写入按 root UUID 查找的配置

如果某台机器仍不认，进 BIOS 关闭 Secure Boot，或改用 Legacy 启动。

---

## 坑 8：Windows 家庭版 RDP 连不上

Remmina 是客户端，不是服务端。Windows 家庭版默认**不提供** RDP 服务端：

- Windows 专业版/企业版：设置 → 系统 → 远程桌面 → 开启
- 家庭版：改用 RustDesk / ToDesk / VNC 等方案

Microsoft 账户的 RDP 用户名通常要写：

```text
MicrosoftAccount\your@email.com
```

域账户：

```text
DOMAIN\username
```

---

## 坑 9：U 盘性能的物理上限

即使做完所有优化，普通 USB 闪存盘的 4K 随机写仍然远低于 SSD。以下场景会明显慢：

- 首次 `apt upgrade`
- 浏览器大量缓存
- 大型项目编译
- 虚拟机镜像

建议：

- 插 USB 3.0 蓝色口，不接 Hub
- 长期使用换 USB 3.2 固态 U 盘 / 移动 SSD
- 重要数据同时备份到主机或云盘

---

## 坑 10：`/tmp` 重启后丢失

制作过程中把脚本、安装包、sudo 密码弹窗脚本放在 `/tmp/opencode`，主机重启后全没了，导致安装中断。

修复：把以下内容放到持久目录：

- 安装脚本：项目仓库
- OpenCode / 星火安装包：项目目录
- askpass 脚本：`~/.local/bin/`
- 日志：项目目录

## 坑 11：第二次黑屏——Xorg 卡在 glamor

第一次黑屏修好 LightDM 后，重启又能进桌面。但换盘/再次启动后，又黑屏。

### 日志

`/var/log/Xorg.0.log` 停在：

```text
(II) Loading /usr/lib/xorg/modules/libglamoregl.so
(II) Module glamoregl: vendor="X.Org Foundation"
```

后面没有 `glamor X acceleration enabled`，LightDM 一直等不到 X server ready。内核命令行还多了 `vt.handoff=7`（由 `splash` 触发）。

### 修复

```bash
# 1) 禁用 Intel glamor
sudo tee /etc/X11/xorg.conf.d/20-modesetting-no-glamor.conf >/dev/null <<'EOF'
Section "Device"
    Identifier "Intel modesetting (no glamor)"
    Driver "modesetting"
    Option "AccelMethod" "none"
EndSection
EOF

# 2) 黑名单 nouveau（显示器接 Intel 时）
sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

# 3) 去掉 splash，关闭 i915 PSR
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="usbcore.autosuspend=-1 i915.enable_psr=0"/' /etc/default/grub

sudo update-initramfs -u -k all
sudo update-grub
```

同时加一个 `nomodeset` 的 GRUB 安全启动项，作为兜底。GRUB 等待时间改成 10 秒。

如果普通项仍黑屏，选 **`Linux Mint (safe graphics, nomodeset)`**。

---

## 坑 12：电源菜单只有注销，确认框点不动

### 日志

`~/.xsession-errors` 反复出现：

```text
polkit-agent-helper-1: needs to be setuid root
```

### 根因

镜像里的两个关键文件丢了 setuid 位：

```text
/usr/bin/pkexec
/usr/lib/polkit-1/polkit-agent-helper-1
```

导致 polkit 认证失败：Xfce 退出对话框里的重启/关机不可用，greeter 的确认框也点不动。

### 修复

```bash
sudo chmod 4755 /usr/bin/pkexec
sudo chmod 4755 /usr/lib/polkit-1/polkit-agent-helper-1

# 可选：修正 dbus helper
sudo chown root:messagebus /usr/lib/dbus-1.0/dbus-daemon-launch-helper
sudo chmod 4754 /usr/lib/dbus-1.0/dbus-daemon-launch-helper
```

再加一条 polkit 规则，允许 `sudo` 组和 `lightdm` 执行电源操作：

```bash
sudo tee /etc/polkit-1/rules.d/49-allow-power.rules >/dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    var ids = [
        "org.freedesktop.login1.power-off",
        "org.freedesktop.login1.reboot",
        "org.freedesktop.login1.power-off-multiple-sessions",
        "org.freedesktop.login1.reboot-multiple-sessions",
        "org.freedesktop.login1.suspend",
        "org.freedesktop.login1.suspend-multiple-sessions"
    ];
    if (ids.indexOf(action.id) !== -1 &&
        (subject.user == "lightdm" || subject.isInGroup("sudo"))) {
        return polkit.Result.YES;
    }
});
EOF
```

兜底：在 `/usr/share/applications/` 加“重启/关机”桌面项，`Exec=pkexec systemctl reboot` / `pkexec systemctl poweroff`。

---

## 坑 13：`apt upgrade` 极慢——U 盘写入是硬瓶颈

### 实测

| 盘 | 顺序写 | 4K 随机写 QD1 | fsync | 顺序读 | 判定 |
|---|---:|---:|---:|---:|---|
| ASolid 128GB | 1.87 MB/s | 0.27 MB/s | 0.13 MB/s | 200 MB/s | FAIL |
| Kingston DataTraveler 3.0 115.5GB | 9.99 MB/s | 0.81 MB/s | 0.58 MB/s | 53.7 MB/s | FAIL |

两盘都是 **BOT + write through**，`hdparm -W1` 也打不开写缓存。

### 结论

`apt` 慢不是系统配置问题，是 U 盘 4K 随机写太低。软件优化只能减轻，不能解决：

```bash
# 跳过 dpkg 逐文件 fsync（用断电安全性换速度）
sudo tee /etc/apt/apt.conf.d/99-usb-fast >/dev/null <<'EOF'
DPkg::Options { "--force-unsafe-io"; };
APT::Acquire::Languages "none";
EOF

# 减少 ext4 日志提交
# /etc/fstab 根分区加 commit=30
```

### 正确做法

**制作前先跑基准**：

```bash
sudo DEV=/dev/sdX TARGET=/mnt/usbtest MODE=full bash scripts/usb-benchmark.sh
```

- GOOD / PASS：继续
- WARN：只做轻量使用
- FAIL：换 USB SSD / 高端 U 盘

详见 [08 · U 盘性能基准](08-usb-benchmark.md)。

下一篇：[05 · 验收清单](05-verification.md)
