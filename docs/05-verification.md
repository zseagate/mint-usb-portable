# 05 · 首次启动验收清单

## 启动

- [ ] UEFI 机器：启动菜单出现 `UEFI: <U 盘名>`，可以进入 GRUB
- [ ] Legacy 机器：启动菜单出现普通 USB 项，可以进入 GRUB
- [ ] GRUB 菜单显示 `Linux Mint`，3 秒超时
- [ ] 进入 LightDM 登录界面（不是黑屏）

## 中文与输入法

登录 `mint` 后：

```bash
locale
# 期望：LANG=zh_CN.UTF-8

fcitx5-diagnose
# 检查 fcitx5 是否正常运行、前端是否加载

cat ~/.xinputrc
# 期望：run_im fcitx5
```

- [ ] 桌面为中文
- [ ] 右上角有 fcitx5 图标
- [ ] `Ctrl+Space` 能切换中英文
- [ ] 能输入拼音/五笔
- [ ] Firefox 界面为中文

## 网络

```bash
nmcli device status
ping -c 3 mirrors.aliyun.com
```

- [ ] 有线/无线可连接
- [ ] DNS 正常
- [ ] 浏览器能打开网页

## OpenCode

```bash
opencode --version
# 期望：2.2.5
which opencode
# 期望：/usr/local/bin/opencode 或 ~/.opencode/bin/opencode
```

- [ ] `opencode` 能启动 TUI
- [ ] 首次运行可配置模型/API key

## Remmina

```bash
remmina
```

- [ ] 能打开 Remmina
- [ ] 新建 RDP 连接，协议选 RDP
- [ ] 能连接 Windows 专业版/企业版的远程桌面

> Windows 家庭版没有 RDP 服务端，见 [07 · FAQ](07-faq.md)。

## 星火应用商店

```bash
spark-store
dpkg -s spark-store | grep -E '^(Version|Status):'
```

- [ ] 菜单里出现“星火应用商店”
- [ ] 能打开商店并加载应用列表
- [ ] 能安装一个测试应用

## 数据分区

```bash
mount | grep /data
touch /data/_rwtest && rm /data/_rwtest
```

- [ ] `/data` 已挂载
- [ ] 普通用户 `mint` 可读写
- [ ] Windows 下能看到 `SHARE` 分区

## 持久化

```bash
echo test > ~/persist-test.txt
```

重启后：

```bash
cat ~/persist-test.txt
```

- [ ] 文件还在
- [ ] 输入法词库/配置还在
- [ ] OpenCode 配置还在
- [ ] `/data` 文件还在

## 性能

```bash
uptime
top -b -n1 | head -20
systemctl list-timers --all
```

- [ ] 开机 1–2 分钟后没有 `plocate` / `updatedb` / `apt-daily` 长时间占 CPU
- [ ] 键鼠无明显延迟
- [ ] `systemctl list-timers` 里不再有 `apt-daily`、`plocate-updatedb`

## 引导安全

- [ ] 主机 `/dev/sda` 的引导没有被改动
- [ ] U 盘拔掉后主机仍能正常启动
- [ ] U 盘在另一台机器上也能启动（可选）

## 如果失败

| 现象 | 先看 |
|---|---|
| 黑屏 | `/var/log/lightdm/lightdm.log`、`seat0-greeter.log` |
| 卡在 GRUB | Secure Boot、ESP 文件、`EFI/BOOT/BOOTX64.EFI` |
| 卡在 initramfs | 根分区 UUID、`/etc/fstab`、`update-initramfs` |
| 没有中文/输入法 | `locale`、`~/.xinputrc`、`fcitx5-diagnose` |
| 键鼠卡顿 | `top`、`systemctl list-timers`、`/var/log/syslog` |

下一篇：[06 · 性能优化](06-performance.md)
