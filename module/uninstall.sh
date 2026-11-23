#!/system/bin/sh
# uninstall.sh — 卸载时确保恢复充电
#
# 注意：smart_chg 的停充位是"驱动级"的，只写一次 0 可能解不掉（实测）。
# 必须 0x2 → 等 → 0，再补一次 input_suspend=0 和老节点复位。

DATA=/data/adb/MiBypassCharge

# 先停 supervisor，否则它 5 秒后又把守护拉起来，复位会被重新写回去
[ -f "$DATA/supervisor.pid" ] && kill "$(cat "$DATA/supervisor.pid" 2>/dev/null)" 2>/dev/null
[ -f "$DATA/tile-keep.pid" ] && kill "$(cat "$DATA/tile-keep.pid" 2>/dev/null)" 2>/dev/null
[ -f "$DATA/daemon.pid" ] && kill "$(cat "$DATA/daemon.pid" 2>/dev/null)" 2>/dev/null
# 用脚本名匹配，兼容新旧模块目录名（旧 id=bypass_guard / 新 id=MiBypassCharge）
pkill -f "bg-watch.sh" 2>/dev/null
pkill -f "bg-supervise.sh" 2>/dev/null
pkill -f "bg-daemon.sh" 2>/dev/null
pkill -f "bg-tile-keep.sh" 2>/dev/null
sleep 2

QB=/sys/class/qcom-battery

# 1) 官方停充位（两步复位）
if [ -w "$QB/smart_chg" ]; then
  echo 0x2 > "$QB/smart_chg" 2>/dev/null
  sleep 6
  echo 0 > "$QB/smart_chg" 2>/dev/null
  sleep 2
fi

# 2) 输入挂起（兜底模式留下的）
[ -w "$QB/input_suspend" ] && echo 0 > "$QB/input_suspend" 2>/dev/null

# 3) 老节点（K70 上不存在，留着给别的机型）
[ -w /sys/class/qcom-battery/restricted_charging ] && echo 0 > /sys/class/qcom-battery/restricted_charging 2>/dev/null
[ -w /sys/class/power_supply/battery/input_suspend ] && echo 0 > /sys/class/power_supply/battery/input_suspend 2>/dev/null
[ -w /sys/class/power_supply/battery/battery_charging_enabled ] && echo 1 > /sys/class/power_supply/battery/battery_charging_enabled 2>/dev/null
[ -w /sys/class/power_supply/battery/charging_enabled ] && echo 1 > /sys/class/power_supply/battery/charging_enabled 2>/dev/null
[ -w /sys/class/power_supply/battery/charge_disable ] && echo 0 > /sys/class/power_supply/battery/charge_disable 2>/dev/null

rm -f "$DATA/bp_on" 2>/dev/null
