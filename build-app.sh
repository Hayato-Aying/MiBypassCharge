#!/bin/bash
# 构建控制中心磁贴 APK（aapt2 + javac + d8 + apksigner，不依赖 Gradle）
#
# 需要：
#   ANDROID_JAR  android.jar（API 34，例如 $ANDROID_HOME/platforms/android-34/android.jar）
#   D8_JAR       d8.jar（build-tools 里的 lib/d8.jar）
#   zipalign / apksigner / keytool 在 PATH 里
#   JDK 17
#
# 产物：tile/build/MiBypassChargeTile.apk，并自动复制到 module/webroot/（刷模块时随包安装）
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
: "${ANDROID_JAR:?请先 export ANDROID_JAR=/path/to/android.jar}"
: "${D8_JAR:?请先 export D8_JAR=/path/to/d8.jar}"
KS=${KS:-$ROOT/tile/keystore.jks}
KS_PASS=${KS_PASS:-android}
OUT=$ROOT/tile/build

cd "$ROOT/tile"
rm -rf "$OUT"; mkdir -p "$OUT/res" "$OUT/classes" "$OUT/dex" "$OUT/src"

# 版本号的唯一来源是 module/module.prop：同时写进 manifest 和 BuildConfigBridge，
# 免得 App 里显示的版本和模块版本对不上（以前这里漏了，界面上永远显示 1.0）。
VER=$(sed -n 's/^version=//p' "$ROOT/module/module.prop" 2>/dev/null | head -1)
VCODE=$(sed -n 's/^versionCode=//p' "$ROOT/module/module.prop" 2>/dev/null | head -1)
cp -a app/src/main/java/. "$OUT/src/"
if [ -n "$VER" ]; then
  BC="$OUT/src/com/changxyz/mibypasscharge/tile/BuildConfigBridge.java"
  sed -i "s|static final String VERSION = \".*\";|static final String VERSION = \"$VER\";|" "$BC"
  grep -q "VERSION = \"$VER\"" "$BC" || { echo "!! BuildConfigBridge 版本写入失败"; exit 1; }
fi

# 模块 WebUI 打进 APK assets：App 用 file:///android_asset/webroot/index.html 加载。
# 用内嵌副本而不是读 /data/adb —— 那是 0700 root-only，App 的 uid 进不去。
ASSETS=$ROOT/tile/app/src/main/assets
rm -rf "$ASSETS"; mkdir -p "$ASSETS/webroot"
cp -a "$ROOT/module/webroot/." "$ASSETS/webroot/"
rm -f "$ASSETS/webroot/MiBypassChargeTile.apk"

aapt2 compile --dir app/src/main/res -o "$OUT/res"
aapt2 link -o "$OUT/base.apk" -I "$ANDROID_JAR" \
  --manifest app/src/main/AndroidManifest.xml \
  -A "$ASSETS" \
  ${VCODE:+--version-code "$VCODE"} ${VER:+--version-name "$VER"} \
  --min-sdk-version 24 --target-sdk-version 34 "$OUT"/res/*.flat

javac -source 17 -target 17 -Xlint:-options -encoding UTF-8 \
  -classpath "$ANDROID_JAR" -d "$OUT/classes" $(find "$OUT/src" -name '*.java')

java -cp "$D8_JAR" com.android.tools.r8.D8 --min-api 24 --output "$OUT/dex" \
  $(find "$OUT/classes" -name '*.class')

cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q ../unsigned.apk classes.dex)
zipalign -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -alias tile -keyalg RSA -keysize 2048 -validity 10000 \
    -dname 'CN=MiBypassCharge Tile, O=ChangXYZ, C=CN' >/dev/null 2>&1
fi
apksigner sign --ks "$KS" --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
  --ks-key-alias tile --min-sdk-version 24 \
  --out "$OUT/MiBypassChargeTile.apk" "$OUT/aligned.apk"

cp "$OUT/MiBypassChargeTile.apk" "$ROOT/module/webroot/MiBypassChargeTile.apk"
echo "版本: ${VER:-<manifest>} (${VCODE:-?})"
ls -l "$OUT/MiBypassChargeTile.apk"
