#!/usr/bin/env bash
# =============================================================================
# USB 随身 Linux 启动盘性能基准
#
# 在制作启动盘之前，先测目标 U 盘/移动固态的真实写入能力。
# 只写测试文件，不分区、不清盘（TARGET 必须是目标盘上已挂载的文件系统）。
#
# 用法:
#   sudo DEV=/dev/sdX TARGET=/mnt/usbtest bash usb-benchmark.sh
#   sudo DEV=/dev/sdX TARGET=/mnt/usbtest MODE=quick bash usb-benchmark.sh
#
# 新盘没有文件系统时，先建一个临时测试分区（会清空该盘）：
#   sudo sgdisk --zap-all /dev/sdX
#   sudo sgdisk -n 1:0:0 -t 1:8300 /dev/sdX
#   sudo mkfs.ext4 -L USBTEST /dev/sdX1
#   sudo mkdir -p /mnt/usbtest && sudo mount /dev/sdX1 /mnt/usbtest
#
# 依赖: fio, python3, util-linux, hdparm（可选）, usbutils（可选）
# =============================================================================
set -Eeuo pipefail

DEV="${DEV:-/dev/sdb}"
TARGET="${TARGET:-}"
MODE="${MODE:-full}"          # full | quick
SEQ_SIZE="${SEQ_SIZE:-}"
RUNTIME="${RUNTIME:-}"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 sudo 运行"
[[ -b "$DEV" ]] || die "设备不存在: $DEV"
[[ $(lsblk -dno TRAN "$DEV" | tr -d '[:space:]') == usb ]] || die "$DEV 不是 USB 设备"
ROOT_SRC="$(findmnt -no SOURCE /)"
[[ "$ROOT_SRC" != "$DEV"* ]] || die "$DEV 是当前根分区所在磁盘，拒绝测试"

command -v fio >/dev/null || die "缺少 fio，请先: sudo apt install fio"
command -v python3 >/dev/null || die "缺少 python3"

case "$MODE" in
  quick)
    SEQ_SIZE="${SEQ_SIZE:-64M}"
    RUNTIME="${RUNTIME:-5}"
    RAND_SIZE="64M"
    FSYNC_SIZE="32M"
    ;;
  full)
    SEQ_SIZE="${SEQ_SIZE:-256M}"
    RUNTIME="${RUNTIME:-10}"
    RAND_SIZE="128M"
    FSYNC_SIZE="64M"
    ;;
  *) die "MODE 只能是 full 或 quick" ;;
esac

if [[ -z "$TARGET" ]]; then
  TARGET="$(lsblk -lnpo NAME,MOUNTPOINT "$DEV" | awk 'NF > 1 && $2 != "" {print $2; exit}')"
fi
[[ -n "$TARGET" ]] || cat <<EOF
未找到已挂载的目标分区。

请先挂载 U 盘上的一个分区，或为新盘创建临时测试分区（会清空该盘）：

  sudo sgdisk --zap-all $DEV
  sudo sgdisk -n 1:0:0 -t 1:8300 $DEV
  sudo mkfs.ext4 -L USBTEST ${DEV}1
  sudo mkdir -p /mnt/usbtest && sudo mount ${DEV}1 /mnt/usbtest

然后：
  sudo DEV=$DEV TARGET=/mnt/usbtest bash $0

EOF
[[ -n "$TARGET" ]] || exit 1

[[ -d "$TARGET" ]] || die "TARGET 不存在: $TARGET"
SRC="$(findmnt -no SOURCE --target "$TARGET")"
[[ "$SRC" == "$DEV"* ]] || die "TARGET 不在 $DEV 上（当前来源: $SRC）"
[[ "$SRC" != "$ROOT_SRC" ]] || die "不要在运行中的根文件系统上测试"

FSTYPE="$(findmnt -no FSTYPE --target "$TARGET")"
FREE_MB="$(df -Pm "$TARGET" | awk 'NR==2 {print $4}')"
NEED_MB=512
[[ "$MODE" == "quick" ]] && NEED_MB=256
(( FREE_MB >= NEED_MB )) || die "TARGET 可用空间不足: ${FREE_MB}MB < ${NEED_MB}MB"

DIRECT=1
case "$FSTYPE" in
  ext4|xfs|btrfs) DIRECT=1 ;;
  *) DIRECT=0 ;;
esac

