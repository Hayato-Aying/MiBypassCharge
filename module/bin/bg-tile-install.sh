#!/system/bin/sh
# bg-tile-install.sh — 安装 / 补装控制中心磁贴 App
#
# 用法：bg-tile-install.sh [APK路径] [--force]
#   不给路径时按模块目录自己找；--force 表示"已经装了也覆盖装一次"（刷模块升级用）
# 输出：OK|...  /  FAIL|原因  /  NOAPK
#
# 为什么要这么多级兜底：HyperOS / MIUI 对非商店来源的 pm install 会返回
# INSTALL_FAILED_USER_RESTRICTED（"通过 USB 安装"开关），换 installer 包名
# 有时候能绕过，有时候不能。绕不过就退化成"把 APK 放到 Download，用户手点一次"，
# 并在 service.sh 里开机再试，直到装上为止。
set -u

FORCE=0
APK=""
for _a in "$@"; do
  case "$_a" in
    --force) FORCE=1 ;;
    *) [ -z "$APK" ] && APK=$_a ;;
  esac
done

PKG=com.changxyz.mibypasscharge.tile
SELF=${0%/*}
SELF=$(cd "$SELF" 2>/dev/null && pwd)

if [ -z "$APK" ] || [ ! -f "$APK" ]; then
  APK=""
  for _c in \
    "$SELF/../webroot/MiBypassChargeTile.apk" \
    /data/adb/modules/MiBypassCharge/webroot/MiBypassChargeTile.apk \
    /data/adb/modules_update/MiBypassCharge/webroot/MiBypassChargeTile.apk; do
    [ -f "$_c" ] && { APK=$_c; break; }
  done
fi
if [ -z "$APK" ]; then
  echo "NOAPK"
  exit 1
fi

if [ "$FORCE" != "1" ] && pm list packages 2>/dev/null | grep -qx "package:$PKG"; then
  echo "OK|已经装好了"
  exit 0
fi

# 先拷到 /data/local/tmp：/data/adb 是 0700，直接喂给 installd 有时会被 SELinux 拒
TMP=/data/local/tmp/mibc_tile.apk
if ! cp -f "$APK" "$TMP" 2>/dev/null; then
  echo "FAIL|拷贝 APK 失败"
  exit 1
fi
chmod 644 "$TMP" 2>/dev/null

LAST=""
for _opt in "-r -g --user 0" "-r -g" "-r -g -i com.android.vending" "-r -g -i com.miui.packageinstaller"; do
  # shellcheck disable=SC2086
  OUT=$(pm install $_opt "$TMP" 2>&1 < /dev/null)
  case "$OUT" in
    *Success*)
      rm -f "$TMP" 2>/dev/null
      echo "OK|已安装"
      exit 0
      ;;
  esac
  LAST=$OUT
done

# 全挂了：留一份到 Download 让用户手点，并写入待装标记，开机由 service.sh 再试
mkdir -p /sdcard/Download 2>/dev/null
cp -f "$TMP" /sdcard/Download/MiBypassChargeTile.apk 2>/dev/null
chmod 644 /sdcard/Download/MiBypassChargeTile.apk 2>/dev/null
mkdir -p /data/adb/MiBypassCharge 2>/dev/null
date +%s > /data/adb/MiBypassCharge/tile_apk_pending 2>/dev/null
rm -f "$TMP" 2>/dev/null
echo "FAIL|${LAST:-未知错误}"
exit 1
