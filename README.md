# MiBypassCharge · 旁路供电（Redmi K70）

KernelSU 模块：插上充电器后，电池充到「充到多少停」就停止充电，手机改由适配器直供
（电池 0 W）；掉到「用到多少才充」再恢复充电。停充走小米充电驱动的 `smart_chg` 位，
和安全中心「导航断充保护」同一条路，状态由驱动保持，拔插不丢。

这是 [ChangXYZ-CPU/MiBypassCharge](https://github.com/ChangXYZ-CPU/MiBypassCharge)
上游 v1.8.0 的 fork，只在自己这台 K70 上用。

## 实际情况

| 项目 | 值 |
|---|---|
| 仓库 | <https://github.com/Hayato-Aying/MiBypassCharge> |
| 版本 | `v1.8.2`（versionCode 10820，基于上游 v1.8.0） |
| 机型 | Redmi K70（`23113RKC6C` / `vermeer` / SM8550） |
| 系统 | `OS4.0.3.0.XNKCNXM`，Android 17，内核 5.15.194 |
| Root | 仅 KernelSU（WebUI 依赖 `window.ksu`，不支持 Magisk / APatch） |
| 组成 | root 脚本 + WebUI，外加一个可选的控制中心磁贴 App（约 45 KB，刷入时自动装） |
| 测试范围 | 只有这一台机器。其他机型、其他 ROM 版本都没跑过 |

## 这个 fork 和上游的差别

| 改动 | 说明 |
|---|---|
| 附带磁贴 App（`tile/`） | 一个极小的 App：`MainActivity` 就是 WebUI 的宿主（桌面图标、磁贴长按都进它），`TileService` 是控制中心磁贴。无常驻通知，不占后台 |
| 磁贴被冻住 → 点了没反应 | HyperOS 的 freezer 会把没绑前台的磁贴进程冻成 `do_freezer_trap`。root 侧 `bg-tile-keep.sh` 每 20 s 把 App 的 `oom_score_adj` 钉到 `-900` 并解冻已冻进程；守护每 5 轮检查它是否被杀，被杀就补起 |
| 磁贴状态延迟 | 守护把状态副本写进 App 私有目录（`/data/adb` 是 0700，App 读不到），磁贴读文件 0 ms 出状态，不再每次 fork `su` |
| 「恢复充电」关不掉 | 上游 v1.7.2 那条 `force_off → auto` 的迁移删掉了：`force_off` 是正式状态（磁贴的「关」就是它），充满后才由守护交回 `auto` |
| 并发点两下留下「停充位武装」 | `smart_clear` 两次写节点都加了重试，`flock` 抢不到锁不再静默 |
| 插拔即时响应 | 界面上的开关取消，固定常开（`WATCH=1`）：每 2 秒读一次 `power_supply/*/online`，变化就叫醒守护；关掉反而让「按阈值自动 + 刚插上」最多等一个巡检周期才停充 |
| 阈值输入被刷新覆盖 | 3 秒状态刷新会把正在输入的「用到多少才充」改回旧值；现在输入框有焦点时跳过回写 |

## 目录

```
module/
  module.prop              模块信息（版本号唯一来源）
  customize.sh             安装：设权限、尝试装磁贴 App
  service.sh               开机拉起守护；补装磁贴 App
  uninstall.sh             卸载时两步复位 smart_chg
  bin/bg-lib.sh            公共函数：内建 read 读电池、flock 写节点、smart_chg 掩码
  bin/bg-daemon.sh         守护主循环：自适应轮询、阈值滞回、退出复位
  bin/bg-supervise.sh      看护：守护退出就重启，活着时零唤醒
  bin/bg-watch.sh          插拔监听：轮询 power_supply/*/online，插拔时叫醒守护
  bin/bg-tile-keep.sh      磁贴保活：钉 oom_score_adj、解冻、补起被杀进程
  bin/bg-tile-install.sh   装 / 更新磁贴 APK（被拦就留到 /sdcard/Download）
  bin/bg-ctl.sh            控制接口：status get set boot on auto stop flip toggle log restart hide
  webroot/index.html       WebUI（单页，JS 内联，避免 WebView 缓存旧代码）
  webroot/style.css
  webroot/MiBypassChargeTile.apk   磁贴 App（打包时带上）
  USAGE.txt                刷入后模块目录里的简短说明

tile/                      磁贴 App 源码（Java；不依赖 Gradle 也能编）
build.sh                   打包模块 zip，读 module.prop 的版本号
build-app.sh               编译磁贴 APK 并塞进 module/webroot/

docs/调试速查.md            命令速查（只看电流，不看 status）
docs/test.sh               真机回归脚本，跑完自动还原配置
docs/RELEASE-NOTES.md       本版发布说明
docs/变更说明.md            上游 v1.2 → v1.7.3 的历史改动与踩坑（历史档，路径仍是旧的 bypass_guard）
docs/probe-k70.sh           节点探针（默认只读）
docs/evidence/              初版分析留档（已过期）
docs/screenshots/           早期版本（v1.7.x）截图，和现在的界面不完全一致
```

## 安装

```bash
sh build.sh        # 生成 MiBypassCharge-v1.8.2.zip
```

KernelSU → 模块 → 从本地安装 → 选 zip → 重启。刷入时 `customize.sh` 会顺手装磁贴 App；
被 HyperOS 拦下的话 APK 会留在 `/sdcard/Download/`，手动点一次，或等开机后自动重试。

重新编磁贴 APK（仓库里已带成品，一般不用）：

```sh
export ANDROID_JAR=$ANDROID_HOME/platforms/android-34/android.jar
export D8_JAR=$ANDROID_HOME/build-tools/34.0.0/lib/d8.jar
./build-app.sh     # 需要自备 keystore，见脚本头部
```

## 使用

桌面「旁路供电」图标，或 KernelSU 模块卡片「打开」，进入 WebUI。

| 控件 | 作用 |
|---|---|
| 旁路供电（总开关） | 关掉就完全不管，插上一直充 |
| 充到多少停 | 40–100%，点 ±5 或直接输入 |
| 用到多少才充 | 5 …（停充点 − 5），点 ±5 或直接输入 |
| 巡检间隔 | 5–120 秒，默认 30 |
| 立即旁充 / 按阈值自动 | 手动旁充，或交回阈值自动 |
| 控制中心磁贴 | 装 / 打开磁贴 App；磁贴主行只写「旁路充电」，状态看高亮色和副标题 |
| 运行日志 | 最近日志 |

判据只看**电池电流**：充电为正、放电为负，`|I| < 120 mA` 才算停充成功。

**滞回**：≥ 停充点就停，≤ 恢复点才继续充，中间保持现状。旁路下几乎不掉电，
从 85 掉到 80 通常要几小时，不会来回切。

命令行（`M=/data/adb/modules/MiBypassCharge`）：

```sh
sh $M/bin/bg-ctl.sh status          # 实时状态
sh $M/bin/bg-ctl.sh flip on         # 立即旁充（force_on）
sh $M/bin/bg-ctl.sh flip off        # 真·正常充电（force_off）
sh $M/bin/bg-ctl.sh flip cancel     # 取消手动：没到阈值还回 auto，到阈值就是 force_off
sh $M/bin/bg-ctl.sh auto            # 交回阈值自动
sh $M/bin/bg-ctl.sh set THRESHOLD_ON 80
```

## 耗电

读取全部用 shell 内建 `read`（不 fork），一轮约 50 ms。守护间隔按场景自适应
（`CHECK_INTERVAL` 默认 30 秒）：

| 场景 | 间隔 | 单核占用 |
|---|---|---|
| 插电、离阈值 ≤3%（或开机头 30 轮） | 3 s（间隔/10，最小 3 s） | ~0.8% |
| 已在旁路中 / 插电中段 | 30 s | ~0.08% |
| 没插电 / 功能关闭 | 30 s | ~0.08% |

插拔监听固定常开：每 2 秒读 4 个 `power_supply/*/online`（shell 内建 read，不 fork），
开销远低于原来常驻的 `logcat`（0.23% 单核）。

## 测试情况

只在这台 K70（`OS4.0.3.0.XNKCNXM` / Android 17）上验证：

| 项目 | 结果 |
|---|---|
| 停充 / 恢复（68–70% 实测，看日志与电池电流） | 通过 |
| 磁贴点击、长按进 WebUI、状态同步 | 通过 |
| 阈值手动输入（输入时不被 3 秒刷新覆盖） | 通过 |
| 版本号显示 `v1.8.0-fork.1 · Redmi K70 · SM8550` | 通过 |
| `docs/test.sh` 回归脚本 | 见下方结果 |

`docs/test.sh` 在本机跑过一轮（未插电）：**38 PASS / 0 FAIL / 4 SKIP**。
4 个 SKIP 都是「需要插着电才谈得上停充/恢复」的项（阈值裁决、重启后重新停充、
关/开总开关后的充电恢复），没插电时脚本直接打 SKIP，不算失败。
插电后再跑一遍能补齐，但那一轮我还没跑，所以不写成「全过」。

zip 里只有 `module/` 下的东西，`docs/` 不随模块发布；跑之前先
`adb push docs/test.sh /data/local/tmp/`，再在手机上 `sh /data/local/tmp/test.sh`。

上游 v1.7.2 那轮「42 项全过」是 HyperOS 2 时代的记录，只作历史，见 `docs/变更说明.md`。

## 其他机型（没测过）

`smart_chg` 是小米 / 红米部分机型才有的充电保护位，别的机型可能也有同样的接口，
**但不一定能稳定用**。满足下面几条**理论上可能可用，尝试有风险**：

- KernelSU v3.x（WebUI 依赖 `window.ksu`）
- 高通平台，`/sys/class/qcom-battery/smart_chg` 存在且可写
- `getprop persist.vendor.smartchg` 含 `bit1`
- HyperOS / MIUI，且系统里确实有「导航断充保护」

自检（root 终端）：

```sh
ls -l /sys/class/qcom-battery/smart_chg
getprop persist.vendor.smartchg        # 含 bit1 即支持
```

上游作者在酷安帖子里收集过其他机型的反馈（<https://www.coolapk.com/feed/75130364>），
那些是用户自测，不是我验证的。

> **我只有这一台 K70，没有别的设备可测。**
> 上面「可能兼容」只是按接口存在性推的，不代表验证过，更不保证安全。
> 换机型用属于你自己的测试行为，先读 `DISCLAIMER.md`，确认你会执行救急命令。

## 注意

- **改了 WebUI 但界面没变**：KernelSU 的 WebView 有缓存。光退出重进不够，要
  `am force-stop me.weishu.kernelsu` 并删掉 `/data/data/me.weishu.kernelsu/app_webview` 再进。
- **卸载**：KernelSU 里移除模块即可，`uninstall.sh` 会走 `0x2 → 等 3 秒 → 0` 两步复位。
  手动救急：
  ```bash
  echo 0x2 > /sys/class/qcom-battery/smart_chg; sleep 4
  echo 0   > /sys/class/qcom-battery/smart_chg
  ```
- 用 KernelSU「禁用」而不是「卸载」时，`uninstall.sh` 不会执行；驱动状态保持到重启。
- 换机型先用 `docs/probe-k70.sh`（只读模式）确认节点和 `bit1`。

## 免责声明

见 [DISCLAIMER.md](DISCLAIMER.md)。简单说：本项目改系统充电行为，**可能导致设备无法充电**，
风险自负，先确认自己会救急。

## 致谢

部分工程实践参考了 [bypass-charger](https://github.com/QiZhi-yi/bypass-charger)（v10.3.5）：
用 `flock` 串行化写充电节点、退出时复位充电、`trap EXIT` 兜底。
停充通道用小米自带的 `smart_chg` 官方位，掩码语义见 `docs/变更说明.md` §10.1。

## 许可

GPL-3.0，见 [LICENSE](LICENSE)。
