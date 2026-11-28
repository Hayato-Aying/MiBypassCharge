#!/system/bin/sh
# bg-daemon.sh — 守护主循环
#
# 执行层是 smart_chg 掩码（驱动级停充），不是 input_suspend。
# 驱动自己保持状态，所以稳态不重写；只有连续几十秒"明显在充电"才补写一次。
#
# 省电（v1.5+）：轮询间隔按场景自适应，不再死守 3 秒
#   旁路中 / 快到阈值 → POLL（3s）   要精确停充、要发现拔线
#   插着电、离阈值还远 → POLL×5（15s） 电量涨得慢
#   没插电           → POLL（30s）   这时什么都做不了，只需发现"插上了"
#                                      （以前是 POLL×2，配合 watch 轮询后改回 POLL）
#
# 唤醒（v1.5+）：WebUI 改配置会发 SIGUSR1，nap 立刻被打断重新裁决，
# 不用等睡满一个周期。
#
# 教训（v1.6.1）：停充位 smart_chg 是"粘"的，拔电也不清。曾试过拔电时把它
# 保留成"充到阈值停"，结果关掉开关后没人去松开它，手机在 79% 一直不充电。
# 现在：拔电照旧清 0；功能关闭 / force_off 每轮都确认它是松开的。

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
. "$MODDIR/bin/bg-lib.sh"

# 版本号从 module.prop 读，不再硬编码（以前写死 v1.7.2 导致升级后日志显示旧版本）
MODVER=$(awk -F= '/^version=/{print $2}' "$MODDIR/module.prop" 2>/dev/null | tr -d '\r')
[ -n "$MODVER" ] || MODVER=unknown

load_conf
find_bat
batt_info

BP=$(read_bp)
TICK=0
STRIKES=0
BACKOFF=0
LAST_STATUS=""
# 初始化为"当前阈值"，这样启动后的第一轮不会误触发重裁决。
# 重裁决只应该由"用户改了阈值"触发；否则启动时电量刚好在阈值下一格（79/80），
# 会被判成"该充电"，和驱动的补电行为打架，变成 79↔80 反复横跳。
LAST_EN=$THRESHOLD_ON
LAST_DI=$THRESHOLD_OFF
LAST_SMART=""
LAST_IDLE=""
# 通知用：记上一轮的「在充电 / 已充满 / 插着电」。
# 空串 = 还没测过，首轮只初始化不弹（否则每次开机都先弹一条假状态）。
LAST_CHG=""
LAST_FULL=""
LAST_ONCH=""
# 自动阈值模式下的区间：high=电量已超停充阈值，mid=落在恢复点~停充点之间。
# 只在区间发生变化时提醒，否则每轮都弹一条会把通知栏刷成滚动条。
LAST_ZONE=""
BOOT_TICKS=0
SLEEP_PID=""

# 连续多少个 tick 都在"明显充电"才认为驱动状态真丢了。
# 80% 附近掉一格再补电是驱动的正常行为，不能一充就补写。
# 注意按"间隔"算：旁路中现在是 30 秒一轮，30 tick 就是 15 分钟（太久了）。
REASSERT_TICKS=${REASSERT_TICKS:-2}

VERIFY_ON_TRIES=${VERIFY_ON_TRIES:-8}      # 8×2s = 16s 等它停
VERIFY_OFF_TRIES=${VERIFY_OFF_TRIES:-12}   # 12×2s = 24s 等它重新充

echo $$ > "$DATA_DIR/daemon.pid"

# 退出必须做的事：驱动状态是"粘"的，守护走了还压着 smart_chg，
# 手机就会一直不充电（比功能失效严重得多）。
# 同时提醒：INT/TERM 要显式 exit，否则 trap 跑完循环还在继续。
on_exit() {
  _rc=$?
  if [ -n "$SLEEP_PID" ]; then kill "$SLEEP_PID" 2>/dev/null; fi
  if [ "$BP" = "1" ]; then
    logi "=== daemon exit pid=$$ rc=$_rc → 复位 smart_chg ==="
    smart_clear
    write_bp 0
  else
    logi "=== daemon exit pid=$$ rc=$_rc ==="
  fi
}
trap on_exit EXIT
trap 'exit 0' INT TERM

