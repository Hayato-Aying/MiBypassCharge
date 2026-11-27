#!/system/bin/sh
# bg-watch.sh — 充电插拔监听器（事件唤醒）
#
# 为什么需要它：纯 shell 没法监听 sysfs 变化（sysfs 不支持 inotify，
# 也没有 netlink 工具）。唯一的"真事件源"是 Android 的 events buffer：
#
#   battery_status: [status, health, present, plugged, technology]
#                    2=充电 3=放电            1=AC 2=USB 4=无线 0=未插
#
# 只在 plugged（第 4 个字段）变化时叫醒守护，status 的抖动不管。
# 叫醒方式不是发信号（mksh 在 wait 子进程时会屏蔽），而是直接杀掉
# 守护的 sleep 子进程 —— wait 立刻返回，守护马上跑一轮。
#
# 成本：实测 logcat 只收这一个 tag 约 0.233% 单核。换来的是插拔 0 延迟，
# 且守护的轮询可以拉到 30/60 秒，总账不亏。

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
DATA_DIR=${DATA_DIR_OVERRIDE:-/data/adb/MiBypassCharge}
LASTFILE=$DATA_DIR/.plugged

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
# 坑：logcat | while read 会 fork 子 shell，子 shell 继承 EXIT trap，
# 它一结束就 rm -rf LOCK，把还活着的父进程的锁删了 → 下一个实例能起来 → 多实例。
# 而 POSIX 规定 $$ 在子 shell 里与父 shell 相同，所以"锁里的 pid == $$"这种校验拦不住它，
# 别再用 pid 比对当守护。这里改成不挂 EXIT trap：
# 进程只会因为信号退出（主循环是 while true，没有正常出口），
# 交给 INT/TERM/HUP trap 收尾即可；万一被 SIGKILL 杀掉，锁会留下，
# 下次启动按 pid + 命令行认出死锁主并自己 rm -rf 重建（见上面 22-34 行）。
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

while true; do
  # -T <时间戳>：只跟这个时间之后的新事件（-t N 是"打最后 N 行然后退出"，不能用）
  TS=$(date '+%m-%d %H:%M:%S.000')
  logcat -b events -s battery_status:I -T "$TS" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *battery_status:*) ;;
      *) continue ;;
    esac
    # 剥掉 'battery_status: [' 之后，剩下 "3,2,1,0,Li-poly]"
    rest=${line#*battery_status:}
    rest=${rest#*[}
    rest=${rest#*,}          # 去掉 status
    rest=${rest#*,}          # 去掉 health
    rest=${rest#*,}          # 去掉 present
    pl=${rest%%,*}           # 剩下就是 plugged
    case "$pl" in ''|*[!0-9]*) continue ;; esac

    last=$(cat "$LASTFILE" 2>/dev/null)
    [ "$pl" = "$last" ] && continue
    echo "$pl" > "$LASTFILE" 2>/dev/null
    wake_daemon
  done
  # logcat 退出（重启 / buffer 重置）就重来
  sleep 5
done
