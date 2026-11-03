# USB 性能基准报告

- 日期：2026-11-03 11:34:21
- 设备：`/dev/sdb`
- 容量/型号：115.5G DataTraveler 3.0
- 文件系统 / 挂载点：ext4 / `/mnt/usbtest`
- USB 协议：BOT (Bulk-Only)
- 调度器：none [mq-deadline] 
- 写缓存：write through
- 模式：full

## 结果

| 测试 | 带宽 | IOPS | 平均延迟 |
|---|---:|---:|---:|
| 顺序写 | 9.99 MB/s | 10.0 | 100.00 ms |
| 顺序读 | 53.69 MB/s | 53.7 | 18.61 ms |
| 4K 随机写 QD1 | 0.81 MB/s | 208.5 | 4.79 ms |
| 4K 随机写 QD32 | 0.82 MB/s | 209.4 | 4.77 ms |
| 4K 写 + fsync | 0.58 MB/s | 147.6 | 3.15 ms |

## 结论：**FAIL**

顺序写 <10MB/s 或 4K 随机写 <1MB/s，不适合做随身 Linux 启动盘

## 判定标准

| 等级 | 顺序写 | 4K 随机写 QD1 | 说明 |
|---|---:|---:|---|
| GOOD | ≥ 50 MB/s | ≥ 5 MB/s | 适合长期便携开发 |
| PASS | ≥ 20 MB/s | ≥ 2 MB/s | 可用，apt 不会太痛苦 |
| WARN | ≥ 10 MB/s | ≥ 1 MB/s | 能跑，但升级/缓存会慢 |
| FAIL | < 10 MB/s | < 1 MB/s | 不建议做启动盘 |

> 读速度再高也弥补不了写速度。随身 Linux 的瓶颈几乎总是写入。