# 可被打断的等待：WebUI 改完配置会发 SIGUSR1。
# 注意它只是"锦上添花"——mksh 在 wait 子进程时用 sigsuspend，信号会被屏蔽，
# 所以改配置能不能立刻生效，真正靠的是 bg-ctl.sh 在 set 之后自己校正一次。
trap 'if [ -n "$SLEEP_PID" ]; then kill "$SLEEP_PID" 2>/dev/null; fi' USR1

nap() {
  sleep "${1:-$IV}" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
}

logi "=== daemon start $MODVER pid=$$ backend=$BACKEND mode=$MODE thr=$THRESHOLD_ON/$THRESHOLD_OFF poll=$POLL ==="

# 启动时无条件重置 BP，让主循环按当前电量重新裁决：
# bp_on 只是我们自己的记账，而 smart_chg 是驱动级状态，进程退出时被 on_exit 清掉后，
# 重启读到的 bp_on=1 就是"假旁路" —— 界面说旁路中，实际 smart_chg=0 在快充。
# 重启多写一次 smart_chg 没有副作用，比漏停充强得多。
#
# 但反向的情况才是致命的：上一任守护被 SIGKILL / LMK 杀掉时 on_exit 根本没跑，
# 驱动里的停充位还武装着、bp_on 也是 1。这时只清记账不清驱动，就留下
# "驱动在停充、界面说没旁路"的僵尸态；而电量一旦落在滞回区
# （THRESHOLD_OFF < 电量 < THRESHOLD_ON），WANT 取 BP=0，do_on/do_off 两支都不进，
# 手机就一直不充电。所以 bp_on=1 时先松一次驱动再重置记账。
if [ "$BP" = "1" ]; then
  logi "startup: 残留 bp_on=1（上个守护可能被强杀）→ 先复位 smart_chg"
  smart_clear
fi
BP=0; write_bp 0

# 注意：这里不要在复位 BP 之后马上写磁贴副本。
# 复位只是记账（bp_on 是上辈子留下的假旁路），此刻的真实结论还没算出来，
# 抢先写就会给磁贴画出一帧 "MODE=force_on 但 BP=0" 的假状态。
# 副本交给主循环：每轮执行完都刷（见下面的 BOOT_TICKS 判断）。

push_ui "旁路供电守护已启动"

wait_stopped() {
  i=0
  while [ "$i" -lt "$1" ]; do
    sleep 2
    batt_info
    is_stopped && return 0
    i=$((i + 1))
  done
  return 1
}

wait_charging() {
  i=0
  while [ "$i" -lt "$1" ]; do
    sleep 2
    batt_info
    is_charging && return 0
    i=$((i + 1))
  done
  return 1
}

do_on() {
  batt_info
  # 没插电就别试了：写进去也停不了（本来就没在充），wait_stopped 必然等满 16 秒，
  # 日志里刷一堆 "smart_set no effect" 把真正的失败淹掉。直接返回 0 = 本轮跳过，
  # WANT 仍是 1，插上电后下一轮自然就做。
  if ! on_charger; then
    return 0
  fi
  lvl=$(smart_target_level)
  if smart_set "$lvl" && wait_stopped "$VERIFY_ON_TRIES"; then
    BP=1; write_bp 1
    logi "BP ON smartchg level=$lvl now=$LEVEL cur=$CUR"
    # 文案看触发原因，不看目标电量：
    #   电量已超停充阈值（插电时就在阈值之上 / 补电过头）→「正在旁路充电」
    #   正好涨到阈值那一格（一路从下往上充）→「已开启旁路电量 X%」
    # lvl 是 smart_target_level 算出的目标值，不是真实电量，别拿它当文案。
    if [ "$LEVEL" -gt "$THRESHOLD_ON" ] 2>/dev/null; then
      push_ui "正在旁路充电"
    else
      push_ui "已开启旁路电量 ${lvl}%"
    fi
    return 0
  fi
  logi "smart_set no effect (cur=$CUR status=$STATUS)"
  # 只有"本机根本没有 smart_chg"时才退到 input_suspend。
  # 有 smart_chg 但这次没停住，说明是阈值没到/驱动还在协商，绝不能用断充兜底
  # （断充会让手机转吃电池，UI 上就是"未插电、0W"，v1.2 初版踩过这个坑）。
  _sus_ok=0
  if suspend_present && [ "$FALLBACK" = "1" ] && ! smart_present; then
    _sus_ok=1
  fi
  if [ "$_sus_ok" = "1" ]; then
    suspend_on
    if wait_stopped "$VERIFY_ON_TRIES"; then
      BACKEND=input_suspend
      save_conf
      BP=1; write_bp 1
      push_ui "已断充（兜底，非旁路）· 电量 ${LEVEL}%"
      return 0
    fi
    suspend_off
  fi
  return 1
}