BASE="$(basename "$DEV")"
WORK="$TARGET/.usb-benchmark-$$"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; sync; }
trap cleanup EXIT

log "设备信息"
lsblk -dno NAME,MODEL,SERIAL,SIZE,TRAN,ROTA "$DEV"
echo "文件系统: $FSTYPE  挂载点: $TARGET  可用: ${FREE_MB}MB"
echo "调度器: $(cat /sys/block/$BASE/queue/scheduler 2>/dev/null)"
echo "写缓存: $(cat /sys/block/$BASE/queue/write_cache 2>/dev/null || echo unknown)"
echo "逻辑/物理块: $(cat /sys/block/$BASE/queue/logical_block_size 2>/dev/null)/$(cat /sys/block/$BASE/queue/physical_block_size 2>/dev/null)"
hdparm -W "$DEV" 2>/dev/null | tail -2 || true

PROTO="unknown"
VID="$(udevadm info -q property -n "$DEV" | awk -F= '/^ID_VENDOR_ID=/{print $2}')"
PID="$(udevadm info -q property -n "$DEV" | awk -F= '/^ID_MODEL_ID=/{print $2}')"
if [[ -n "$VID" && -n "$PID" ]] && command -v lsusb >/dev/null; then
  P="$(lsusb -v -d "$VID:$PID" 2>/dev/null | awk '/bInterfaceProtocol/{print $2; exit}')"
  case "$P" in
    80) PROTO="BOT (Bulk-Only)" ;;
    98) PROTO="UAS" ;;
    *) PROTO="${P:-unknown}" ;;
  esac
fi
echo "USB 协议: $PROTO"

run_fio() {
  local name="$1"; shift
  local out="$WORK/$name.json"
  if fio --output-format=json --output="$out" "$@" >/dev/null 2>&1; then
    echo "$out"; return 0
  fi
  # 某些文件系统（exFAT/vFat）不支持 O_DIRECT，自动回退
  local args=()
  local a
  for a in "$@"; do
    [[ "$a" == "--direct=1" ]] && a="--direct=0"
    args+=("$a")
  done
  fio --output-format=json --output="$out" "${args[@]}" >/dev/null 2>&1 || die "fio $name 失败"
  echo "$out"
}

read_metrics() {
  python3 - "$1" "$2" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))["jobs"][0]
k = sys.argv[2]
d = j.get(k, {})
bw = d.get("bw_bytes", 0) / 1048576.0
iops = d.get("iops", 0)
lat = d.get("clat_ns", {}).get("mean", 0) / 1_000_000.0
print(f"{bw:.2f} {iops:.1f} {lat:.2f}")
PY
}

log "顺序写 ${SEQ_SIZE}（direct=${DIRECT}）"
SEQW_JSON=$(run_fio seqwrite \
  --name=seqwrite --filename="$WORK/seq.bin" --size="$SEQ_SIZE" --bs=1M \
  --rw=write --direct="$DIRECT" --end_fsync=1 --group_reporting)
read -r SEQW_BW SEQW_IOPS SEQW_LAT < <(read_metrics "$SEQW_JSON" write)

log "顺序读（尽量绕过缓存）"
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
SEQR_JSON=$(run_fio seqread \
  --name=seqread --filename="$WORK/seq.bin" --size="$SEQ_SIZE" --bs=1M \
  --rw=read --direct="$DIRECT" --group_reporting)
read -r SEQR_BW SEQR_IOPS SEQR_LAT < <(read_metrics "$SEQR_JSON" read)

log "4K 随机写 QD1 ${RUNTIME}s"
R1_JSON=$(run_fio rand4k_qd1 \
  --name=rand4k_qd1 --filename="$WORK/rand.bin" --size="$RAND_SIZE" --bs=4k \
  --rw=randwrite --iodepth=1 --runtime="$RUNTIME" --time_based \
  --direct="$DIRECT" --group_reporting)
read -r R1_BW R1_IOPS R1_LAT < <(read_metrics "$R1_JSON" write)

log "4K 随机写 QD32 ${RUNTIME}s"
R32_JSON=$(run_fio rand4k_qd32 \
  --name=rand4k_qd32 --filename="$WORK/rand.bin" --size="$RAND_SIZE" --bs=4k \
  --rw=randwrite --iodepth=32 --runtime="$RUNTIME" --time_based \
  --direct="$DIRECT" --group_reporting)
read -r R32_BW R32_IOPS R32_LAT < <(read_metrics "$R32_JSON" write)

