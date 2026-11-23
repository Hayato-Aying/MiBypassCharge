#!/system/bin/sh
# 真机回归 —— 跑完自动恢复原配置
#
# 目标版本：v1.8.0-fork.1（模块 ID 已改为 MiBypassCharge）
# 实测环境：Redmi K70 / OS4.0.3.0.XNKCNXM（Android 17）/ KernelSU
#
# 覆盖：进程自愈 / 插拔监听固定常开不堆积 / 巡检间隔与老配置补字段 /
#       force_off 是正式状态 / 阈值裁决（需插电，否则 SKIP）/ 总开关彻底停进程 /
#       flip 三态（on / off / cancel）/ WebUI 元素
#
# 用法：docs/ 不随 zip 发，先把本文件拷到手机：
#   adb push docs/test.sh /data/local/tmp/
#   adb shell su -c "sh /data/local/tmp/test.sh"
#       插着电跑能覆盖阈值裁决；没插电时那几项会打 SKIP，不算失败。
M=/data/adb/modules/MiBypassCharge
D=/data/adb/MiBypassCharge
CTL="$M/bin/bg-ctl.sh"
B=/sys/class/power_supply/battery
Q=/sys/class/qcom-battery

pass=0; fail=0; skip=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }
skp()  { echo "  SKIP  $1"; skip=$((skip+1)); }

cur()  { cat $B/current_now 2>/dev/null; }
cap()  { cat $B/capacity 2>/dev/null; }
smart(){ cat $Q/smart_chg 2>/dev/null; }
bp()   { cat $D/bp_on 2>/dev/null; }
mode() { grep '^MODE=' $D/config.conf 2>/dev/null | cut -d= -f2; }
conf() { grep "^$1=" $D/config.conf 2>/dev/null | cut -d= -f2; }

# 插着电才谈得上停充/恢复
plugged() {
  case "$(cat $B/status 2>/dev/null)" in
    Charging|Full|"Not charging"|"Charging (AC)"*) return 0 ;;
  esac
  return 1
}

# 计数必须校验 /proc cmdline：裸 pgrep -f 会把执行脚本的 su/adb shell 自身算进去
pcnt() {
  n=0
  for p in $(pgrep -f "$1" 2>/dev/null); do
    [ -r "/proc/$p/cmdline" ] || continue
    case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in
      *"$2"*) n=$((n+1)) ;;
    esac
  done
  echo $n
}
dcount(){ pcnt 'bg-[d]aemon' 'bg-daemon.sh'; }
scount(){ pcnt 'bg-[s]upervise' 'bg-supervise.sh'; }
wcount(){ pcnt 'bg-[w]atch' 'bg-watch.sh'; }

wait_stop() {
  i=0
  while [ $i -lt 45 ]; do
    c=$(cur); s=$(smart)
    if [ "${c#-}" -lt 120000 ] 2>/dev/null && [ "$s" != "0" ] 2>/dev/null; then return 0; fi
    sleep 1; i=$((i+1))
  done
  return 1
}
wait_charge() {
  i=0; hit=0
  while [ $i -lt 40 ]; do
    c=$(cur); s=$(smart)
    case "$c" in
      -*) n=${c#-}; if [ "$n" -gt 500000 ] 2>/dev/null && [ "$s" = "0" ] 2>/dev/null; then hit=$((hit+1)); else hit=0; fi ;;
      *) hit=0 ;;
    esac
    [ "$hit" -ge 2 ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

echo "======== 旁路供电 完整回归 ========"
echo "版本: $(grep '^version=' $M/module.prop | cut -d= -f2)"
echo "开始: $(date '+%F %T')  电量: $(cap)%  $(plugged && echo 插电中 || echo 未插电)"
echo

cp $D/config.conf $D/.test-config.bak

# ============ 0. 基线 ============
echo "[0] 基线检查"
sh $CTL boot >/dev/null 2>&1
sleep 5
ver=$(grep '^version=' $M/module.prop | cut -d= -f2)
case "$ver" in
  v1.*) ok "版本 $ver" ;;
  *)    bad "版本异常 $ver" ;;
