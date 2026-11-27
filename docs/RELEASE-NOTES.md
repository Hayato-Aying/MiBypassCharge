# Release notes · v1.8.1

> 本文件供打 Release 时复制。发布包：`MiBypassCharge-v1.8.1.zip`
> 大小 `88337` 字节，SHA-256 `03ddc1c4c4d9f3612d19a6753a86d2584fd21882175d8c5657f9ad6d6d65934c`
> （zip 条目带打包时间戳，重新打包哈希会变；上面是 Release 附件那一次的实测值，
> 字节数固定 `88337`，核验以 Release 页附件为准）
> 磁贴 APK：这次**没有重建**（本机没有 Android SDK），包内仍是 v1.8.0-fork.1 构建的那份
> （`46,174` 字节，SHA-256 `900affa091aa8cd342df2f641e0d267ee98903be509436b2c49129436f589017`）。
> 磁贴代码本版没动，功能不受影响；只是 App 里显示的版本号还是旧的，
> 要让版本号跟着变，得在装了 Android SDK 的机器上跑一次 `build-app.sh`。
> 上游改动史见 `变更说明.md`（历史档，里面的路径仍是旧的 `bypass_guard`）。

这是 [ChangXYZ-CPU/MiBypassCharge](https://github.com/ChangXYZ-CPU/MiBypassCharge)
v1.8.0 的个人 fork，只在自己一台 Redmi K70 上验证，**不是上游官方发布**。

## 本版改动（v1.8.1）：5 处审计修复，不改功能

`smart_chg` 的写入参数、阈值、滞回裁决、UI 行为一律没动。逐条说明见 `变更说明.md` 第 17 节。

- **守护被强杀后可能「不充电」**：启动时若发现残留 `bp_on=1`，先 `smart_clear` 复位驱动。
  `on_exit` 只在自己捕获到信号时才跑，被 SIGKILL / LMK 带走时驱动停充位还武装着，
  只清记账就会留下「界面说没旁路、手机却不充电」；电量落在滞回区时 `do_on`/`do_off`
  两支都不进，一直不充
- **`input_suspend` 兜底写守 flock**：`do_off` 里那处裸重定向改成 `write_node`，
  不再绕开节点写串行化
- **`bg-watch` 不再误删自己的锁**：`EXIT` trap 换成 `INT`/`TERM`/`HUP`。
  管道子 shell 会继承 `EXIT` trap，而 `$$` 在子 shell 里与父进程相同，
  pid 校验拦不住 —— 子 shell 一结束就删掉了还活着的锁
- **`flip` 耗时注释按事实改写**：关一路 ≥3 秒、最坏约 5.4 秒（原来写「300ms 内返回」），
  磁贴侧 6 秒 `waitFor` 余量不到 1 秒
- **仓库地址**：`README.md` / `build.sh` / `module/USAGE.txt` 里的 `1918554837` 改成 `Hayato-Aying`

## 实测环境

| 项目 | 值 |
|---|---|
| 机型 | Redmi K70（`23113RKC6C` / `vermeer` / SM8550） |
| 系统 | `OS4.0.3.0.XNKCNXM`，Android 17，内核 5.15.194 |
| Root | KernelSU（WebUI 依赖 `window.ksu`，不支持 Magisk / APatch） |
| 停充节点 | `/sys/class/qcom-battery/smart_chg`，`persist.vendor.smartchg=6`（含 bit1） |

## 与上游 v1.8.0 的差别

- **附带控制中心磁贴 App**（`tile/`，约 45 KB）：`MainActivity` 是 WebUI 的宿主
  （桌面图标、磁贴长按都进它），`TileService` 是磁贴。刷入时 `customize.sh` 自动装，
  被系统拦下就留到 `/sdcard/Download/`，开机后 `service.sh` 再试一次
- **磁贴防冻结**：HyperOS 的 freezer 会把没绑前台的磁贴冻成 `do_freezer_trap`，
  表现为「点了没反应」。root 侧 `bg-tile-keep.sh` 每 20 秒把 `oom_score_adj` 钉到
  `-900` 并解冻已冻进程；守护每 5 轮检查是否被杀，被杀就补起
- **磁贴读状态不再起 su**：守护把状态副本写进 App 私有目录（`/data/adb` 是 0700，
  App 读不到），磁贴读文件 0 ms 出状态
- **`force_off` 恢复为正式状态**：上游 v1.7.2 那条 `force_off → auto` 的迁移删掉了，
  否则磁贴「关」之后 auto 到阈值又会继续停充，用户看到的就是「关不掉」；
  现在充满后由守护交回 `auto`
- **`flip` 明确带方向**：`flip on` / `flip off` / `flip cancel`，无参数的旧形式保留给
  已安装的旧磁贴（按 MODE 翻转）。WebUI 和磁贴都不再让后台猜意图
- **写节点加重试**：`smart_clear` 两次写都加了重试，`flock` 抢不到锁不再静默
- **插拔监听固定常开**：界面上的开关取消，`WATCH` 恒为 1。`logcat -b events` 只收
  `battery_status` 一个 tag，约 0.23% 单核；关掉反而让「按阈值自动 + 刚插上」
  最多等一个巡检周期才停充
- **阈值输入不再被刷新覆盖**：3 秒状态刷新会跳过有焦点的输入框
  （以前手动输「用到多少才充」，一松手就被改回旧值）
- **版本号唯一来源 `module/module.prop`**：WebUI 底部、安装横幅、日志都从它读，
  不再出现「升了级日志还写 v1.7.2」

## 功能

- 插电后充到「充到多少停」（默认 80%）停充，手机改由适配器直供，电池 0 W
- 掉到「用到多少才充」（默认 75%）再恢复充电，中间保持现状（滞回）
- 停充走小米官方 `smart_chg` 位，与安全中心「导航断充保护」同款，驱动自保持，拔插不丢
- 状态判定只看电池电流：充电为正、放电为负，`|I| < 120 mA` 才算停充成功
- WebUI 可调：总开关、两个阈值、巡检间隔（默认 30 秒）；按钮「立即旁充」/「按阈值自动」
- 总开关关掉 = 守护、看护、监听全停，零常驻

## 升级 / 安装

如果你之前装的是上游版本，模块 ID 不同（上游是 `bypass_guard`，这里是
`MiBypassCharge`），KernelSU 会把它们当成两个模块，**先卸载旧模块再装本版**，
否则两个守护同时跑会互相打架。配置会自动从 `/data/adb/bypass_guard` 复制到
`/data/adb/MiBypassCharge`。

```bash
sh build.sh     # 生成 MiBypassCharge-v1.8.1.zip
```

KernelSU → 模块 → 从本地安装 → 选 zip → 重启。装完桌面会有「旁路供电」图标，
控制中心编辑里能找到「旁路充电」磁贴。

## 卸载与救急

KernelSU 里移除模块即可，`uninstall.sh` 走 `0x2 → 等 3 秒 → 0` 两步复位。

**若刷完发现手机不充电**（root 终端执行）：

```sh
echo 0x2 > /sys/class/qcom-battery/smart_chg
sleep 4
echo 0   > /sys/class/qcom-battery/smart_chg
```

仍不行就重启手机（sysfs 不落盘，重启必然复位）。

## 验证情况

**v1.8.1 没上真机**，只做了静态检查：

| 项目 | 结果 |
|---|---|
| `sh -n`（`module/bin/*.sh`、`service.sh`、`uninstall.sh`、`customize.sh`） | 10/10 通过 |
| `build.sh` 打包（含 CRLF 校验） | 18 文件、88337 字节、exit 0 |

本版两处改动的触发条件都不在普通路径上，要真机确认：

1. 强杀 `bg-daemon.sh` 让 `bg-supervise.sh` 重新拉起，把电量放在滞回区
   （恢复点 < 电量 < 停充点），应能正常充电，不再停在「界面显示未旁路、电流 0」
2. 反复插拔若干次后 `pgrep -f bg-watch.sh` 的实例数应恒定（`test.sh` 里算的是 2 个进程：
   1 主 + 1 管道子 shell）

下面这些结果来自 v1.8.0-fork.1（上一版；代码与本版只差上述 5 处）：

| 项目 | 结果 |
|---|---|
| 停充 / 恢复（看日志与电池电流） | 通过 |
| 磁贴点击、长按进 WebUI、状态同步 | 通过 |
| 阈值手动输入不被刷新覆盖 | 通过 |
| 版本号显示 `v1.8.0-fork.1 · Redmi K70 · SM8550` | 通过 |
| `docs/test.sh`（未插电跑） | 38 PASS / 0 FAIL / 4 SKIP |

4 个 SKIP 是需要插着电才能测的项（阈值裁决、重启后重新停充、关/开总开关后的
充电恢复）。插电补跑那一轮还没做，所以不写「全过」。

上游 v1.7.2 / v1.7.3 那些「42 项全过」是 HyperOS 2 时代的记录，属于上游历史，
只留在 `变更说明.md` 里，和本 fork 无关。

## 风险提示

修改系统充电行为，**可能导致设备无法充电**。请备份数据并自行承担风险。
与小米、KernelSU 及任何厂商无关。详见仓库 `DISCLAIMER.md`。

## 致谢

- 上游 [ChangXYZ-CPU/MiBypassCharge](https://github.com/ChangXYZ-CPU/MiBypassCharge)（GPL-3.0）
- [bypass-charger](https://github.com/QiZhi-yi/bypass-charger)（v10.3.5）：
  `flock` 串行化写充电节点、退出复位、`trap EXIT` 兜底

## 许可

GPL-3.0