log "4K 写 + 每块 fsync ${RUNTIME}s"
FS_JSON=$(run_fio fsync4k \
  --name=fsync4k --filename="$WORK/fsync.bin" --size="$FSYNC_SIZE" --bs=4k \
  --rw=write --fsync=1 --iodepth=1 --runtime="$RUNTIME" --time_based \
  --direct="$DIRECT" --group_reporting)
read -r FS_BW FS_IOPS FS_LAT < <(read_metrics "$FS_JSON" write)

# ---------------- 评估 ----------------
VERDICT="PASS"
REASON=""

if awk "BEGIN{exit !($SEQW_BW < 10 || $R1_BW < 1)}"; then
  VERDICT="FAIL"
  REASON="顺序写 <10MB/s 或 4K 随机写 <1MB/s，不适合做随身 Linux 启动盘"
elif awk "BEGIN{exit !($SEQW_BW >= 50 && $R1_BW >= 5)}"; then
  VERDICT="GOOD"
  REASON="写入性能优秀，适合长期当便携开发盘"
elif awk "BEGIN{exit !($SEQW_BW >= 20 && $R1_BW >= 2)}"; then
  VERDICT="PASS"
  REASON="写入性能可用，apt/桌面会明显快于低端盘"
else
  VERDICT="WARN"
  REASON="能启动，但 apt/升级/浏览器缓存会偏慢，建议只做轻量使用"
fi

if awk "BEGIN{exit !($SEQR_BW < 100)}"; then
  warn "顺序读 ${SEQR_BW} MB/s < 100MB/s，可能不是 USB 3.x 高速口/链路"
fi
if [[ "$PROTO" == BOT* ]]; then
  warn "USB 协议为 BOT，不是 UAS；随机性能通常不如 UAS"
fi
if [[ "$(cat /sys/block/$BASE/queue/write_cache 2>/dev/null)" == "write through" ]]; then
  warn "写缓存为 write through（设备不支持/被禁用），小文件写入会明显偏慢"
fi

REPORT="usb-benchmark-$(date +%Y%m%d-%H%M%S).md"
cat > "$REPORT" <<EOF
# USB 性能基准报告

- 日期：$(date '+%F %T')
- 设备：\`$DEV\`
- 容量/型号：$(lsblk -dno SIZE,MODEL "$DEV" | sed 's/  */ /g')
- 文件系统 / 挂载点：$FSTYPE / \`$TARGET\`
- USB 协议：$PROTO
- 调度器：$(cat /sys/block/$BASE/queue/scheduler 2>/dev/null)
- 写缓存：$(cat /sys/block/$BASE/queue/write_cache 2>/dev/null || echo unknown)
- 模式：$MODE

## 结果

| 测试 | 带宽 | IOPS | 平均延迟 |
|---|---:|---:|---:|
| 顺序写 | ${SEQW_BW} MB/s | ${SEQW_IOPS} | ${SEQW_LAT} ms |
| 顺序读 | ${SEQR_BW} MB/s | ${SEQR_IOPS} | ${SEQR_LAT} ms |
| 4K 随机写 QD1 | ${R1_BW} MB/s | ${R1_IOPS} | ${R1_LAT} ms |
| 4K 随机写 QD32 | ${R32_BW} MB/s | ${R32_IOPS} | ${R32_LAT} ms |
| 4K 写 + fsync | ${FS_BW} MB/s | ${FS_IOPS} | ${FS_LAT} ms |

## 结论：**$VERDICT**

$REASON

## 判定标准

| 等级 | 顺序写 | 4K 随机写 QD1 | 说明 |
|---|---:|---:|---|
| GOOD | ≥ 50 MB/s | ≥ 5 MB/s | 适合长期便携开发 |
| PASS | ≥ 20 MB/s | ≥ 2 MB/s | 可用，apt 不会太痛苦 |
| WARN | ≥ 10 MB/s | ≥ 1 MB/s | 能跑，但升级/缓存会慢 |
| FAIL | < 10 MB/s | < 1 MB/s | 不建议做启动盘 |

> 读速度再高也弥补不了写速度。随身 Linux 的瓶颈几乎总是写入。
EOF

echo
sed -n '1,99p' "$REPORT"
log "报告已写入: $REPORT"

case "$VERDICT" in
  GOOD|PASS) exit 0 ;;
  WARN) exit 2 ;;
  FAIL) exit 1 ;;
esac
