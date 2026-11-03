#!/usr/bin/env bash
# =============================================================================
# 将 Linux Mint 22.3 (定制 lite ISO) 完整安装到 USB 盘
#  - GPT: 1MB bios_grub + 1GB ESP + 90GB ext4 root + 剩余 exFAT 数据区
#  - UEFI (shim + 签名 GRUB, 支持 Secure Boot) 与 Legacy BIOS 双启动
#  - 中文 locale / fcitx5 输入法随 /etc/skel 自动进入新用户
#  - 预装: Remmina (RDP/VNC), FreeRDP3, git, OpenCode 2.2.5, zram, ripgrep
#
# 用法:
#   sudo bash install-mint-usb.sh --check     # 只检查，不写盘
#   sudo DEV=/dev/sdX bash install-mint-usb.sh
#   sudo MINT_PASSWORD='xxx' DEV=/dev/sdX bash install-mint-usb.sh --yes
#
# 依赖: 把 linuxmint-22.3-xfce-64bit-lite.iso 放在当前目录，
#       或通过 ISO=/path/to/xxx.iso 指定。
# 警告: 会清空目标 U 盘的全部数据！请务必确认 DEV。
# =============================================================================
set -Eeuo pipefail

# ----------------------------- 可调整参数 ------------------------------------
ISO="${ISO:-./linuxmint-22.3-xfce-64bit-lite.iso}"
DEV="${DEV:-/dev/sdb}"
ROOT_LABEL="${ROOT_LABEL:-MINTROOT}"
ESP_LABEL="${ESP_LABEL:-MINTESP}"
SHARE_LABEL="${SHARE_LABEL:-SHARE}"
ROOT_SIZE="${ROOT_SIZE:-90G}"          # root 分区大小，剩余给 exFAT 数据区
NEW_USER="${NEW_USER:-mint}"
NEW_HOST="${NEW_HOST:-mint}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
OC_VERSION="${OC_VERSION:-2.2.5}"
OC_TGZ="${OC_TGZ:-./opencode2.tgz}"
OC_URL="https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-${OC_VERSION}.tgz"
MNT="${MNT:-/mnt/mint-usb-build}"
ISO_MNT="${ISO_MNT:-/mnt/mint-iso}"
ASSUME_YES=0
CHECK_ONLY=0

# ------------------------------- 基础函数 ------------------------------------
log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
  set +e
  umount "$ISO_MNT" 2>/dev/null
  umount "$MNT/run" 2>/dev/null
  umount "$MNT/dev/pts" 2>/dev/null
  umount "$MNT/dev" 2>/dev/null
  umount "$MNT/proc" 2>/dev/null
  umount -R "$MNT/sys" 2>/dev/null
  umount "$MNT/boot/efi" 2>/dev/null
  umount -R "$MNT" 2>/dev/null
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then warn "脚本在第 $LINENO 行失败 (rc=$rc)"; fi; cleanup; exit $rc' EXIT

for arg in "$@"; do
  case "$arg" in
    -y|--yes)   ASSUME_YES=1 ;;
    --check)    CHECK_ONLY=1 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *)          die "未知参数: $arg" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "请用 sudo 运行: sudo bash $0"
[[ -f $ISO ]] || die "ISO 不存在: $ISO"
[[ -b $DEV ]] || die "设备不存在: $DEV"

# --------------------------- 目标设备安全校验 --------------------------------
TRAN="$(lsblk -dno TRAN "$DEV" | tr -d '[:space:]')"
TYPE="$(lsblk -dno TYPE "$DEV" | tr -d '[:space:]')"
SIZE="$(lsblk -dno SIZE "$DEV" | tr -d '[:space:]')"
MODEL="$(lsblk -dno MODEL "$DEV" | sed 's/[[:space:]]*$//')"
SERIAL="$(lsblk -dno SERIAL "$DEV" | tr -d '[:space:]')"
ROOT_SRC="$(findmnt -no SOURCE /)"

