#!/system/bin/sh
# bg-ctl.sh — 控制接口（WebUI 调用）
#
#   status            输出实时状态（直接读 sysfs，不是旧文件）
#   get               输出配置
#   set KEY VALUE     改配置
#   boot              开机启动完整链路（service.sh 调，ENABLED=0 时不启动）
#   on                手动旁路（MODE=force_on），仅在插电时有意义
#   auto              交回自动模式（点到"恢复自动"就是它），按阈值裁决
#   stop              彻底停止所有守护进程（关总开关时用，零常驻省电）
#   log [n]           日志尾部
#   restart           重启守护
#
# v1.8.0-fork.1：force_off 是正式状态，不是"废弃的手动充电模式"。
#        「按阈值自动」关掉、「现在恢复充电」都落到它；守护在充满后交回 auto。
#        flip 支持 on / off / cancel，无参数的旧形式保留给已装的旧磁贴。

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
. "$MODDIR/bin/bg-lib.sh"

load_conf
find_bat
batt_info

# BP 是本进程的记账值，print_state / write_tile_state 都要用。
# 以前只有 status 分支给它赋值，于是 boot 写出的磁贴副本是 "BP="（空串），
# 磁贴/界面按字符串比较 BP=1 就会把"阈值停在 80% 正在旁充"判成没在旁充。
BP=$(read_bp)

ONCH=0
on_charger && ONCH=1

# 改完配置后按新配置校正一次停充位，不等守护醒来。
# 原因：mksh 在 wait 子进程时用 sigsuspend，SIGUSR1 会被屏蔽，光靠信号不可靠。
reconcile() {
  _bp=$(read_bp)
  # 断充兜底只在"没有 smart_chg、被迫走 input_suspend"时才允许存在，
  # 其余任何情形都必须释放，否则插着电也不充（v1.2 踩过）。
  [ "$BACKEND" = "input_suspend" ] && [ "$MODE" = "force_on" ] || suspend_off
  if [ "$ENABLED" != "1" ]; then
    bypass_off_now
  elif [ "$MODE" = "force_on" ]; then
    bypass_on_now
  elif [ "$ONCH" = "1" ]; then
    # 按"当前电量 vs 阈值"直接裁决，不走滞回区：
    # 把阈值调到当前电量之上，就是想继续充，得把停充位松开。
    if [ "$LEVEL" -ge "$THRESHOLD_ON" ] 2>/dev/null; then
      smart_set "$THRESHOLD_ON"; write_bp 1; BP=1
    elif [ "$_bp" = "1" ]; then
      bypass_off_now
    fi
  fi
  # 顺手叫一下守护（能醒更好，醒不了上面已经校正过了）
  _dpid=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
  [ -n "$_dpid" ] && kill -USR1 "$_dpid" 2>/dev/null
}

# ---- 进程管理：关总开关时彻底停掉，零常驻、零唤醒 ----
# 关键：supervise 会在 daemon 退出后 3 秒把它拉起来，所以必须先停 supervise，
# 再停 daemon 和 watch，否则杀了 daemon 又活过来，等于没停。
supervise_pids() {
  for p in $(pgrep -f "bg-supervise[.]sh" 2>/dev/null); do
    [ -r "/proc/$p/cmdline" ] || continue
    case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in
      *bg-supervise.sh*) echo "$p" ;;
    esac
  done
}

daemon_pids() {
  for p in $(pgrep -f "bg-daemon[.]sh" 2>/dev/null); do
    [ -r "/proc/$p/cmdline" ] || continue
    case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in
      *bg-daemon.sh*) echo "$p" ;;
    esac
  done
}

