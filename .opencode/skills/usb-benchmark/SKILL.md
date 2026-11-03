---
name: USB Benchmark
description: Test a USB flash drive or portable SSD before building a portable Linux USB. Measures sequential and 4K random write, fsync, read speed, BOT/UAS protocol, and write cache, then returns GOOD/PASS/WARN/FAIL.
---

# USB Benchmark

Use this skill **before** making a portable Linux USB, or when an existing USB feels slow during `apt upgrade`, browser cache, or desktop use.

The goal is to reject a slow drive **before** spending an hour installing a system on it.

## Safety

- Only write test files to a **mounted filesystem on the target USB**.
- Never run it on the host root filesystem.
- The script checks that `TARGET` belongs to `DEV` and is not the root source.
- For a new blank drive, creating the temporary test partition below is destructive; confirm there is no data to keep.

## Preparation

The drive must have a mounted filesystem. Use an existing partition, or for a new drive create a temporary one (this wipes that partition):

```bash
sudo sgdisk --zap-all /dev/sdX
sudo sgdisk -n 1:0:0 -t 1:8300 /dev/sdX
sudo mkfs.ext4 -L USBTEST /dev/sdX1
sudo mkdir -p /mnt/usbtest
sudo mount /dev/sdX1 /mnt/usbtest
```

> Replace `/dev/sdX` with the target USB. Double-check with `lsblk`.

## Run

```bash
# quick: 64MB + 5s random tests
sudo DEV=/dev/sdX TARGET=/mnt/usbtest MODE=quick \
  bash scripts/usb-benchmark.sh

# full: 256MB + 10s random tests (recommended before building)
sudo DEV=/dev/sdX TARGET=/mnt/usbtest MODE=full \
  bash scripts/usb-benchmark.sh
```

Requirements: `fio`, `python3`, root, `util-linux`; `hdparm` and `usbutils` are optional.

The script prints a Markdown report and writes `usb-benchmark-<timestamp>.md` in the current directory. Unmount when done.

## Thresholds

| Verdict | Sequential write | 4K random write QD1 | Meaning |
|---|---:|---:|---|
| GOOD | ≥ 50 MB/s | ≥ 5 MB/s | Suitable for a long-term portable dev drive |
| PASS | ≥ 20 MB/s | ≥ 2 MB/s | Usable; apt won't be painful |
| WARN | ≥ 10 MB/s | ≥ 1 MB/s | Runs, but upgrades/cache will be slow |
| FAIL | < 10 MB/s | < 1 MB/s | Do not use for a full portable Linux install |

Read speed is not the deciding factor. A drive can read at 200 MB/s and still be unusable for `apt` if 4K write is 0.3 MB/s.

Also note:

- **BOT vs UAS**: BOT (`bInterfaceProtocol=80`) is common on cheap drives; UAS is better.
- **write through / write cache not supported**: small-file writes and fsync become much slower.
- **fsync result**: below ~0.5 MB/s means `dpkg` will crawl.

## Decision

- **GOOD / PASS**: proceed with the full portable Linux build.
- **WARN**: only use for light live sessions; avoid large `apt upgrade`, Docker, IDE, browser caches.
- **FAIL**: replace the drive. Use a USB 3.x SSD (Samsung T7, SanDisk Extreme, Kingston XS1000, etc.) or a high-end flash drive. Software tweaks cannot fix 1 MB/s writes.

## Reference results

| Drive | Seq write | 4K write QD1 | fsync | Read | Protocol | Verdict |
|---|---:|---:|---:|---:|---|---|
| ASolid 128GB USB 3.0 | 1.87 MB/s | 0.27 MB/s | 0.13 MB/s | 200 MB/s | BOT, write through | FAIL |
| Kingston DataTraveler 3.0 115.5GB | 9.99 MB/s | 0.81 MB/s | 0.58 MB/s | 53.7 MB/s | BOT, write through | FAIL |

Both drives show the same pattern: fast reads, very slow small writes. The Kingston is better than the ASolid but still below the usable line for a full Linux install.

## After the test

If the drive passes, run the main build:

```bash
sudo DEV=/dev/sdX bash scripts/install-mint-usb.sh --check
sudo DEV=/dev/sdX bash scripts/install-mint-usb.sh
```

See the repository `docs/08-usb-benchmark.md` for methodology, reports, and decisions.