[[ "$TYPE" == "disk" ]] || die "$DEV 不是整块磁盘"
[[ "$TRAN" == "usb" ]]  || die "$DEV 的 TRAN=$TRAN，不是 USB 设备，已中止"
[[ "$ROOT_SRC" != "$DEV"* ]] || die "不能写入当前系统根分区所在磁盘 ($ROOT_SRC)"

cat <<EOF

目标设备:
  设备      : $DEV
  型号/序列 : ${MODEL:-?} / ${SERIAL:-?}
  容量      : $SIZE  (USB, $TRAN)
  当前布局  :
$(lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DEV" | sed 's/^/    /')

将要创建:
  ${DEV}1   1MB    bios_grub (Legacy BIOS)
  ${DEV}2   1GB    FAT32  $ESP_LABEL  -> /boot/efi
  ${DEV}3   $ROOT_SIZE  ext4   $ROOT_LABEL -> /
  ${DEV}4   剩余   exFAT  $SHARE_LABEL -> /data (Windows 可读写)
EOF

if [[ $CHECK_ONLY -eq 1 ]]; then
  log "检查模式：未做任何修改。"
  exit 0
fi

[[ $ASSUME_YES -eq 1 ]] || {
  echo
  read -rp "此操作会清空 $DEV 的全部数据。确认请输入 WIPE: " ans
  [[ "$ans" == "WIPE" ]] || die "已取消"
}

# ------------------------------- 新用户密码 ----------------------------------
PASS1="${MINT_PASSWORD:-}"
if [[ -z $PASS1 ]]; then
  [[ -t 0 ]] || die "非交互模式请在环境变量 MINT_PASSWORD 中提供密码"
  while :; do
    read -rsp "设置用户 $NEW_USER 的密码: " PASS1; echo
    read -rsp "再次输入密码: " PASS2; echo
    [[ -n $PASS1 ]] || { warn "密码不能为空"; continue; }
    [[ "$PASS1" == "$PASS2" ]] || { warn "两次输入不一致"; continue; }
    [[ "$PASS1" != *:* ]] || { warn "密码不能包含冒号"; continue; }
    break
  done
fi
[[ "$PASS1" != *:* ]] || die "密码不能包含冒号"

# -------------------------------- 清理挂载 -----------------------------------
log "卸载目标设备上已有挂载"
while read -r part; do
  [[ -n $part ]] || continue
  umount -R "$part" 2>/dev/null || umount -l "$part" 2>/dev/null || true
done < <(lsblk -lnpo NAME "$DEV" | tail -n +2)
udevadm settle
if lsblk -lnpo NAME,MOUNTPOINT "$DEV" | awk 'NF > 1 && $2 != "" {print}' | grep -q .; then
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DEV" >&2
  die "目标设备仍有分区挂载，请先手动卸载后再运行"
fi

# -------------------------------- 分区 ---------------------------------------
log "写入 GPT 分区表并创建分区"
wipefs -a "$DEV"
sgdisk --zap-all "$DEV"
sgdisk \
  -n 1:0:+1M      -t 1:ef02 -c 1:"bios_grub" \
  -n 2:0:+1G      -t 2:ef00 -c 2:"$ESP_LABEL" \
  -n 3:0:+"$ROOT_SIZE" -t 3:8300 -c 3:"$ROOT_LABEL" \
  -n 4:0:0        -t 4:0700 -c 4:"$SHARE_LABEL" \
  "$DEV"
partprobe "$DEV"
udevadm settle

log "格式化分区"
mkfs.vfat -F32 -n "$ESP_LABEL" "${DEV}2"
mkfs.ext4 -F -L "$ROOT_LABEL" -m 1 "${DEV}3"
mkfs.exfat -n "$SHARE_LABEL" "${DEV}4"
udevadm settle

ROOT_UUID="$(blkid -s UUID -o value "${DEV}3")"
ESP_UUID="$(blkid -s UUID -o value "${DEV}2")"
SHARE_UUID="$(blkid -s UUID -o value "${DEV}4")"
[[ -n $ROOT_UUID && -n $ESP_UUID && -n $SHARE_UUID ]] || die "读取分区 UUID 失败"

# -------------------------------- 挂载 ---------------------------------------
log "挂载 root 并展开 squashfs（这一步最慢）"
mkdir -p "$MNT" "$ISO_MNT"
mount "${DEV}3" "$MNT"
mount -o loop,ro "$ISO" "$ISO_MNT"
unsquashfs -f -d "$MNT" "$ISO_MNT/casper/filesystem.squashfs"
umount "$ISO_MNT"

mkdir -p "$MNT/boot/efi" "$MNT/data"
mount "${DEV}2" "$MNT/boot/efi"

# ------------------------------ 基础系统配置 ---------------------------------
log "写入 fstab / hostname / 时区 / locale"
cat > "$MNT/etc/fstab" <<EOF
# /etc/fstab: static file system information.
UUID=$ROOT_UUID  /          ext4  defaults,noatime,commit=30,errors=remount-ro  0 1
UUID=$ESP_UUID   /boot/efi  vfat  umask=0077,shortname=winnt           0 2
UUID=$SHARE_UUID /data      exfat defaults,nofail,noatime,uid=1000,gid=1000,umask=022 0 0
EOF

echo "$NEW_HOST" > "$MNT/etc/hostname"
cat > "$MNT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $NEW_HOST
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

printf 'LANG=zh_CN.UTF-8\n' > "$MNT/etc/default/locale"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$MNT/etc/localtime"
echo "$TIMEZONE" > "$MNT/etc/timezone"

rm -f "$MNT/etc/machine-id" "$MNT/var/lib/dbus/machine-id"
: > "$MNT/etc/machine-id"
rm -f "$MNT"/etc/ssh/ssh_host_* 2>/dev/null || true

# 关掉 live 专用服务，避免装好后一开机就弹安装器 / 做 ISO 校验
rm -f "$MNT/etc/systemd/system/graphical.target.wants/ubiquity.service"
rm -f "$MNT/etc/systemd/system/multi-user.target.wants/casper-md5check.service"
rm -f "$MNT/etc/xdg/autostart/ubiquity-mint.desktop"
rm -f "$MNT/usr/share/applications/ubiquity.desktop" 2>/dev/null || true
ln -sf /lib/systemd/system/graphical.target "$MNT/etc/systemd/system/default.target"

# 准备 opencode 安装包
if [[ ! -s $OC_TGZ ]]; then
  log "下载 OpenCode ${OC_VERSION}"
  curl -fL --retry 3 --connect-timeout 20 "$OC_URL" -o "$OC_TGZ"
fi
gzip -t "$OC_TGZ" || die "OpenCode 安装包损坏: $OC_TGZ"

# -------------------------- 生成 chroot 内脚本 -------------------------------
cat > "$MNT/tmp/setup.sh" <<'CHROOT_SCRIPT'
#!/bin/bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

log() { printf '\n\033[1;36m[chroot] %s\033[0m\n' "$*"; }

log "配置 apt 镜像（阿里云）"
rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
cat > /etc/apt/sources.list.d/official-package-repositories.list <<'EOF'
deb https://mirrors.aliyun.com/linuxmint-packages zena main upstream import backport
deb https://mirrors.aliyun.com/ubuntu noble main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu noble-updates main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu noble-backports main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu noble-security main restricted universe multiverse
EOF
apt-get update

log "安装 Remmina / FreeRDP / git / zram / ripgrep"
apt-get install -y --no-install-recommends \
  ca-certificates curl wget \
  git ripgrep \
  remmina remmina-plugin-rdp remmina-plugin-vnc remmina-plugin-secret \
  freerdp3-x11 gnome-keyring \
  zram-tools
apt-get clean

log "创建用户 $NEW_USER"
if ! id "$NEW_USER" >/dev/null 2>&1; then
  GRPS="$(for g in adm cdrom dip plugdev lpadmin sambashare sudo audio video render; do
            getent group "$g" >/dev/null && printf '%s,' "$g"
          done)"
  useradd -m -U -s /bin/bash -G "${GRPS%,}" "$NEW_USER"
