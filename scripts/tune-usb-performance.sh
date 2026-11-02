#!/usr/bin/env bash
# =============================================================================
# 对已安装好的 Mint U 盘做性能优化（可重复执行）
#
# 主要针对：开机后 apt-daily / plocate 立即运行、journald 写盘过多、
# 大块脏页回写、USB 输入设备自动休眠导致的桌面/键鼠卡顿。
#
# 用法:
#   sudo DEV=/dev/sdb bash tune-usb-performance.sh
# =============================================================================
set -Eeuo pipefail

DEV="${DEV:-/dev/sdb}"
MNT="${MNT:-/mnt/mint-usb-build}"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
cleanup() {
  set +e
  umount "$MNT/run" 2>/dev/null
  umount "$MNT/dev/pts" 2>/dev/null
  umount "$MNT/dev" 2>/dev/null
  umount "$MNT/proc" 2>/dev/null
  umount -R "$MNT/sys" 2>/dev/null
  umount "$MNT/boot/efi" 2>/dev/null
  umount -R "$MNT" 2>/dev/null
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then echo "FAILED rc=$rc"; fi; cleanup; exit $rc' EXIT

[[ $EUID -eq 0 ]] || die "请用 sudo 运行"
[[ -b "$DEV" ]] || die "设备不存在: $DEV"

log "挂载目标系统"
mountpoint -q "$MNT" || mount "${DEV}3" "$MNT"
mkdir -p "$MNT/boot/efi" "$MNT/dev" "$MNT/dev/pts" "$MNT/proc" "$MNT/sys" "$MNT/run"
mountpoint -q "$MNT/boot/efi" || mount "${DEV}2" "$MNT/boot/efi"
mountpoint -q "$MNT/dev" || mount --bind /dev "$MNT/dev"
mountpoint -q "$MNT/dev/pts" || mount --bind /dev/pts "$MNT/dev/pts"
mountpoint -q "$MNT/proc" || mount --bind /proc "$MNT/proc"
mountpoint -q "$MNT/sys" || mount --bind /sys "$MNT/sys"
mountpoint -q "$MNT/run" || mount -t tmpfs -o mode=755 tmpfs "$MNT/run"

log "应用性能优化"
chroot "$MNT" /bin/bash -c '
set -e
# 1) 关闭开机后立即运行的索引/自动更新定时器
for t in apt-daily.timer apt-daily-upgrade.timer motd-news.timer \
         plocate-updatedb.timer man-db.timer e2scrub_all.timer \
         fwupd-refresh.timer fstrim.timer; do
  rm -f "/etc/systemd/system/timers.target.wants/$t"
  rm -f "/etc/systemd/system/$t"
done
# 2) 限制 journald 日志占用
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-usb.conf <<EOF
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=20M
RuntimeMaxUse=64M
EOF
# 3) 降低脏页阈值，减少大块写回卡顿
cat > /etc/sysctl.d/99-usb-performance.conf <<EOF
vm.swappiness=100
vm.dirty_background_bytes=33554432
vm.dirty_bytes=134217728
vm.dirty_expire_centisecs=3000
vm.dirty_writeback_centisecs=3000
EOF
# 4) USB 存储调度器
cat > /etc/udev/rules.d/60-usb-iosched.rules <<EOF
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="none"
EOF
# 5) 禁用 USB 自动休眠
if ! grep -q "usbcore.autosuspend=-1" /etc/default/grub; then
  sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 usbcore.autosuspend=-1\"/" /etc/default/grub
fi
# 6) 关闭 mintupdate / mintreport 登录自启
for f in /etc/xdg/autostart/mintupdate.desktop /etc/xdg/autostart/mintreport.desktop; do
  [ -f "$f" ] || continue
  if grep -q "^X-GNOME-Autostart-enabled=" "$f"; then
    sed -i "s/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=false/" "$f"
  else
    echo "X-GNOME-Autostart-enabled=false" >> "$f"
  fi
done
# 7) 修正 GRUB 菜单名
if [ -f /etc/default/grub.d/50_linuxmint.cfg ]; then
  sed -i "s/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR=\"Linux Mint\"/" /etc/default/grub.d/50_linuxmint.cfg
fi
update-grub
'

log "卸载"
sync
log "完成，重启后生效"
