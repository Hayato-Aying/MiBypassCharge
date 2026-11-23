#!/usr/bin/env bash
# 打包模块：读 module/module.prop 的 version，生成 MiBypassCharge-<版本>.zip
set -e
cd "$(dirname "$0")"

VER=$(awk -F= '/^version=/{print $2}' module/module.prop | tr -d '\r')
[ -n "$VER" ] || { echo "读不到版本号"; exit 1; }
OUT="MiBypassCharge-${VER}.zip"
[ -f "$OUT" ] && rm -f "$OUT"

python - "$OUT" "$VER" <<'PY'
import os, re, sys, zipfile, hashlib
out = sys.argv[1]
ver = sys.argv[2]
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'module')

# 版本号唯一来源是 module/module.prop：同步写进 WebUI 底部那行注入值
_idx = os.path.join(root, 'webroot', 'index.html')
if os.path.exists(_idx):
    _txt = open(_idx, encoding='utf-8').read()
    _new = re.sub(r'window\.__BG_VER__ = "[^"]*"',
                  'window.__BG_VER__ = "%s"' % ver.lstrip('v'), _txt)
    if _new != _txt:
        open(_idx, 'w', encoding='utf-8').write(_new)
        print('WebUI 版本 ->', ver.lstrip('v'))
README = """MiBypassCharge — 旁路供电守护 (K70)
版本: %s

插电后充到设定电量就停充，手机改由适配器直供（电池 0W），
低于恢复点再继续充。停充走小米官方 smart_chg 位，
与安全中心「导航断充保护」同款，驱动自保持，拔插不丢。

KernelSU 模块，纯脚本 + WebUI，不安装任何 App。
适配 Redmi K70（vermeer / HyperOS 2 / Android 15）；其他机型未测试。

开源地址: https://github.com/ChangXYZ-CPU/MiBypassCharge
使用说明 / 更新日志 / 免责声明见仓库 README.md 与 DISCLAIMER.md。

修改系统充电行为有风险，请自行承担。安装前请备份数据。
""" % ver
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for dp, dn, fns in os.walk(root):
        for fn in fns:
            p = os.path.join(dp, fn)
            z.write(p, os.path.relpath(p, root).replace('\\', '/'))
    z.writestr('README.txt', README.encode('utf-8'))
with zipfile.ZipFile(out) as z:
    bad = [n for n in z.namelist() if n.endswith(('.sh', '.prop', '.html', '.css')) and b'\r\n' in z.read(n)]
    print('文件数:', len(z.namelist()))
    if bad:
        print('!! 含 CRLF，mksh 会报错:', bad); sys.exit(1)
d = open(out, 'rb').read()
print('输出:', out, len(d), 'bytes')
print('MD5 :', hashlib.md5(d).hexdigest())
PY