# 彻底停止：先 supervise（防止它拉起 daemon），再 daemon，再 watch
stop_all() {
  for p in $(supervise_pids); do kill "$p" 2>/dev/null; done
  for p in $(daemon_pids); do kill "$p" 2>/dev/null; done
  watch_stop
  tile_keep_stop
  # 轮询等退出，没了就立刻走（省掉固定 sleep 1）
  i=0
  while [ "$i" -lt 10 ]; do
    [ -z "$(supervise_pids)" ] && [ -z "$(daemon_pids)" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  # 兜底强杀（supervise 可能在 sleep 3 里，TERM 后仍会再拉一次）
  for p in $(supervise_pids); do kill -9 "$p" 2>/dev/null; done
  for p in $(daemon_pids); do kill -9 "$p" 2>/dev/null; done
  rm -f "$DATA_DIR/daemon.pid" "$DATA_DIR/supervisor.pid" 2>/dev/null
}

# 完整启动：开机 / 重新打开总开关时用
start_all() {
  # 磁贴保活独立于守护链路，先确保它在
  tile_keep_start
  # 已经在跑就不重复拉
  if [ -n "$(supervise_pids)" ]; then
    # supervise 在，只需确保 daemon 活着（它会自己拉）
    # 但 watch 是独立进程，可能被单独杀掉，补一下（插拔监听固定常开）
    watch_start
    return 0
  fi
  # setsid 脱离本命令的进程组：bg-ctl 由 WebUI exec，退出会清掉自己 fork 的后台进程
  setsid "$MODDIR/bin/bg-supervise.sh" >/dev/null 2>&1 < /dev/null &
  # 不要在这里 rm .watch.lock：那会让 watch_start 的去重失效，
  # 每次 boot 都多起一个 watch，旧的杀不掉就堆成 4 个实例白费电。
  # 让 watch_start 自己看锁 + cmdline 判断要不要起。
  watch_start
}

# 插拔监听：固定常开（界面开关已取消）
watch_start() {
  # 去重要彻底：只要已经有任何活着的 watch 实例（含子 shell），就不再起。
  # 旧版只看锁文件里的单个 pid，锁被覆盖/残留时漏判，导致反复 boot 堆出 4 个实例。
  [ -n "$(watch_pids)" ] && return 0
  setsid sh "$MODDIR/bin/bg-watch.sh" >/dev/null 2>&1 < /dev/null &
}

# 找所有真正在跑的 bg-watch 进程（不能只信锁文件：pid 会复用、锁可能残留）
watch_pids() {
  for p in $(pgrep -f "bg-watch[.]sh" 2>/dev/null); do
    [ -r "/proc/$p/cmdline" ] || continue
    case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in
      *bg-watch.sh*) echo "$p" ;;
    esac
  done
}

