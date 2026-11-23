# 旁路供电守护（Redmi K70）

> ### 本 fork 的改动（基于上游 v1.8.0）
>
> 在上游「纯脚本 + WebUI」的基础上，补了一个**可选的控制中心磁贴 App**，并修掉了磁贴相关的几处硬伤：
>
> | 改动 | 说明 |
> | --- | --- |
> | 磁贴 App（`tile/`） | 一个极小的 TileService + WebUI 宿主，桌面图标和 QS 磁贴两个入口；不常驻、无常驻通知 |
> | 磁贴被冻结 → 点击没反应 | HyperOS 的 freezer 会把没绑定前台的磁贴进程冻成 `do_freezer_trap`，点击要么丢、要么拖几十秒才执行。现在由 root 侧 `bg-tile-keep.sh` 每 20 s 把 App 的 `oom_score_adj` 钉到 `-900` 并对已冻进程解冻；App 自己 `onCreate` 也会自钉一次；守护每 5 轮检查保活进程是否被杀，被杀就补起 |
> | 磁贴状态延迟 | 守护把 `state` 副本写到 App 私有目录（`/data/adb` 是 0700，App 读不到），磁贴读文件 0 ms 出状态，不再每次 fork 一个 `su` |
> | 「恢复充电」关不掉 | 上游 v1.7.2 的 `force_off → auto` 迁移被删掉：`force_off` 是正式状态，磁贴的「关」就是它，充满后才由守护交回 `auto` |
> | 并发点两下留下"停充位武装" | `smart_clear` 的两次写节点都加了重试，`flock` 抢锁失败不再静默 |
> | 插拔即时响应 | 界面上的开关取消，固定常开（`WATCH=1`）：uevent 阻塞读只占约 0.23% 单核，关掉反而会让「阈值自动 + 刚插上」最多等 60 s 才停充 |
>
> 构建：
> ```sh
> export ANDROID_JAR=$ANDROID_HOME/platforms/android-34/android.jar
> export D8_JAR=$ANDROID_HOME/build-tools/34.0.0/lib/d8.jar
> ./build-app.sh      # 出 APK 并塞进 module/webroot/
> sh build.sh         # 打模块 zip
> ```

KernelSU 模块：插上充电器后，电池充到设定电量就停止充电，手机由适配器直供（电池 0 W）。
停充走小米充电驱动的官方位 `smart_chg` —— 和安全中心「导航断充保护」同一条路，
状态由驱动保持，拔插不丢，不需要周期性重写。