fi
USER_GROUP="$(id -gn "$NEW_USER")"
NEW_PASS="$(cat /tmp/newpass)"
rm -f /tmp/newpass
echo "$NEW_USER:$NEW_PASS" | chpasswd
unset NEW_PASS

log "生成 locale / machine-id / ssh host keys"
locale-gen
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup
ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
command -v ssh-keygen >/dev/null && ssh-keygen -A || true

log "关闭 live 专用服务"
rm -f /etc/systemd/system/graphical.target.wants/ubiquity.service
rm -f /etc/systemd/system/multi-user.target.wants/casper-md5check.service
chmod -x /etc/grub.d/30_os-prober 2>/dev/null || true

# live 镜像里 /var/lib/lightdm 是 root:root 750，会导致 greeter 无法写 .Xauthority 而黑屏
if getent passwd lightdm >/dev/null 2>&1; then
  chown lightdm:lightdm /var/lib/lightdm
  chmod 700 /var/lib/lightdm
  rm -f /var/lib/lightdm/.Xauthority
  mkdir -p /var/lib/lightdm-data/lightdm
  chown lightdm:lightdm /var/lib/lightdm-data/lightdm
  chmod 770 /var/lib/lightdm-data/lightdm
fi

# 修复 polkit 认证助手 setuid（否则电源菜单/确认框不可用）
chmod 4755 /usr/bin/pkexec
chmod 4755 /usr/lib/polkit-1/polkit-agent-helper-1
if getent group messagebus >/dev/null 2>&1; then
  chown root:messagebus /usr/lib/dbus-1.0/dbus-daemon-launch-helper
  chmod 4754 /usr/lib/dbus-1.0/dbus-daemon-launch-helper