do_off() {
  # 手动旁路在低电量时用过断充兑底，退出时无条件释放，
  # 残留会让「插着电却当没插电」，只能重启（v1.2 踩过）。
  suspend_off
  case "$BACKEND" in
    input_suspend)
      # 走 write_node 而不是裸重定向：所有节点写必须 flock 串行化（见 bg-lib.sh 的事故记录）
      write_node "$INPUT_SUSPEND" 0
      BACKEND=smartchg; save_conf
      ;;
    *)
      smart_clear
      ;;
  esac

  BP=0; write_bp 0

  # 拔了电就别等它"充上"了（拔着电永远等不到，会白等 20 多秒）
  # 拔电不弹通知（用户明确要求）：只记日志。
  if ! on_charger; then
    logi "BP OFF (unplugged) level=$LEVEL"
    return 0
  fi

  if wait_charging "$VERIFY_OFF_TRIES"; then
    logi "BP OFF level=$LEVEL cur=$CUR (charging resumed)"
    push_ui "已恢复充电"
  else
    logi "BP OFF but not charging yet (cur=$CUR status=$STATUS) → 再补一次"
    smart_clear
    sleep 4
    batt_info
    push_ui "已恢复充电"
  fi
  return 0
}

# 下一次睡多久。核心思路：smart_chg 是驱动级的「充到 X 停」，
# 插上电后驱动自己就按它执行，守护不需要守着 —— 所以空闲时可以把间隔拉得很长。
# 直接算进 IV，不要用 $(next_interval) —— 命令替换每轮 fork 一次，26ms 白花
next_interval() {
  # CHECK_INTERVAL = 平时巡检秒数（界面直接填），5~120
  _p=$CHECK_INTERVAL
  [ "$_p" -ge 5 ] 2>/dev/null || _p=30
  [ "$_p" -gt 120 ] && _p=120
  # 快档：临界/开机，最小 3 秒（保证精确停在阈值上）
  _fast=$(( _p / 10 ))
  [ "$_fast" -lt 3 ] && _fast=3
  # 开机后头 30 轮用快节奏（约 90 秒）：PD 还没协商完，容易误判"没插电"
  if [ "$BOOT_TICKS" -le 30 ]; then IV=$_fast; return; fi
  # 没插电 / 功能关：按巡检周期睡（不再 ×2）
  # 以前没插电睡 60s，指望 watch 在插拔时把 nap 打断；但这台机 events buffer
  # 是空的，watch 拿不到 battery_status 事件，60s 就成了「插上电最多等 60s 才反应」。
  # 现在 watch 退化成 2s 轮询 usb/online，正常情况 2-3s 内就叫醒；
  # 这里仍按 _p（30s）兜底，万一 watch 死了最坏也只慢 30s。
  if [ "$ENABLED" != "1" ] || [ "$ONCH" != "1" ]; then
    if [ "$MODE" = "force_on" ]; then IV=$_fast; else IV=$_p; fi
    return
  fi
  if [ "$MODE" != "force_on" ]; then
    _d=$(( THRESHOLD_ON - LEVEL ))
    # 只有"还没到但快到了"才用快档。旁路中 _d<=0，必须走慢档，
    # 否则 CHECK_INTERVAL=120 时旁路中仍每 12 秒醒一次，白费电。
    if [ "$_d" -ge 0 ] 2>/dev/null && [ "$_d" -le 3 ] 2>/dev/null; then
      IV=$_fast; return
    fi
  fi
  IV=$_p                                                       # 旁路中/插电中段
}