esac
# customize.sh 只在安装阶段存在，装完会被删除，所以只在文件存在时检查
for f in $M/bin/*.sh $M/service.sh $M/uninstall.sh; do
  [ -f "$f" ] || continue
  sh -n "$f" 2>/dev/null || bad "语法 $f"
done
[ -f "$M/customize.sh" ] && { sh -n "$M/customize.sh" 2>/dev/null || bad "语法 customize.sh"; }
ok "脚本语法全部通过"
[ "$(dcount)" -eq 1 ] && ok "daemon=1" || bad "daemon 数量=$(dcount)"
[ "$(scount)" -eq 1 ] && ok "supervise=1" || bad "supervise 数量=$(scount)"
[ "$(wcount)" -eq 2 ] && ok "watch=2（1 主 + 1 管道子）" || bad "watch 数量=$(wcount)"

# ============ 1. 守护自愈 ============
echo "[1] kill daemon → supervise 自动重启"
old=$(cat $D/daemon.pid 2>/dev/null)
kill "$old" 2>/dev/null
# 等旧 pid 真的消失（TERM 后要跑 on_exit 的 smart_clear，可能 3 秒）
i=0
while [ $i -lt 12 ]; do
  [ -d "/proc/$old" ] || break
  sleep 1; i=$((i+1))
done
# 再等新 daemon 出现（supervise 3 秒后拉起）
i=0; new=""
while [ $i -lt 20 ]; do
  sleep 1; new=$(cat $D/daemon.pid 2>/dev/null)
  if [ -n "$new" ] && [ -d "/proc/$new" ] && [ "$new" != "$old" ]; then break; fi
  i=$((i+1))
done
[ -n "$new" ] && [ -d "/proc/$new" ] && [ "$new" != "$old" ] && ok "daemon $old → $new (${i}s)" || bad "未重启(old=$old new=$new)"
if plugged; then
  wait_stop && ok "重启后重新停充" || bad "重启后未停充"
else
  skp "重启后重新停充（未插电）"
fi

# ============ 2. 插拔监听：固定常开、不堆积 ============
# v1.8.0-fork.1 起界面上去掉了这个开关，WATCH 恒为 1；
# bg-ctl set WATCH 0 只当"确保在跑"，不应真的把监听停掉。
echo "[2] 插拔监听固定常开"
sh $CTL set WATCH 0 >/dev/null 2>&1; sleep 2
w=$(conf WATCH); n=$(wcount)
[ "$w" = "1" ] && [ "$n" -eq 2 ] && ok "set WATCH 0 被忽略：WATCH=1 进程=2" || bad "WATCH=$w 进程=$n"

for r in 1 2 3; do
  sh $CTL set WATCH 1 >/dev/null 2>&1; sleep 1
done
w2=$(wcount)
[ "$w2" -eq 2 ] && ok "反复 set 仍=2，不堆积" || bad "堆积：$w2（应为2）"

sh $CTL boot >/dev/null 2>&1; sleep 3
w3=$(wcount)
[ "$w3" -eq 2 ] && ok "重复 boot 仍=2" || bad "boot 后=$w3（应为2）"

# ============ 3. 巡检间隔 + 老配置补字段 + force_off 是正式状态 ============
echo "[3] 巡检间隔 / 老配置 / force_off"
sh $CTL set CHECK_INTERVAL 45 >/dev/null 2>&1
v=$(conf CHECK_INTERVAL)
[ "$v" = "45" ] && ok "间隔写入 45" || bad "间隔写入失败($v)"

# 删掉两个字段模拟 v1.7.x 老配置，load_conf 应补写回去
sed -i '/^WATCH=/d; /^CHECK_INTERVAL=/d' $D/config.conf
sh $CTL status >/dev/null 2>&1; sleep 1
hw=$(grep -c '^WATCH=' $D/config.conf); hc=$(grep -c '^CHECK_INTERVAL=' $D/config.conf)
[ "$hw" -ge 1 ] && [ "$hc" -ge 1 ] && ok "老配置自动补字段" || bad "字段未补(W=$hw C=$hc)"
sh $CTL set CHECK_INTERVAL 30 >/dev/null 2>&1

# 上游 v1.7.2 会把 force_off 迁移成 auto，fork 删掉了这条迁移：force_off 必须保留
sed -i 's/^MODE=.*/MODE=force_off/' $D/config.conf
sh $CTL status >/dev/null 2>&1; sleep 1
mv=$(mode)
[ "$mv" = "force_off" ] && ok "force_off 保留为正式状态" || bad "force_off 被改写($mv)"
sh $CTL auto >/dev/null 2>&1; sleep 1
[ "$(mode)" = "auto" ] && ok "auto 交回阈值自动" || bad "auto 失败($(mode))"