fi

# 允许 sudo 组 / lightdm 执行电源操作
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/49-allow-power.rules <<'EOF'
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
chmod 644 /etc/polkit-1/rules.d/49-allow-power.rules

# 桌面兜底电源入口
cat > /usr/share/applications/mint-usb-reboot.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=重启
Name[en]=Reboot
Comment=Restart the system
Exec=pkexec systemctl reboot
Icon=system-reboot
Terminal=false
Categories=System;
EOF
cat > /usr/share/applications/mint-usb-poweroff.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=关机
Name[en]=Power Off
Comment=Power off the system
Exec=pkexec systemctl poweroff
Icon=system-shutdown
Terminal=false
Categories=System;
EOF
chmod 644 /usr/share/applications/mint-usb-*.desktop

log "确保网络与 DNS 服务开机启动"
systemctl enable NetworkManager.service >/dev/null 2>&1 || true
systemctl enable systemd-resolved.service >/dev/null 2>&1 || true
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

log "配置 zram"
if [[ -f /etc/default/zramswap ]]; then
  sed -i 's/^#\?ALGO=.*/ALGO=lz4/; s/^#\?PERCENT=.*/PERCENT=50/' /etc/default/zramswap
fi
if ! systemctl enable zramswap.service >/dev/null 2>&1; then
  for unit in /usr/lib/systemd/system/zramswap.service /lib/systemd/system/zramswap.service; do
    if [[ -f $unit ]]; then
      ln -sf "$unit" /etc/systemd/system/multi-user.target.wants/zramswap.service
      break
    fi
  done
fi

