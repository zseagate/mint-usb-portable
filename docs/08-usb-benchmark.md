# 08 · 制作前先测 U 盘：性能基准与判定标准

> 这一篇是后补的。第一版系统做完后，`apt upgrade` 慢到无法接受，最后用 `fio` 测出 U 盘顺序写只有 **1.87MB/s**、4K 随机写 **268KB/s**——再多的系统优化也救不了。

## 为什么必须先测

随身 Linux 的体验几乎完全由 **写入性能** 决定：

- `apt upgrade` / `dpkg` 要解包大量小文件并 fsync
- 浏览器缓存、日志、输入法词库都在写
- 桌面卡顿很多时候是写回（writeback）把 I/O 占满

读速度快不代表能用。旧盘顺序读 200MB/s，但顺序写 1.87MB/s，结果就是“能开机、能看网页，但一升级就卡死”。

## 基准脚本

仓库根目录：

```bash
scripts/usb-benchmark.sh
```

同时提供为 OpenCode 技能：`usb-benchmark`（见 `.opencode/skills/usb-benchmark/`）。

### 准备一个可写文件系统

测试只写测试文件，不分区。目标盘必须先挂载一个文件系统。

新盘/空盘可以创建一个临时 ext4 测试分区（**会清空该分区**）：

```bash
sudo sgdisk --zap-all /dev/sdX
sudo sgdisk -n 1:0:0 -t 1:8300 /dev/sdX
sudo mkfs.ext4 -L USBTEST /dev/sdX1
sudo mkdir -p /mnt/usbtest
sudo mount /dev/sdX1 /mnt/usbtest
```

### 运行

```bash
# 快速筛查：64MB 顺序写 + 5 秒随机写
sudo DEV=/dev/sdX TARGET=/mnt/usbtest MODE=quick \
  bash scripts/usb-benchmark.sh

# 正式评估：256MB 顺序写 + 10 秒随机写
sudo DEV=/dev/sdX TARGET=/mnt/usbtest MODE=full \
  bash scripts/usb-benchmark.sh
```

依赖：`fio`、`python3`、root；`hdparm` / `usbutils` 可选。

脚本会输出 Markdown 报告，并写入当前目录的 `usb-benchmark-<timestamp>.md`。

## 判定标准

| 等级 | 顺序写 | 4K 随机写 QD1 | 结论 |
|---|---:|---:|---|
| **GOOD** | ≥ 50 MB/s | ≥ 5 MB/s | 适合长期便携开发 |
| **PASS** | ≥ 20 MB/s | ≥ 2 MB/s | 可用，apt 不会太痛苦 |
| **WARN** | ≥ 10 MB/s | ≥ 1 MB/s | 能跑，但升级/缓存慢 |
| **FAIL** | < 10 MB/s | < 1 MB/s | 不建议做完整启动盘 |

补充：

- **4K 随机写比顺序写更重要**。`apt` 不是复制大文件，而是写大量小文件。
- **fsync 低于 0.5MB/s** 时，`dpkg` 会非常慢。
- **BOT（`bInterfaceProtocol=80`）** 不如 UAS；廉价盘常见。
- **`write through` / 写缓存不支持** 会进一步放大 fsync 和小文件写入的延迟。
- 读速度只用于判断链路（USB 3.x 正常应在 100MB/s 以上）。

## 实测结果

### ASolid 128GB USB 3.0（旧盘）

| 测试 | 结果 |
|---|---:|
| 顺序读 | 200 MB/s |
| 顺序写 | 1.87 MB/s |
| 4K 随机写 QD1 | 0.27 MB/s |
| 4K 随机写 QD32 | 0.27 MB/s |
| 4K 写 + fsync | 0.13 MB/s |
| 协议 / 写缓存 | BOT / `write through`，`hdparm -W1` 不支持 |
| **判定** | **FAIL** |

结果：能启动、能进桌面，但 `apt upgrade` 极慢，键鼠在后台写入时明显卡顿。

### Kingston DataTraveler 3.0 115.5GB（新盘）

Quick（64MB）：

| 测试 | 结果 |
|---|---:|
| 顺序写 | 12.78 MB/s |
| 顺序读 | 57.25 MB/s |
| 4K 随机写 QD1 | 0.83 MB/s |
| 4K 写 + fsync | 0.57 MB/s |
| **判定** | **FAIL** |

Full（256MB）：

| 测试 | 结果 |
|---|---:|
| 顺序写 | **9.99 MB/s**（持续写入掉速） |
| 顺序读 | 53.69 MB/s |
| 4K 随机写 QD1 | 0.81 MB/s |
| 4K 随机写 QD32 | 0.82 MB/s |
| 4K 写 + fsync | 0.58 MB/s |
| 协议 / 写缓存 | BOT / `write through` |
| **判定** | **FAIL** |

结论：Kingston 比 ASolid 快约 5 倍，但 4K 随机写仍不到 1MB/s，**不适合完整随身 Linux 开发盘**。如果只做轻量 live 使用可以，但 `apt upgrade`、OpenCode、浏览器缓存仍会慢。

完整报告：

- [reports/kingston-datatraveler-3.0-quick.md](reports/kingston-datatraveler-3.0-quick.md)
- [reports/kingston-datatraveler-3.0-full.md](reports/kingston-datatraveler-3.0-full.md)

## 结论与建议

1. **制作前必须跑 full 基准**，不要只看商家标称速度。
2. **FAIL 的盘不要做完整安装**。可以做 Ventoy/live 应急盘，但不要装 OpenCode、星火、开发工具。
3. 想要“随身开发机”体验，建议：
   - USB 3.2 固态 U 盘 / 移动 SSD（Samsung T7、SanDisk Extreme、Kingston XS1000 等）
   - 或直接用小容量 NVMe + USB 硬盘盒
4. 如果只能用慢盘：
   - 使用本仓库的 `install-mint-usb.sh`（已包含 `--force-unsafe-io`、`commit=30` 等低写入优化）
   - 不要一次 `apt upgrade` 几百个包，分批来
   - 重要数据同时备份，慢盘也可能是寿命/颗粒问题

## 新盘制作流程

```text
1. lsblk 确认目标盘（必须是 USB，且不是系统盘）
2. 挂载/创建测试分区
3. usb-benchmark.sh MODE=full
4. 看判定：
   GOOD/PASS → 继续制作
   WARN      → 只做轻量使用
   FAIL      → 换盘，不要浪费时间装系统
5. 通过后再运行 install-mint-usb.sh
```

## 相关

- 脚本：`scripts/usb-benchmark.sh`
- 技能：`.opencode/skills/usb-benchmark/SKILL.md`
- 性能调优：`docs/06-performance.md`
- 踩坑记录：`docs/04-pitfalls.md`