# ============ 4~6. 阈值裁决（需插电）============
if plugged; then
  echo "[4] 阈值 85 → 90（应恢复充电）"
  sh $CTL set THRESHOLD_ON 90 >/dev/null 2>&1
  wait_charge && ok "恢复充电(cur=$(cur))" || bad "未恢复"

  echo "[5] 阈值 90 → 85（应停充）"
  sh $CTL set THRESHOLD_ON 85 >/dev/null 2>&1
  wait_stop && ok "停充(cur=$(cur))" || bad "未停"

  echo "[6] 边界 100 / 40"
  sh $CTL set THRESHOLD_ON 100 >/dev/null 2>&1
  wait_charge && ok "100 恢复充电" || bad "100 未恢复"
  sh $CTL set THRESHOLD_ON 40 >/dev/null 2>&1
  wait_stop && ok "40 停充" || bad "40 未停"
  sh $CTL set THRESHOLD_ON 85 >/dev/null 2>&1
  sh $CTL set THRESHOLD_OFF 80 >/dev/null 2>&1
  wait_stop && ok "回 85/80" || bad "回 85/80 失败"
else
  echo "[4~6] 阈值裁决"
  skp "阈值裁决（未插电：恢复充电 / 停充 / 边界 100 / 40 共 5 项）"
fi

# ============ 7. 总开关：彻底停进程 ============
echo "[7] 总开关 → 彻底停进程省电"
sh $CTL set ENABLED 0 >/dev/null 2>&1
sleep 4
[ "$(dcount)" -eq 0 ] && [ "$(scount)" -eq 0 ] && [ "$(wcount)" -eq 0 ] \
  && ok "关：daemon/supervise/watch 全停" \
  || bad "关：仍有进程 d=$(dcount) s=$(scount) w=$(wcount)"
if plugged; then
  wait_charge && ok "关：恢复充电" || bad "关：未恢复充电"
else
  skp "关：恢复充电（未插电）"
fi

sh $CTL set ENABLED 1 >/dev/null 2>&1
sleep 4
[ "$(dcount)" -eq 1 ] && [ "$(scount)" -eq 1 ] && [ "$(wcount)" -eq 2 ] \
  && ok "开：进程恢复 1/1/2" \
  || bad "开：进程异常 d=$(dcount) s=$(scount) w=$(wcount)"
if plugged; then
  wait_stop && ok "开：重新停充" || bad "开：未停充"
else
  skp "开：重新停充（未插电）"
fi

# ============ 8. flip 三态 ============
echo "[8] flip on / off / cancel"
sh $CTL auto >/dev/null 2>&1; sleep 1
[ "$(mode)" = "auto" ] && ok "起点 auto" || bad "起点=$(mode)"