log "安装 OpenCode ${OC_VERSION} 到 ~/.opencode/bin"
mkdir -p /tmp/oc2
tar xzf /tmp/opencode2.tgz -C /tmp/oc2 --strip-components=1
install -d -o "$NEW_USER" -g "$USER_GROUP" "/home/$NEW_USER/.opencode/bin"
install -m 0755 /tmp/oc2/bin/opencode "/home/$NEW_USER/.opencode/bin/opencode"
chown -R "$NEW_USER:$USER_GROUP" "/home/$NEW_USER/.opencode"
ln -sf "/home/$NEW_USER/.opencode/bin/opencode" /usr/local/bin/opencode
for f in "/home/$NEW_USER/.bashrc" "/home/$NEW_USER/.profile"; do
  [[ -f $f ]] || touch "$f"
  grep -q '.opencode/bin' "$f" 2>/dev/null || \
    echo 'export PATH="$HOME/.opencode/bin:$PATH"' >> "$f"
  chown "$NEW_USER:$USER_GROUP" "$f"
done
rm -rf /tmp/oc2 /tmp/opencode2.tgz

log "配置 GRUB 默认项"
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=10/' /etc/default/grub
sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
# 去掉 splash（避免 vt.handoff），关闭 i915 PSR
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="usbcore.autosuspend=-1 i915.enable_psr=0"/' /etc/default/grub
if grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
  sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub
else
  echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
fi

# Xorg 兼容性：禁用 Intel glamor，避免卡在 libglamoregl 初始化
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/20-modesetting-no-glamor.conf <<'EOF'
Section "Device"
    Identifier "Intel modesetting (no glamor)"
    Driver "modesetting"
    Option "AccelMethod" "none"
EndSection
EOF
# 显示器接 Intel 时，黑名单 nouveau
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

# apt 低写入优化（U 盘慢盘）
cat > /etc/apt/apt.conf.d/99-usb-fast <<'EOF'
DPkg::Options { "--force-unsafe-io"; };
APT::Acquire::Languages "none";
EOF
chmod 644 /etc/apt/apt.conf.d/99-usb-fast

log "重建 initramfs"
update-initramfs -u -k all

log "安装 GRUB（UEFI，含 Secure Boot shim）"
SECURE_BOOT=0
if grub-install --target=x86_64-efi --efi-directory=/boot/efi \
      --bootloader-id=ubuntu --uefi-secure-boot --no-nvram; then
  SECURE_BOOT=1
else
  rm -f /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/ubuntu/mmx64.efi 2>/dev/null || true
  grub-install --target=x86_64-efi --efi-directory=/boot/efi \
      --bootloader-id=ubuntu --no-nvram
fi

log "写入 ESP 引导配置"
mkdir -p /boot/efi/EFI/ubuntu /boot/efi/EFI/BOOT
cat > /boot/efi/EFI/ubuntu/grub.cfg <<GRUBCFG
search.fs_uuid $ROOT_UUID root
set prefix=(\$root)'/boot/grub'
configfile \$prefix/grub.cfg
GRUBCFG

# 可移动介质回退路径：保证任何 UEFI 都能从 EFI/BOOT/BOOTX64.EFI 启动
cp -a /boot/efi/EFI/ubuntu/. /boot/efi/EFI/BOOT/ 2>/dev/null || true
if [[ $SECURE_BOOT -eq 1 ]]; then
  if [[ -f /boot/efi/EFI/BOOT/shimx64.efi ]]; then
    cp -f /boot/efi/EFI/BOOT/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
  elif [[ -f /usr/lib/shim/shimx64.efi.signed ]]; then
    cp -f /usr/lib/shim/shimx64.efi.signed /boot/efi/EFI/BOOT/BOOTX64.EFI
  fi
  [[ -f /boot/efi/EFI/BOOT/mmx64.efi ]] || \
    cp -f /usr/lib/shim/mmx64.efi /boot/efi/EFI/BOOT/mmx64.efi 2>/dev/null || true
  cp -f /usr/lib/shim/fbx64.efi /boot/efi/EFI/BOOT/fbx64.efi 2>/dev/null || true
  printf 'shimx64.efi,grubx64.efi,,Linux Mint\n' > /boot/efi/EFI/BOOT/BOOTX64.CSV
