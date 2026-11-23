#!/system/bin/sh
# bg-tile-keep.sh — 磁贴保活
#
# 为什么需要它：
# HyperOS 的 freezer 会把"没有前台也没有常驻服务"的 App 冻起来。
# 磁贴 App 被冻住后，控制中心点磁贴的那一下要么丢、要么拖几十秒才执行，
# 用户看到的就是「点了没反应，尤其是 App 没在后台的时候」。
#
# 做法：每 20 秒看一眼磁贴 App 的进程，把它的 oom_score_adj 钉到 -900
# （等同于常驻应用，系统不会再把它当缓存进程冻掉），万一已经被冻就解冻。
# 只有一次 /proc 读取，几乎不耗电。总开关关掉时不钉，让它正常休眠。

DATA=/data/adb/MiBypassCharge
PKG=com.changxyz.mibypasscharge.tile
PIDF="$DATA/tile-keep.pid"

echo $$ > "$PIDF" 2>/dev/null

pin() {
  for p in $(pidof "$PKG" 2>/dev/null); do
    [ -d "/proc/$p" ] || continue
    _a=$(cat "/proc/$p/oom_score_adj" 2>/dev/null)
    [ "$_a" = "-900" ] || echo -900 > "/proc/$p/oom_score_adj" 2>/dev/null
    for f in /sys/fs/cgroup/uid_*/pid_"$p"/cgroup.freeze; do
      [ -f "$f" ] || continue
      [ "$(cat "$f" 2>/dev/null)" = "1" ] && echo 0 > "$f" 2>/dev/null
    done
  done
}

while :; do
  _en=$(sed -n 's/^ENABLED=//p' "$DATA/config.conf" 2>/dev/null | head -1)
  if [ "$_en" = "1" ]; then
    pin
  fi
  sleep 20
done
