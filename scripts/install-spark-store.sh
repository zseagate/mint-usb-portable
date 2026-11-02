#!/usr/bin/env bash
# =============================================================================
# 在已安装好的 Mint U 盘里安装「星火应用商店」(Spark Store)
#
# 用法:
#   sudo DEV=/dev/sdb bash install-spark-store.sh
#   sudo DEV=/dev/sdb SPARK_DEB=/path/to/spark-store_5.3.2_amd64.deb \
#        bash install-spark-store.sh
#
# 依赖: 目标系统需能联网（脚本会在 chroot 内 apt-get update）。
# =============================================================================
set -Eeuo pipefail

DEV="${DEV:-/dev/sdb}"
MNT="${MNT:-/mnt/mint-usb-build}"
SPARK_VERSION="${SPARK_VERSION:-5.3.2}"
SPARK_DEB="${SPARK_DEB:-./spark-store_${SPARK_VERSION}_amd64.deb}"
SPARK_URL="https://gitee.com/spark-store-project/spark-store/releases/download/${SPARK_VERSION}/spark-store_${SPARK_VERSION}_amd64.deb"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
cleanup() {
  set +e
  umount "$MNT/run" 2>/dev/null
  umount "$MNT/dev/pts" 2>/dev/null
  umount "$MNT/dev" 2>/dev/null
  umount "$MNT/proc" 2>/dev/null
  umount -R "$MNT/sys" 2>/dev/null
  umount -R "$MNT" 2>/dev/null
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then echo "FAILED rc=$rc"; fi; cleanup; exit $rc' EXIT

[[ $EUID -eq 0 ]] || die "请用 sudo 运行"
[[ -b "$DEV" ]] || die "设备不存在: $DEV"
[[ $(lsblk -dno TRAN "$DEV" | tr -d '[:space:]') == usb ]] || die "$DEV 不是 USB 设备"

if [[ ! -s "$SPARK_DEB" ]]; then
  log "下载星火应用市场 ${SPARK_VERSION}"
  curl -fL --retry 3 --connect-timeout 20 "$SPARK_URL" -o "$SPARK_DEB"
fi

log "挂载目标系统"
mountpoint -q "$MNT" || mount "${DEV}3" "$MNT"
mkdir -p "$MNT/dev" "$MNT/dev/pts" "$MNT/proc" "$MNT/sys" "$MNT/run"
mountpoint -q "$MNT/dev" || mount --bind /dev "$MNT/dev"
mountpoint -q "$MNT/dev/pts" || mount --bind /dev/pts "$MNT/dev/pts"
mountpoint -q "$MNT/proc" || mount --bind /proc "$MNT/proc"
mountpoint -q "$MNT/sys" || mount --bind /sys "$MNT/sys"
mountpoint -q "$MNT/run" || mount -t tmpfs -o mode=755 tmpfs "$MNT/run"

log "配置 chroot DNS"
rm -f "$MNT/etc/resolv.conf"
if grep -q '^nameserver 127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
  DNS_ENTRIES="nameserver 127.0.0.53"
else
  DNS_ENTRIES="$(awk '/^nameserver[[:space:]]/{print "nameserver "$2}' /etc/resolv.conf 2>/dev/null | head -2)"
fi
[[ -n "$DNS_ENTRIES" ]] || DNS_ENTRIES="nameserver 1.1.1.1"
printf '%s\noptions edns0 trust-ad\n' "$DNS_ENTRIES" > "$MNT/etc/resolv.conf"

cp -f "$SPARK_DEB" "$MNT/tmp/spark-store.deb"

log "安装星火应用市场及依赖（apt）"
chroot "$MNT" /usr/bin/env DEBIAN_FRONTEND=noninteractive SYSTEMD_OFFLINE=1 /bin/bash -c '
set -e
apt-get update
# 先直接装本地包；若之前 dpkg 解包后缺依赖，再用 -f install 修复
apt-get install -y /tmp/spark-store.deb || {
  apt-get -f install -y
  apt-get install -y /tmp/spark-store.deb
}
apt-get install -y aria2
rm -f /tmp/spark-store.deb
dpkg -s spark-store | grep -E "^(Package|Version|Status):"
command -v spark-store
'

log "恢复 resolv.conf 并卸载"
rm -f "$MNT/etc/resolv.conf"
ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
sync
log "完成：菜单中应出现「星火应用商店」，终端可运行 spark-store"