else
  cp -f /boot/efi/EFI/BOOT/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
fi
cat > /boot/efi/EFI/BOOT/grub.cfg <<GRUBCFG
search.fs_uuid $ROOT_UUID root
set prefix=(\$root)'/boot/grub'
configfile \$prefix/grub.cfg
GRUBCFG

log "安装 GRUB（Legacy BIOS）"
grub-install --target=i386-pc --boot-directory=/boot "$TARGET_DEV"

log "应用 U 盘性能优化"
# 1) 关闭开机后立刻运行的索引/自动更新定时器（U 盘随机写慢，容易造成键鼠卡顿）
for t in apt-daily.timer apt-daily-upgrade.timer motd-news.timer \
         plocate-updatedb.timer man-db.timer e2scrub_all.timer \
         fwupd-refresh.timer fstrim.timer; do
  rm -f "/etc/systemd/system/timers.target.wants/$t"
  rm -f "/etc/systemd/system/$t"
done
# 2) 限制 journald 日志占用，避免默认按根分区 10% 持续写盘
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-usb.conf <<'EOF'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=20M
RuntimeMaxUse=64M
EOF
# 3) 降低脏页阈值，减少大块写回造成的长时间卡顿
cat > /etc/sysctl.d/99-usb-performance.conf <<'EOF'
vm.swappiness=100
vm.dirty_background_bytes=33554432
vm.dirty_bytes=134217728
vm.dirty_expire_centisecs=3000
vm.dirty_writeback_centisecs=3000
EOF
# 4) USB 存储使用 none 调度器（下次启动生效）
cat > /etc/udev/rules.d/60-usb-iosched.rules <<'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="none"
EOF
# 5) 禁用 USB 自动休眠，避免键鼠接收器/输入设备被挂起造成卡顿
if ! grep -q 'usbcore.autosuspend=-1' /etc/default/grub; then
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 usbcore.autosuspend=-1"/' /etc/default/grub
fi
# 6) 关闭 mintupdate / mintreport 登录自启（仍可从菜单手动打开）
for f in /etc/xdg/autostart/mintupdate.desktop /etc/xdg/autostart/mintreport.desktop; do
  [[ -f "$f" ]] || continue
  if grep -q '^X-GNOME-Autostart-enabled=' "$f"; then
    sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=false/' "$f"
  else
    echo 'X-GNOME-Autostart-enabled=false' >> "$f"
  fi
done
# 7) 修正 GRUB 菜单显示名（部分定制 ISO 的 50_linuxmint.cfg 写的是 Ubuntu）
if [[ -f /etc/default/grub.d/50_linuxmint.cfg ]]; then
  sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Linux Mint"/' /etc/default/grub.d/50_linuxmint.cfg
fi

# 安全启动项：nomodeset 兜底（普通项仍黑屏时选它）
cat > /etc/grub.d/40_custom <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry "Linux Mint (safe graphics, nomodeset)" {
    search --no-floppy --fs-uuid --set=root $ROOT_UUID
    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=$ROOT_UUID ro nomodeset
    initrd /boot/initrd.img-6.14.0-37-generic
}
EOF
chmod 755 /etc/grub.d/40_custom

log "生成 GRUB 菜单"
update-grub

log "验证关键组件"
dpkg -s remmina >/dev/null 2>&1 || { echo "ERROR: remmina 未安装"; exit 1; }
command -v remmina >/dev/null || { echo "ERROR: remmina 命令不存在"; exit 1; }
[[ -x "/home/$NEW_USER/.opencode/bin/opencode" ]] || { echo "ERROR: opencode 未安装"; exit 1; }
runuser -u "$NEW_USER" -- env HOME="/home/$NEW_USER" "/home/$NEW_USER/.opencode/bin/opencode" --version || true

log "chroot 配置完成"
CHROOT_SCRIPT

