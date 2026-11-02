# 06 · U 盘性能优化说明

## 为什么 U 盘会卡

普通 USB 闪存盘：

- 顺序读写可能 100–200MB/s
- 4K 随机写往往只有 0.5–2MB/s
- 大量小文件、日志、包索引、文件扫描会放大随机写

桌面卡顿通常不是显卡问题，而是 **I/O 等待** 或 **后台任务抢占**。

## 本项目做的优化

### 1. 禁用开机立即运行的定时器

涉及：

- `apt-daily.timer`
- `apt-daily-upgrade.timer`
- `plocate-updatedb.timer`
- `man-db.timer`
- `motd-news.timer`
- `e2scrub_all.timer`
- `fwupd-refresh.timer`
- `fstrim.timer`

原因：定制镜像里的持久化时间戳可能在“未来”，systemd 开机后会立即补跑，造成长时间 I/O。

代价：不会自动检查更新/索引；需要时手动执行：

```bash
sudo apt update && sudo apt upgrade
sudo updatedb
```

### 2. 限制 journald

`/etc/systemd/journald.conf.d/99-usb.conf`：

```ini
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=20M
RuntimeMaxUse=64M
```

避免默认按 90GB 根分区的 10% 持续写日志。

### 3. 降低脏页阈值

`/etc/sysctl.d/99-usb-performance.conf`：

```ini
vm.swappiness=100
vm.dirty_background_bytes=33554432
vm.dirty_bytes=134217728
vm.dirty_expire_centisecs=3000
vm.dirty_writeback_centisecs=3000
```

把脏页上限限制在 128MB，减少一次性大块回写造成的卡顿。`swappiness=100` 配合 zram 使用。

### 4. USB 存储调度器

`/etc/udev/rules.d/60-usb-iosched.rules`：

```udev
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="none"
```

USB 闪存盘通常上报 `rotational=1`，使用 `none` 减少调度开销。下次启动生效。

### 5. 禁用 USB 自动休眠

GRUB：

```text
usbcore.autosuspend=-1
```

避免键鼠、无线接收器被挂起后出现“第一下没反应”的延迟。

### 6. 关闭 mintupdate / mintreport 登录自启

它们会在登录后检查更新/崩溃报告，产生额外 I/O。需要时从菜单手动打开。

### 7. 根分区 noatime

`/etc/fstab`：

```fstab
UUID=... / ext4 defaults,noatime,errors=remount-ro 0 1
```

减少读文件时的元数据写入。

## 还可以做什么

### 关闭 Xfce 合成器

```bash
xfconf-query -c xfwm4 -p /general/use_compositing -s false
```

适合低端机器/远程桌面；会失去窗口阴影和透明效果。

### 换 USB 3.2 固态 U 盘

如果经常：

- 编译大型项目
- 跑 Docker
- 开多个浏览器标签
- 使用 IDE

建议直接用移动 SSD。软件优化无法突破闪存颗粒的 4K 随机写上限。

### 不要把 swap 放到 U 盘

本项目使用 zram（内存压缩），没有创建磁盘 swap。U 盘 swap 会严重缩短寿命并造成卡顿。

## 验证

```bash
systemctl list-timers --all
cat /etc/systemd/journald.conf.d/99-usb.conf
cat /etc/sysctl.d/99-usb-performance.conf
cat /etc/udev/rules.d/60-usb-iosched.rules
grep usbcore /proc/cmdline
```

## 还原

如果想让系统恢复默认自动更新：

```bash
sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
sudo systemctl enable --now plocate-updatedb.timer
```

（在正常硬盘上使用时不建议禁用这些定时器。）

下一篇：[07 · FAQ](07-faq.md)