sh $CTL flip on >/dev/null 2>&1; sleep 1
[ "$(mode)" = "force_on" ] && ok "flip on → force_on" || bad "flip on=$(mode)"

sh $CTL flip off >/dev/null 2>&1; sleep 1
[ "$(mode)" = "force_off" ] && ok "flip off → force_off（无条件恢复充电）" || bad "flip off=$(mode)"
[ "$(smart)" = "0" ] && ok "flip off 已松开停充位" || bad "停充位未松开($(smart))"

# cancel：从 auto 手动插进来的，没到阈值还回 auto；已到阈值 / 手动开的 → force_off
lvl=$(cap); on=$(conf THRESHOLD_ON)
sh $CTL auto >/dev/null 2>&1; sleep 1
sh $CTL flip on >/dev/null 2>&1; sleep 1
sh $CTL flip cancel >/dev/null 2>&1; sleep 1
mc=$(mode)
if [ "$lvl" -lt "$on" ] 2>/dev/null; then
  [ "$mc" = "auto" ] && ok "flip cancel（${lvl}% < ${on}%）→ auto" || bad "cancel=$mc（应 auto）"
else
  [ "$mc" = "force_off" ] && ok "flip cancel（${lvl}% ≥ ${on}%）→ force_off" || bad "cancel=$mc（应 force_off）"
fi

# toggle 是 flip 的别名，老磁贴还在用
sh $CTL auto >/dev/null 2>&1; sleep 1
sh $CTL toggle on >/dev/null 2>&1; sleep 1
[ "$(mode)" = "force_on" ] && ok "toggle on 等价 flip on" || bad "toggle on=$(mode)"
sh $CTL auto >/dev/null 2>&1; sleep 1

# ============ 9. WebUI 元素 ============
echo "[9] WebUI 元素"
html=$M/webroot/index.html
for id in enabled pollNum thNum lowNum btnToggle btnTile nodeText daemonText bgtoast; do
  grep -q "id=\"$id\"" "$html" && ok "元素 $id" || bad "元素 $id 缺失"
done
# 插拔开关已删除，不该再有 watchOn
grep -q 'id="watchOn"' "$html" && bad "残留 watchOn 元素" || ok "无 watchOn 元素"
grep -q 'function nextFrame' "$html" && ok "nextFrame 存在" || bad "nextFrame 缺失"
grep -qE 'ksu[.]toast|k[.]toast' "$html" && ok "调用系统 toast" || bad "未用系统 toast"
grep -qE 'refreshTimer *= *setInterval' "$html" && ok "轮询用 refreshTimer" || bad "轮询实现变了"
# 输入框有焦点时不能被 3 秒刷新覆盖（低阈值手输修复）
grep -q 'document.activeElement' "$html" && ok "刷新跳过聚焦输入框" || bad "缺聚焦保护"
css=$M/webroot/style.css
grep -q 'track::before' "$css" && ok "开关背景用 opacity 合成层" || bad "CSS 未改合成层"
grep -q 'will-change' "$css" && ok "will-change 已加" || bad "缺 will-change"
grep -q '不会停充，插多少充多少' "$html" && ok "总开关关闭文案" || bad "缺关闭文案"

# ============ 恢复 ============
echo "[10] 恢复原配置"
cp $D/.test-config.bak $D/config.conf
rm -f $D/.test-config.bak
sh $CTL boot >/dev/null 2>&1
sleep 3
echo "  最终: cap=$(cap)% cur=$(cur) smart=$(smart) bp=$(bp)"
echo "  进程: d=$(dcount) s=$(scount) w=$(wcount)"
echo "  配置: $(grep -E 'ENABLED|MODE|THRESHOLD_ON|THRESHOLD_OFF|WATCH|CHECK_INTERVAL' $D/config.conf | tr '\n' ' ')"
echo
echo "======== 结果: $pass PASS / $fail FAIL / $skip SKIP ========"
echo "结束: $(date '+%F %T')"