- 机型：**仅基于 Redmi K70**（`23113RKC6C` / `vermeer` / SM8550）**本机测试**，其他机型未验证，见下方[可能的兼容设备](#可能的兼容设备未测试)
- 系统：HyperOS 2（实测 `2.0.205.0.VNKCNXM`，Android 15）
- Root：**仅 KernelSU**（WebUI 依赖 `window.ksu`，不支持 Magisk / APatch）
- 模块本身只有 root 脚本 + WebUI，**不安装任何 App**
- 注：本人制作模块初衷为自用，可能因学业原因维护修理不及时，欢迎提 Issue，但无法保证响应时效。目前仅考虑针对本机开发。

## 目录

```
module/                    模块本体（可直接打包成 zip 刷入）
  META-INF/                KernelSU 安装脚本入口
  module.prop              模块信息
  customize.sh             安装时权限设置
  service.sh               开机拉起看护与监听器
  uninstall.sh             卸载时两步复位 smart_chg，保证不会留下"永远不充电"
  bin/bg-lib.sh            公共函数：内建 read 读电池、flock 写节点、smart_chg 掩码
  bin/bg-daemon.sh         守护主循环：自适应轮询、阈值滞回、退出复位
  bin/bg-supervise.sh      看护循环：守护退出就重启，活着时零唤醒
  bin/bg-watch.sh          插拔监听：logcat 跟电池事件，插拔时即时叫醒守护
  bin/bg-ctl.sh            控制接口：status / on / auto / toggle / set / boot / stop / log / restart
  webroot/                 WebUI 单页（HTML 内联 JS，无外链，避免 WebView 缓存旧代码）

docs/
  变更说明.md              从 v1.1 到 v1.7.3 的改动、实测数据、踩过的坑（含各版本根因分析）
  调试速查.md              命令速查（只看电流，不看 status）
  RELEASE-NOTES.md         发布说明模板（当前 v1.7.3）
  test.sh                  全量回归脚本（42 项，跑完自动还原配置）
  probe-k70.sh             节点探针（默认只读；--test 会逐项写并还原，供新机型用）
  evidence/                初版分析与历史证据：官方 smart_chg 机制结论、自写 AXML 解码器、
                           v1.1 失败审核报告（已过期，仅留档）
  screenshots/             README 引用的界面截图

build.sh                   打包：读 module.prop 的版本号，生成 MiBypassCharge-v<版本>.zip
```

## 构建 / 安装

```bash
bash build.sh                       # 生成 MiBypassCharge-v<版本>.zip
# KernelSU → 模块 → 从本地安装 → 选 zip → 重启
```

## 使用

进 KSU 模块卡片点「打开」进入 WebUI：

| 控件 | 作用 |
|---|---|
| 旁路供电（总开关） | 关掉就完全不管，插上一直充 |
| 充到多少停（− 数字 +） | 停充电量，40–100%，点一次 ±5 或直接输入 |
| 插拔即时响应（开关） | 开=插拔立刻响应（多耗约 0.2%/天）；关=省电，等下次巡检 |
| 巡检间隔（− 数字 +） | 平时多久看一眼电量，5–120 秒，越小越灵敏越费电 |
| 恢复充电 / 立即旁路 | 临时手动切换 |
| 状态环 / 四个指标 | 电量、电池功率、电压、电池电流、温度 |

界面截图（点击可看大图）：从左到右为 WebUI 状态与控制、WebUI 省电设置与日志、
Scene 充电统计（旁路生效验证：到 90% 后功率曲线归零，系统由适配器供电，电池不再充放电）。

| WebUI 状态与控制 | WebUI 省电设置与日志 | Scene 验证 |
|---|---|---|
| ![WebUI 状态与控制](docs/screenshots/webui-main.jpg) | ![WebUI 省电设置与日志](docs/screenshots/webui-settings.jpg) | ![Scene 充电统计](docs/screenshots/scene-charge-stats.jpg) |

判据只看**电池电流**：充电为正、放电为负，`|I| < 120 mA` 才算停充成功。

**滞回**：≥ 停止阈值就停，≤ 恢复阈值（默认停充点 −5）才继续充，中间保持现状。
旁路下几乎不掉电，所以从 85 掉到 80 通常要几小时，不会来回切。

## 更新日志

### v1.8.0（2026-11-20）— 模块更名，需卸载重装

**⚠️ 模块 ID 从 `bypass_guard` 改为 `MiBypassCharge`。KernelSU 以 ID 识别模块，
旧版与本版会被视为两个独立模块，直接覆盖安装会导致两套守护同时运行。
升级必须先卸载旧模块 → 重启 → 安装新版 → 再重启。**
配置会自动迁移（`/data/adb/bypass_guard` → `/data/adb/MiBypassCharge`），阈值等设置不丢。

- **修好「关了开关还在后台占资源」**：`WATCH=0` 时若直接改配置再 boot，监听进程不会被
  清理，会持续唤醒耗电。现在 boot 按当前配置校正 watch 进程，`ENABLED=0` 分支改为彻底
  `stop_all`。实测关闭总开关后 daemon / supervise / watch 全部停止，残留进程 0 个。
- **修好关开关瞬间界面闪一帧**：配置回读存在"写入未落盘、读到旧值"的窗口，会在关停瞬间
  画出反向状态。新增用户意图值兜底，toast 改为等画面绘制完成后再弹。
- **数据目录随模块 ID 调整**，首次运行自动从旧目录迁移配置。
- **WebUI 顶部改为读取本机真实机型 / SoC**，不再硬编码 K70。
- 安装横幅去掉易错位的方框，版本号改为从 `module.prop` 动态读取；底部说明支持换行。
- 回归测试 42 项全过。

### v1.7.3（2026-11-18）

两个小修，基于 v1.7.2：

- **守护状态不再误报"未响应"**：开总开关后守护要几百 ms 才起来，旧版在这段窗口里
  直接显示橙色"未响应"。现在 12 秒宽限期内显示中性的"启动中…"。
- **自动自愈**：`ENABLED=1` 但连续约 9 秒查不到守护时，自动调 `bg-ctl boot` 补齐链路，
  20 秒内最多一次。以前 supervise 那一环断了要手动重启服务，现在不需要了。
- **去掉调整充电上限时的 toast**：数字框本身已即时更新，重复弹提示反而打断连续微调。

### v1.7.2（2026-11-18）— 热修复

四个真机反馈问题 + 一个排查中发现的隐藏 bug，全部修复并在 K70 实机验证（42 项回归全过）。

**1. 关掉总开关后彻底停进程，真正省电**
旧版 `ENABLED=0` 只是让守护低频空转，`daemon` / `supervise` / `watch` 三个进程一个没停。
现在关开关会按 `supervise → daemon → watch` 顺序全部终止（先停 supervise，否则它 3 秒后
把 daemon 拉活），零常驻、零唤醒；开机脚本也走同一入口，关闭态不启动任何进程。

**2. 去掉"手动充电"模式，修好回不到自动**
旧版点过手动后会写成 `MODE=force_off`，只有充满 100% 才回自动，实际卡死在手动两态。
手动充电本就等价于关掉总开关，没必要单列一个模式。现在按钮是**「立即旁路 ↔ 恢复自动」**
两态，切换只在 `force_on` 与 `auto` 之间；老配置里的 `force_off` 会自动迁移为 `auto`。

**3. 开关视觉真正跟手（修开关颜色不同步）**
现象：点开关后滑块滑到另一侧，但背景还是蓝色，要等几秒后 toast 弹出才变黑。
根因是两者走了不同的渲染管线——滑块位移 `transform` 在 GPU 合成层、不受阻塞；
背景 `background` 走主线程 paint，被 KernelSU 的同步 `exec` 冻结。现在背景改用
`.track::before` + `opacity` 过渡（同属合成层属性 + `will-change`），滑块与背景严格同步。

顺带把所有交互改成**乐观更新**：点下去先改视觉，命令异步跑，失败才回滚；校验完成后弹
系统 toast（`window.ksu.toast`）说明结果。

**4. 修"插拔即时响应"提示误闪**
刚打开该开关时监听器是异步启动的，旧逻辑在状态未刷新前就判成"启动失败"弹橙色警告、
几秒后又消失。现在加 8 秒启动宽限，期间显示中性的"启动中…"，确认超时仍未起来才提示失败；
总开关关闭时显示"已随总开关停止"、守护显示"已停止（省电）"而非"未响应"。

**5. 修插拔监听进程堆积（4 个实例）**
排查中发现 `bg-watch.sh` 会堆到 4 个实例，重复监听白费电。两处根因：① `logcat | while read`
fork 的子 shell 继承了 `EXIT` trap，退出时删掉了父进程仍持有的锁；② 启动函数主动删锁，
使去重失效。现在锁释放加 pid 校验、去重改为查进程表，反复开关/重复开机都稳定在 1 主 + 1 管道子。

详细根因分析与逐项测试结果见 [`docs/变更说明.md`](docs/变更说明.md) 的 §15–16 节。

### v1.7.1

修开关弹回、旁路中轮询没按间隔睡。详见 `docs/变更说明.md`。

## 耗电

读取全部用 shell 内建 `read`（不 fork），每轮成本约 50 ms。巡检间隔按场景自适应：

| 场景 | 间隔（默认巡检 60 秒时） | 单核占用 |
|---|---|---|
| 插电、离阈值 ≤3% | 6 s（间隔/10，最小 3 s） | ~0.8% |
| 已在旁路中 / 插电中段 | 60 s | ~0.08% |
| 没插电 / 功能关闭 | 120 s | ~0.04% |

插拔监听（可关）另占约 0.233% 单核。关掉它 + 把巡检调到 120 秒，
就是本模块最省电的配置。详见 `docs/变更说明.md` §10–§14 的实测数据。

## 测试情况

模块在真机（K70 / HyperOS 2.0.205）上做过完整验证，脚本是 `docs/test.sh`（42 项），跑完会自动还原配置：

| 类别 | 覆盖内容 | 结果 |
|---|---|---|
| 功能回归 v1.7.2（42 项） | 进程自愈、监听开关与不堆积、巡检间隔、四个阈值方向、总开关彻底停进程、toggle 两态、老配置迁移、WebUI 元素与修复点 | **42 PASS / 0 FAIL** |
| 手动触摸 | 两个开关、巡检 ±、阈值 +、立即旁路/恢复自动，逐项真机点击 | 通过 |
| 开关视觉同步 | 滑块与背景色同时变化（改 `opacity` 合成层后），录屏逐帧确认 | 通过 |
| 真实开机 | 重启后自启 1 supervise + 1 daemon + 2 watch，配置保留、旁路自动恢复 | 通过 |
| 拔插 | 拔电清位、插回即时停充（事件唤醒），多次循环 | 通过 |
| 省电实测 | 内建 `read` 单轮约 50 ms；旁路中设 120 秒时 2 分半零日志；关总开关后进程数归零 | 通过 |

判据统一看**电池电流**（充电为正、放电为负），不看滞后的 `status`。
其中"开开关后 20 秒内没停"那次 FAIL 是测试判据撞上 PD 协商假电流，改成连续两次采样后全绿，非功能问题。

> 以上只覆盖 K70 / HyperOS 2。其他设备没有测试条件，见下方"可能的兼容设备"。

## 可能的兼容设备（未测试）

`smart_chg` 是小米/红米部分机型存在的充电保护位，K70 外的机型可能也有同样的接口，**但是不一定可以稳定使用**。满足以下条件的设备**理论上可能可用，尝试可能存在风险**：

- KernelSU v3.x（WebUI 依赖 `window.ksu`）
- 高通平台，`/sys/class/qcom-battery/smart_chg` 节点存在且可写
- `getprop persist.vendor.smartchg` 的值含 `bit1`（支持导航断充）
- HyperOS / MIUI 且系统里确实有「导航断充保护」功能

**已在其他机型上跑通的案例，以及对应的 HyperOS 版本，见
[酷安评论区](https://www.coolapk.com/feed/75130364?s=YWVlNGFmNTYyMjg3NTUwZzZhZmZkYzAwega1673)。**
这些是用户自行测试的结果，不是作者验证的，仅供参考。

自检（root 终端）：

```sh
ls -l /sys/class/qcom-battery/smart_chg
getprop persist.vendor.smartchg        # 含 bit1 即支持
```

> **重要：作者本人只有一台 K70，没有其他任何设备可以测试。**
> 上述"可能兼容"只是基于接口存在性的推断，**不代表已验证，更不能保障安全**。
> 在其他机型上使用属于你自己的测试行为，请先读 `DISCLAIMER.md`，
> 并确认你会执行救急命令或恢复出厂设置。

## 注意

- **更新 WebUI 后界面没变化**：KernelSU 的 WebView 有缓存。光退出重进不够，
  需要 `am force-stop me.weishu.kernelsu` 并删掉
  `/data/data/me.weishu.kernelsu/app_webview` 再进。
- **卸载**：KernelSU 里移除模块即可，`uninstall.sh` 会走 `0x2 → 等 3 秒 → 0` 两步复位。
  手动救急：
  ```bash
  echo 0x2 > /sys/class/qcom-battery/smart_chg; sleep 4
  echo 0   > /sys/class/qcom-battery/smart_chg
  ```
- 用 KernelSU「禁用」而不是「卸载」时，`uninstall.sh` 不会执行；驱动状态保持到重启。
- 只验证过 K70 / HyperOS 2。其他机型先用 `docs/probe-k70.sh`（只读模式）确认 `smart_chg`
  存在且 `persist.vendor.smartchg` 含 `bit1`。

## 免责声明

见 [DISCLAIMER.md](DISCLAIMER.md)。简要说：本项目修改系统充电行为，**可能导致设备无法充电或系统故障**，
请自行承担风险并保留救急手段；与小米、KernelSU 及任何厂商无关。

## 致谢

部分工程实践参考了开源项目 [bypass-charger](https://github.com/QiZhi-yi/bypass-charger)
（v10.3.5），具体包括：用 `flock` 串行化写充电节点（它记录过并发写导致厂商充电驱动死锁的事故）、
KernelSU 禁用状态检测、退出时复位充电、`trap EXIT` 兜底。停充通道使用小米系统自带的
`smart_chg` 官方停充位，掩码语义见 `docs/变更说明.md` §10.1。

## 许可

GPL-3.0，见 [LICENSE](LICENSE)。