chmod 755 "$MNT/tmp/setup.sh"

# ------------------------------ 进入 chroot ----------------------------------
log "准备 chroot 环境"
for d in dev dev/pts proc sys; do
  mkdir -p "$MNT/$d"
  mount --bind "/$d" "$MNT/$d"
done
mount -t tmpfs -o mode=755 tmpfs "$MNT/run"

# chroot 内使用真实 resolv.conf，结束后恢复 systemd-resolved 的符号链接
# 注意：如果宿主机使用 systemd-resolved（127.0.0.53），chroot 共享网络命名空间，
# 直接复用该 stub 最稳；否则复制宿主机的上游 DNS。
rm -f "$MNT/etc/resolv.conf"
if grep -q '^nameserver 127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
  DNS_ENTRIES="nameserver 127.0.0.53"
else
  DNS_ENTRIES="$(awk '/^nameserver[[:space:]]/{print "nameserver "$2}' /etc/resolv.conf 2>/dev/null | head -2)"
fi
[[ -n "$DNS_ENTRIES" ]] || DNS_ENTRIES="nameserver 1.1.1.1"
printf '%s\noptions edns0 trust-ad\n' "$DNS_ENTRIES" > "$MNT/etc/resolv.conf"

printf '%s' "$PASS1" > "$MNT/tmp/newpass"
chmod 600 "$MNT/tmp/newpass"
cp -f "$OC_TGZ" "$MNT/tmp/opencode2.tgz"

log "进入 chroot 安装软件与引导（Remmina / OpenCode / GRUB）"
chroot "$MNT" /usr/bin/env \
  NEW_USER="$NEW_USER" NEW_HOST="$NEW_HOST" ROOT_UUID="$ROOT_UUID" \
  TARGET_DEV="$DEV" OC_VERSION="$OC_VERSION" \
  /bin/bash /tmp/setup.sh

# 数据分区挂载选项里的 uid/gid 对齐实际用户
NEW_UID="$(chroot "$MNT" id -u "$NEW_USER")"
NEW_GID="$(chroot "$MNT" id -g "$NEW_USER")"
sed -i "s/uid=1000,gid=1000/uid=$NEW_UID,gid=$NEW_GID/" "$MNT/etc/fstab"

# ------------------------------- 收尾 ----------------------------------------
log "清理临时文件与挂载"
rm -f "$MNT/tmp/setup.sh" "$MNT/tmp/newpass" "$MNT/tmp/opencode2.tgz"
rm -rf "$MNT/tmp/oc2"
rm -f "$MNT/etc/resolv.conf"
ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"

sync
umount "$MNT/run" 2>/dev/null || true
umount "$MNT/dev/pts" 2>/dev/null || true
umount "$MNT/dev" 2>/dev/null || true
umount "$MNT/proc" 2>/dev/null || true
umount -R "$MNT/sys" 2>/dev/null || true
umount "$MNT/boot/efi" 2>/dev/null || true
umount -R "$MNT" 2>/dev/null || true
sync

log "完成！"
cat <<EOF

安装摘要
  设备      : $DEV
  root UUID : $ROOT_UUID  (ext4, $ROOT_SIZE)
  ESP UUID  : $ESP_UUID   (FAT32, 1GB)
  数据区    : $SHARE_UUID (exFAT, Windows 可读写)
  用户      : $NEW_USER / 你设置的密码
  主机名    : $NEW_HOST
  引导      : UEFI (shim + secure boot) + Legacy BIOS
  预装      : Remmina (RDP/VNC) + FreeRDP3, git, ripgrep, zram, OpenCode $OC_VERSION

下一步
  1. 安全弹出 U 盘，重启并在启动菜单选择它。
  2. 首次进入后: Ctrl+Space 切换中文输入法; 终端运行 opencode。
  3. 检查 Remmina: 开始菜单 -> Remmina，新建 RDP 连接。
EOF

lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DEV"