watch_stop() {
  # 先 TERM 所有实例（主+子 shell 都被 watch_pids 认 cmdline 抓到）
  for p in $(watch_pids); do kill "$p" 2>/dev/null; done
  # 轮询等待退出，没了就立刻返回（不再固定睡两轮，关闭响应从 ~3s 降到 ~0.2s）
  i=0
  while [ "$i" -lt 10 ]; do
    [ -z "$(watch_pids)" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  # 还没死透就强杀一次
  for p in $(watch_pids); do kill -9 "$p" 2>/dev/null; done
  rm -rf "$DATA_DIR/.watch.lock" 2>/dev/null
}

watch_status() {
  [ -n "$(watch_pids)" ] && echo "1" || echo "0"
}

cmd=$1

case "$cmd" in
  status)
    # 实时读，界面数据不受守护轮询间隔影响
    BP=$(read_bp)
    print_state ts
    if daemon_alive; then echo "DAEMON=1"; else echo "DAEMON=0"; fi
    echo "WATCH_RUNNING=$(watch_status)"
    ;;

  get)
    cat "$CONF"
    ;;

  set)
    k=$2; v=$3
    [ -z "$k" ] && { echo "ERR|missing key"; exit 1; }
    case "$k" in
      ENABLED)
        set_key ENABLED "$v"; load_conf
        if [ "$v" = "0" ]; then
          # 关总开关：先松开停充位（否则插电不充），再彻底停掉所有进程省电
          bypass_off_now
          stop_all
          write_tile_state
          echo "OK"
        else
          # 开总开关：拉起完整链路
          set_key MODE auto; MODE=auto
          start_all
          write_tile_state
          echo "OK"
        fi
        ;;
      MODE|THRESHOLD_ON|THRESHOLD_OFF)
        [ "$k" = "MODE" ] && set_key MANUAL_FROM ""
        set_key "$k" "$v"; load_conf; reconcile
        write_tile_state
        echo "OK"
        ;;
      POLL|CHECK_INTERVAL|NOTIFY|BACKEND|SMART_MODE|FALLBACK)
        set_key "$k" "$v"; load_conf
        echo "OK"
        ;;

      WATCH)
        # 开关已取消，监听固定常开；老界面/脚本再调也只当"确保在跑"
        set_key WATCH 1; watch_start; echo "OK"
        ;;
      *)
        echo "ERR|unknown key"
        exit 1
        ;;
    esac
    ;;

  on|pause)
    if ! on_charger; then
      echo "ERR|未插电，旁路无意义"
      exit 1
    fi
    # 立刻生效：停充电量取"当前电量"，不看阈值（阈值 85 而当前 70 时写 85 是不会停的）
    lvl=$LEVEL
    [ -z "$lvl" ] && lvl=80
    [ "$lvl" -lt 20 ] 2>/dev/null && lvl=20
    set_key MODE force_on; MODE=force_on
    bypass_on_now
    # 只做 3 秒快速确认，确认不到也算"指令已下发"（PD 重协商本来就要几秒）
    i=0; ok=0
    while [ "$i" -lt 3 ]; do
      sleep 1; batt_info
      if is_stopped; then ok=1; break; fi
      i=$((i + 1))
    done
    logi "ctl on level=$lvl stopped=$ok cur=$CUR"
    write_tile_state
    push_ui "已开启旁路 · 电量 ${LEVEL}%"
    if [ "$ok" = "1" ]; then echo "OK"; else echo "OK|已下发，等待电池停充（当前 ${CUR}µA）"; fi
    exit 0
    ;;

  auto)
    # "恢复自动"：清掉手动标记，按阈值重新裁决。
    # 去掉了原来的 resume(force_off)：手动充电没必要单独做个模式，
    # 关掉旁路总开关就等价于手动充电，这里只负责交回自动。
    set_key MANUAL_FROM ""
    set_key MODE auto
    load_conf
    reconcile
    batt_info
    write_tile_state
    push_ui "已恢复自动模式 · 电量 ${LEVEL}%"
    echo "OK"
    ;;

  boot)
    # 开机入口：ENABLED=0 时什么都不起（彻底省电），否则拉起完整链路
    if [ "$ENABLED" != "1" ]; then
      bypass_off_now
      stop_all          # 连残留进程一起清，保证"关了就是零占用"
      write_tile_state
      echo "OK|disabled"
      exit 0
    fi
    start_all
    write_tile_state
    echo "OK"
    ;;

  stop)
    # 彻底停止（关总开关 / 排障用）
    bypass_off_now
    stop_all
    write_tile_state
    echo "OK"
    ;;

  flip)
    # 只翻转 MODE + 当场改停充位，立刻返回（不等物理停充，磁贴不卡）。
    #
    # flip on  / flip off：界面（WebUI、磁贴新版本）明确告诉我要开还是要关。
    #   这是唯一可靠的方式 —— 之前靠 MODE 反推意图，一旦界面状态和配置文件
    #   差一拍（乐观更新、轮询延迟、两次点击），就会落到反方向：
    #   auto 下手动旁路后再点一次会"悄悄"退回 auto，表现就是"点了没反应/关不掉"。
    # flip（无参数）：老接口，保留给已安装的旧磁贴，按当前 MODE 翻转。
    if [ "$ENABLED" != "1" ]; then
      echo "ERR|模块已停用"; exit 1
    fi
    # 守护链路没在跑就先补起来（刚开机 service.sh 还没跑完、或守护被系统清理时）。
    # flip 自己会当场写停充位，但阈值自动的巡检、插拔监听、状态副本都靠这条链，
    # 链没起来就会"点下去像没反应"，或者过一会儿状态又被陈货覆盖回去。
    # start_all 内部去重，已经在跑就是空操作。
    if [ -z "$(supervise_pids)" ]; then
      start_all
      logi "flip: 守护链路未运行，已补拉起"
    fi
    _want=$2
    # 目标模式用 _tm 这个专属变量名：下面会调 batt_info，它内部会改 _N/_cs，
    # 千万不要用 _t 之类的通用名（历史 bug，见 bg-lib.sh chk_set 的注释）。
    _tm=""
    case "$_want" in
      on)
        _tm=force_on
        ;;
      off)
        # 无条件恢复正常充电。用于「关闭按阈值自动」——
        # 这里绝不能退回 auto，否则 auto 到阈值本来就会继续停充，用户看到的就是"关不掉"。
        _tm=force_off
        ;;
      cancel)
        # 取消手动旁路，按原策略交接（界面上的「恢复正常充电」走这条）：
        #   · 手动旁路是从「按阈值自动」插进来的，且还没到阈值 → 还回 auto，继续按阈值自动
        #   · 已经到/超过阈值，或本来就是手动开的 → force_off 真·正常充电
        if [ "$MANUAL_FROM" = "auto" ] && [ "$LEVEL" -lt "$THRESHOLD_ON" ] 2>/dev/null; then
          _tm=auto
        else
          _tm=force_off
        fi
        ;;
      *)
        case "$MODE" in
          force_on)
            # 到阈值了还手动旁路 → 取消就是恢复正常充电；
            # 没到阈值且原本在按阈值自动 → 退回 auto，继续按阈值自动。
            if [ "$LEVEL" -ge "$THRESHOLD_ON" ] 2>/dev/null; then
              _tm=force_off
            elif [ "$MANUAL_FROM" = "auto" ]; then
              _tm=auto
            else
              _tm=force_off
            fi
            ;;
          *) _tm=force_on ;;
        esac
        ;;
    esac
    # 记下"手动旁路是从哪个模式插进来的"，取消时才知道该还回哪里
    if [ "$_tm" = "force_on" ] && [ "$MODE" = "auto" ]; then
      set_key MANUAL_FROM auto
    elif [ "$_tm" != "force_on" ]; then
      set_key MANUAL_FROM ""
    fi
    set_key MODE "$_tm"
    load_conf
    batt_info
    # 当场执行，不等守护下一轮巡检（下一轮可能是 60 秒后）。
    # 注意两边的耗时不对称：开（smart_set + verify）是毫秒级；
    # 关（smart_clear）必须先写 0x2、等 CLEAR_GAP（默认 3 秒）才写 0，
    # 抢不到 flock 时两次写各还要重试 6×0.2 秒 —— 关一路 ≥3 秒、最坏约 5.4 秒。
    # 所以磁贴侧那次 waitFor 的超时必须留到 6 秒以上，否则会出现
    # "其实已经关了，磁贴却报 su 超时"。
    if [ "$_tm" = "force_on" ]; then
      if on_charger; then
        bypass_on_now
        logi "flip on level=$LEVEL cur=$CUR"
      fi
    else
      bypass_off_now
      logi "flip off -> MODE=$_tm"
    fi
    batt_info
    write_tile_state
    # 叫醒守护：杀掉 nap 里的 sleep 子进程，wait 立刻返回，下一轮就按新 MODE 执行
    _p=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
    case "$_p" in
      ''|*[!0-9]*) : ;;
      *)
        if [ -r "/proc/$_p/cmdline" ]; then
          case "$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)" in
            *bg-daemon.sh*)
              for _c in $(pgrep -P "$_p" 2>/dev/null); do kill "$_c" 2>/dev/null; done
              ;;
          esac
        fi
        ;;
    esac
    if [ "$_tm" = "force_on" ] && ! on_charger; then
      echo "OK|MODE=$MODE|未插电，插上后自动旁路"
    else
      echo "OK|MODE=$MODE"
    fi
    ;;

  toggle)
    # 老接口保留：就是 flip 的别名（同样接受 on/off 参数）。
    sh "$0" flip "$2"
    ;;

  hide)
    hide_ui
    echo "OK"
    ;;

  log)
    n=${2:-40}
    tail -n "$n" "$LOGFILE" 2>/dev/null
    ;;

  restart)
    # 不要在这里杀 supervisor 再重新起：bg-ctl 是由 WebUI exec 拉起来的短命进程，
    # 它 fork 的后台进程会随命令结束被一起清掉，结果就是守护没了。
    # 正确做法：supervisor 活着时只杀守护，它 3 秒后自会拉起新的。
    SPD=$(cat "$DATA_DIR/supervisor.pid" 2>/dev/null)
    DPD=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
    alive=0
    case "$SPD" in
      ''|*[!0-9]*) : ;;
      *)
        [ -r "/proc/$SPD/cmdline" ] && \
        case "$(tr '\0' ' ' < "/proc/$SPD/cmdline" 2>/dev/null)" in
          *bg-supervise.sh*) alive=1 ;;
        esac
        ;;
    esac
    if [ "$alive" = "1" ]; then
      [ -n "$DPD" ] && kill "$DPD" 2>/dev/null
      echo "OK"
      exit 0
    fi
    # supervisor 确实不在了才重起；setsid 脱离当前进程组，避免随本命令退出被清掉
    setsid "$MODDIR/bin/bg-supervise.sh" >/dev/null 2>&1 < /dev/null &
    sleep 1
    echo "OK"
    ;;

  *)
    echo "ERR|unknown command: $cmd"
    exit 1
    ;;
esac
