SKIPUNZIP=0

# 安装横幅：不用方框包裹中文（中英文字符在 KSU 终端宽度不等，会错位）
ui_print " "
ui_print "  ======== MiBypassCharge ========"
ui_print "   smart_chg 官方停充位"
ui_print " "
# 版本号从 module.prop 动态读取，避免硬编码后忘记更新
if [ -f "$MODPATH/module.prop" ]; then
  _v=$(grep '^version=' "$MODPATH/module.prop" | head -1 | cut -d= -f2)
  [ -n "$_v" ] && ui_print "   $_v"
fi
ui_print " "

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755

set_perm "$MODPATH/service.sh"   0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755

# 刷模块时顺手把控制中心磁贴 App 装上。
# 不装也行：模块本体在 WebUI 里也能用，只是少了控制中心开关。
# HyperOS/MIUI 可能拦非商店来源的静默安装，这里失败不算致命，
# 只把 APK 留到 /sdcard/Download 并写待装标记，开机后 service.sh 会再试。
if [ -f "$MODPATH/webroot/MiBypassChargeTile.apk" ]; then
  ui_print "- 安装控制中心磁贴 App…"
  _r=$(sh "$MODPATH/bin/bg-tile-install.sh" "$MODPATH/webroot/MiBypassChargeTile.apk" --force 2>&1)
  case "$_r" in
    OK*)
      ui_print "  ✓ 磁贴已安装：控制中心 → 编辑 → 添加「旁路充电」"
      ;;
    NOAPK)
      ui_print "  ! 模块里没带磁贴 APK（跳过）"
      ;;
    *)
      ui_print "  ! 自动安装被系统拦截：${_r#FAIL|}"
      ui_print "  → 已放到 /sdcard/Download/MiBypassChargeTile.apk，点它手动安装一次即可"
      ui_print "  → 开机后也会自动再试一次"
      ;;
  esac
fi

ui_print "- 安装完成（重启后生效）"
ui_print "- 打开方式：桌面「旁路供电」图标（就是模块 WebUI），或 KernelSU → 模块 → 打开"
ui_print "- 停充阈值等参数见 WebUI；配置不随升级丢失"
ui_print " "
