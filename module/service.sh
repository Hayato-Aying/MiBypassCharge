#!/system/bin/sh
# service.sh — 开机拉起守护
#
# 守护本体交给 bg-supervise.sh 看护：它退出就重启，活着时零唤醒。
# 原来这里是「每 30 秒 pgrep 一次」，既多一层定时唤醒，pgrep -f 还会误判。

MODDIR=${0%/*}
DATA=/data/adb/MiBypassCharge

mkdir -p "$DATA" 2>/dev/null

# 等待系统启动完成
i=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 2
  i=$((i + 1))
  [ "$i" -gt 90 ] && break
done

# 再多等一会儿，等充电驱动初始化完
sleep 8

# 清掉上一次残留（重启后 pid 文件还在的情况）
if [ -f "$DATA/supervisor.pid" ]; then
  _o=$(cat "$DATA/supervisor.pid" 2>/dev/null)
  [ -n "$_o" ] && kill "$_o" 2>/dev/null
  sleep 1
fi
# 用脚本名匹配，兼容新旧模块目录名（旧 id=bypass_guard / 新 id=MiBypassCharge）
pkill -f "bg-watch.sh" 2>/dev/null
pkill -f "bg-supervise.sh" 2>/dev/null
pkill -f "bg-daemon.sh" 2>/dev/null
pkill -f "bg-tile-keep.sh" 2>/dev/null
sleep 1

# 开机清掉上次遗留的锁（pid 会被复用，留着只会误导）
rm -rf "$DATA/.watch.lock" 2>/dev/null

# 统一交给 bg-ctl boot：ENABLED=0 时它只恢复充电、不启动任何进程（彻底省电），
# ENABLED=1 时才拉起 supervise + daemon + watch。判断逻辑只在一处，避免两处不一致。
MODDIR="$MODDIR" sh "$MODDIR/bin/bg-ctl.sh" boot >/dev/null 2>&1

# 补装磁贴 App：刷模块时如果被 HyperOS 拦下（INSTALL_FAILED_USER_RESTRICTED），
# 这里再试。只在"没装"或"上次留了待装标记"时才动手，已装好就什么都不做。
# 放后台跑：pm install 可能要几秒，不该拖住 service.sh。
(
  PKG=com.changxyz.mibypasscharge.tile
  PENDING=$DATA/tile_apk_pending
  _need=0
  pm list packages 2>/dev/null | grep -qx "package:$PKG" || _need=1
  [ -f "$PENDING" ] && _need=1
  if [ "$_need" = "1" ]; then
    _r=$(sh "$MODDIR/bin/bg-tile-install.sh" 2>&1)
    case "$_r" in
      OK*) rm -f "$PENDING" 2>/dev/null ;;
    esac
  fi
) >/dev/null 2>&1 &

