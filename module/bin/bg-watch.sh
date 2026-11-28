#!/system/bin/sh
# bg-watch.sh — 充电插拔监听器
#
# 作用：插拔电源的瞬间把守护的 nap 打断，让它立刻跑一轮，
# 而不是等睡满一个轮询周期。叫醒方式不是发信号（mksh 在 wait 子进程时会
# 屏蔽），而是直接杀掉守护的 sleep 子进程 —— wait 立刻返回。
#
# 历史（v1.5~v1.8.2）：用 Android events buffer 的 battery_status 事件，
# 号称"0 延迟"，代价是 logcat 常驻约 0.233% 单核。
#
# 为什么改：这台 Redmi（HyperOS 3 / Android 16）的 events buffer
# 实质是空的 —— `logcat -b events -g` 显示只消费了 16 KiB，
# `logcat -b events -t 3000` 只有开机那 66 行 auditd，时间戳停在几个月前，
# 盯着看 6 秒零新增。也就是说 battery_status 事件从来没产出过一条，
# 这个监听器从装上那天起就没工作过，.plugged 文件至今不存在。
# 而它不工作是不报错的：logcat 安静地挂着，守护就一直在 nap 里睡到自然醒。
# 未插电时 next_interval 给的是 60s，于是"插上电 → 旁路 → 通知"最坏要等 76 秒。
#
# 两条候选事件源都实测排除了：
#   · sysfs 的 /sys/class/power_supply/usb/uevent 不是阻塞读，
#     `read -r line < uevent` 立刻返回第一行 POWER_SUPPLY_NAME=usb 就结束；
#   · 本机没有 netlink 工具，sysfs 也不支持 inotify。
#
# 所以退化成轮询：每 2 秒读一次各充电口的 online，签名变化就唤醒守护。
# 4 个小文件用 shell 内建 read 读，不 fork，开销比常驻 logcat 还低。
# 换来的是插拔延迟从"最坏 60s"变成"最坏 2s"，且不依赖任何系统日志行为。

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
DATA_DIR=${DATA_DIR_OVERRIDE:-/data/adb/MiBypassCharge}
PS=${SYSFS_ROOT:-}/sys/class/power_supply
LASTFILE=$DATA_DIR/.plugged
# 轮询粒度。2 秒是"人感觉不到延迟"和"省电"的折中。
WATCH_INTERVAL=${WATCH_INTERVAL:-2}

mkdir -p "$DATA_DIR" 2>/dev/null

# 单实例：mkdir 是原子的。光看 pid 会被复用骗到，所以还要认 /proc/<pid>/cmdline
LOCK=$DATA_DIR/.watch.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  old=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$old" ] && [ -r "/proc/$old/cmdline" ]; then
    case "$(tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null)" in
      *bg-watch.sh*) exit 0 ;;
    esac
  fi
  rm -rf "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK/pid" 2>/dev/null
# 坑：以前主循环里有 `logcat | while read`，管道会 fork 子 shell，子 shell 继承
# EXIT trap，它一结束就 rm -rf LOCK，把还活着的父进程的锁删了 → 下一个实例能起来 → 多实例。
# 而 POSIX 规定 $$ 在子 shell 里与父 shell 相同，所以"锁里的 pid == $$"这种校验拦不住它。
# 现在虽然已经没有管道了，这个规矩继续保留：不挂 EXIT trap，
# 进程只会因为信号退出（主循环是 while true），交给 INT/TERM/HUP 收尾；
# 万一被 SIGKILL 杀掉，锁会留下，下次启动按 pid + 命令行认出死锁主并自己重建。
release_lock() {
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null
}
trap 'release_lock; exit 0' INT TERM HUP

wake_daemon() {
  P=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
  case "$P" in ''|*[!0-9]*) return 0 ;; esac
  [ -r "/proc/$P/cmdline" ] || return 0
  case "$(tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null)" in
    *bg-daemon.sh*) ;;
    *) return 0 ;;
  esac
  # 杀掉 nap 里那个 sleep，wait 就会立刻返回
  for c in $(pgrep -P "$P" 2>/dev/null); do
    kill "$c" 2>/dev/null
  done
}

# 充电口签名：usb/ac/wireless/dc 四个口的 online 拼起来。
# 只看 usb/online 会漏掉无线充和部分 PD 走 ac 的机型；
# 读不到的路径 read 直接返回空串，拼出来仍是稳定签名。
plug_sig() {
  _pu=""; _pa=""; _pw=""; _pd=""
  read -r _pu 2>/dev/null < "$PS/usb/online"
  read -r _pa 2>/dev/null < "$PS/ac/online"
  read -r _pw 2>/dev/null < "$PS/wireless/online"
  read -r _pd 2>/dev/null < "$PS/dc/online"
  echo "${_pu:-0}:${_pa:-0}:${_pw:-0}:${_pd:-0}"
}

# 首次进来先记下当前状态，不要一启动就"以为刚插上电"
_last=$(cat "$LASTFILE" 2>/dev/null)
if [ -z "$_last" ]; then
  _last=$(plug_sig)
  echo "$_last" > "$LASTFILE" 2>/dev/null
fi

while true; do
  _now=$(plug_sig)
  if [ "$_now" != "$_last" ]; then
    _last=$_now
    echo "$_now" > "$LASTFILE" 2>/dev/null
    wake_daemon
  fi
  sleep "$WATCH_INTERVAL"
done