while true; do
  # KernelSU 里"禁用"模块不会跑 uninstall.sh，只能靠这里自己退出并放开充电
  if [ -f "$MODDIR/disable" ]; then
    logi "检测到 disable 标记 → 恢复充电并退出"
    if [ "$BP" = "1" ]; then smart_clear; write_bp 0; BP=0; fi
    break
  fi

  load_conf
  find_bat
  batt_info

  ONCH=0
  on_charger && ONCH=1

    # 恢复值必须明显低于开启值
  if [ "$THRESHOLD_OFF" -ge "$THRESHOLD_ON" ] 2>/dev/null; then
    THRESHOLD_OFF=$((THRESHOLD_ON - 5))
  fi

  # ---- 通知：只在跳变上发一条，其余轮次闭嘴 ----
  # push_ui 在 do_on / do_off 里已经覆盖了「开旁路」「恢复充电」，
  # 主循环这里补的是光靠那两处发不出来的：
  #   ①一直充到 100%（全程没有状态翻转）
  #   ②旁路中拔了又插（BP 一直是 1，不经过 on/off 翻转）
  #   ③按阈值自动时电量落在两阈值之间 / 已经冲过头
  # 「正常开始充电」不通知（用户明确要求）。_chg 只用来把 LAST_CHG 从空串
  # 变成非空 —— 它是「首轮只初始化不弹」的门闩，别拿它当通知条件。
  _chg=0; is_charging && _chg=1
  _full=0
  case "$STATUS" in Full*) _full=1 ;; esac
  [ "$LEVEL" -ge 100 ] 2>/dev/null && _full=1

  # 区间只看自动阈值模式：high = 已超停充阈值（> ON），
  # mid = 落在恢复点~停充点之间（OFF <= 电量 < ON）。
  # 电量正好等于 ON 那一刻归 do_on 的「已开启旁路电量 X%」管，这里不重复报。
  _zone=""
  if [ "$ENABLED" = "1" ] && [ "$ONCH" = "1" ]; then
    case "$MODE" in
      force_on|force_off) ;;
      *)
        if [ "$LEVEL" -gt "$THRESHOLD_ON" ] 2>/dev/null; then
          _zone="high"
        elif [ "$LEVEL" -ge "$THRESHOLD_OFF" ] 2>/dev/null && [ "$LEVEL" -lt "$THRESHOLD_ON" ] 2>/dev/null; then
          _zone="mid"
        fi
        ;;
    esac
  fi

  if [ "$NOTIFY" = "1" ] && [ -n "$LAST_CHG" ]; then
    if [ "$_full" = "1" ] && [ "$LAST_FULL" != "1" ] && [ "$ONCH" = "1" ]; then
      push_ui "已充满"
    elif [ "$ONCH" = "1" ] && [ "$LAST_ONCH" = "0" ] && [ "$BP" = "1" ]; then
      push_ui "正在旁路充电"
    elif [ "$_zone" != "$LAST_ZONE" ]; then
      case "$_zone" in
        high) push_ui "正在旁路充电" ;;
        mid)  push_ui "阈值充电" ;;
      esac
    fi
  fi
  LAST_ONCH=$ONCH
  LAST_CHG=$_chg
  LAST_FULL=$_full
  LAST_ZONE=$_zone

  # 功能关闭 / 强制充电：必须保证停充位是松开的。
  # 踩过的坑：拔电时把 smart_chg 留成「充到 80 停」，插上电后又关掉开关，
  # 结果没有任何地方去清它 —— 手机一直不充电（79% 卡了半天）。
  if [ "$ENABLED" != "1" ] || [ "$MODE" = "force_off" ]; then
    suspend_off
    if [ "$LAST_SMART" != "off" ]; then
      smart_clear
      LAST_SMART="off"
      logi "停充位已松开（ENABLED=$ENABLED MODE=$MODE）"
    fi
  fi

  # force_off 是终态，别再"贴心"地充满后偷偷改回 auto。
  # 以前这里 LEVEL>=100 就 set_key MODE auto，结果用户点「恢复正常充电」
  # （语义 = 立即旁充和按阈值自动都没开）之后，手机一充满，
  # 按钮就自己亮回「按阈值自动」，而且 100>=停止阈值会立刻再次停充 ——
  # 用户看到的就是"我没碰它，它自己又开回去了"。要开阈值自动只能由用户点。

  # ---- 决策 ----
  if [ "$ENABLED" != "1" ]; then
    WANT=0
  else
    case "$MODE" in
      force_on)
        WANT=1
        ;;
      force_off)
        WANT=0
        ;;
      *)
        if [ "$ONCH" != "1" ]; then
          WANT=0
        elif [ "$THRESHOLD_ON" != "$LAST_EN" ] || [ "$THRESHOLD_OFF" != "$LAST_DI" ]; then
          # 阈值刚被改过 / 刚启动 / 刚插电：按当前电量直接裁决，不走滞回区。
          # 否则把停止阈值调到当前电量之上后，会一直卡在死区里不动。
          if [ "$LEVEL" -ge "$THRESHOLD_ON" ] 2>/dev/null; then WANT=1; else WANT=0; fi
        elif [ "$LEVEL" -ge "$THRESHOLD_ON" ] 2>/dev/null; then
          WANT=1
        elif [ "$LEVEL" -le "$THRESHOLD_OFF" ] 2>/dev/null; then
          WANT=0
        else
          WANT=$BP          # 滞回区：维持现状
        fi
        ;;
    esac
  fi
  LAST_EN=$THRESHOLD_ON
  LAST_DI=$THRESHOLD_OFF

  # 没插电就没必要维持旁路
  if [ "$ONCH" != "1" ] && [ "$MODE" != "force_on" ]; then
    WANT=0
  fi

  TICK=$((TICK + 1))
  BOOT_TICKS=$((BOOT_TICKS + 1))

  # ---- 执行 ----
  if [ "$WANT" = "1" ] && [ "$BP" != "1" ]; then
    if [ "$BACKOFF" -gt 0 ]; then
      BACKOFF=$((BACKOFF - 1))
    elif ! do_on; then
      BACKOFF=6
      logi "do_on failed, backoff 6 ticks"
    fi
  elif [ "$WANT" = "0" ] && [ "$BP" = "1" ]; then
    do_off
  elif [ "$WANT" = "1" ] && [ "$BP" = "1" ]; then
    if is_charging; then
      STRIKES=$((STRIKES + 1))
      if [ "$STRIKES" -ge "$REASSERT_TICKS" ]; then
        logi "reassert: charging $STRIKES ticks (cur=$CUR level=$LEVEL) → rewrite"
        do_on >/dev/null 2>&1
        STRIKES=0
      fi
    else
      STRIKES=0
    fi
  fi

  # 状态变化时记一笔
  if [ "$LAST_STATUS" != "$STATUS" ]; then
    LAST_STATUS=$STATUS
    logi "status -> $STATUS level=$LEVEL cur=$CUR"
  fi

  save_state
  # 磁贴状态副本：开机/重启后头 20 轮每轮都刷，之后每 10 轮一次。
  # 为什么必须每轮：磁贴 App 很可能是 service.sh 在守护起来之后才补装的，
  # 装上的那一刻它的 files 目录才存在，之前所有 write_tile_state 都被
  # "[ -d ] || continue" 静默跳过 —— 于是"没打开过 App 的开机首刷"里磁贴永远读不到副本。
  # 以前只靠"签名变化 + 每 10 轮"，闲置时 10 轮 = 好几分钟，用户等的就是这段时间。
  # 之后降到每 10 轮，只为让"这数据是不是陈货"可判断，不必一直频繁写盘。
  if [ "$BOOT_TICKS" -le 20 ] || [ $((TICK % 10)) -eq 0 ]; then write_tile_state; fi
  # 磁贴保活进程看护：它被系统/管理器清掉后，磁贴又会变回"点了没反应"。
  # 每 5 轮查一次（一个 pgrep，稳态下几十秒一次，可忽略）。
  if [ $((TICK % 5)) -eq 0 ] && [ "$ENABLED" = "1" ]; then
    [ -n "$(tile_keep_pids)" ] || tile_keep_start
  fi
  next_interval
  nap "$IV"
done
