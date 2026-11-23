package com.changxyz.mibypasscharge.tile;

import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
import android.util.Log;
import android.widget.Toast;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * 控制中心「旁路充电」开关。
 *
 * 两条硬约束（上一版慢就慢在这两条都没做）：
 *
 * 1) 读状态绝不起 su。
 *    /data/adb 是 0700 root-only，App 进不去，所以原来每次拉开控制中心都要
 *    fork 一次 su 去跑 bg-ctl status。KSU 管理器被划掉后 su 还要等授权应答，
 *    于是一路卡到超时。现在模块守护会把同一份 KV 复制到本 App 的私有目录
 *    （/data/data/<pkg>/files/state，644），磁贴读文件即可，0ms。
 *
 * 2) 点击绝不等于 bg-ctl on/auto。
 *    那两条命令会 sleep 3~24 秒等"物理上真的停充/真的充上"才返回。
 *    磁贴只调 bg-ctl flip：改 MODE + 戳醒守护，立刻返回，真正的动作由常驻守护做。
 *    所以整个点击路径只有一次 su，且 ~200ms 内返回。
 */
public class BypassTile extends TileService {

    private static final String TAG = "MiBypassTile";
    private static final String STATE = "state";
    private static final String RESOLVE =
            "P=/data/adb/modules/MiBypassCharge/bin/bg-ctl.sh; " +
            "[ -f \"$P\" ] || P=/data/adb/modules_update/MiBypassCharge/bin/bg-ctl.sh; " +
            "[ -f \"$P\" ] || { echo 'ERR|未安装 MiBypassCharge 模块'; exit 0; }; ";

    /**
     * 磁贴主行只写功能名，不带状态。
     * HyperOS 控制中心点磁贴时会自己弹一条「<标签>已开启 / 已关闭」的提示，
     * 标签里再写「开启/关闭」就变成「旁路充电开启已开启」，重复了。
     * 开关状态由磁贴高亮色 + 副标题表达。
     */
    private static final String LABEL = "旁路充电";

    /** 守护每 10 轮刷一次副本，超过这个时长还没更新就说明守护大概率没在跑。 */
    private static final long STALE_SEC = 900;

    /**
     * 控制中心打开期间自动补刷。
     * 刚开机时磁贴 App 可能是 service.sh 现场补装的，files/state 还没被写过，
     * 这时候状态是"还没加载出来"，不是"关掉"。以前直接把磁贴置成
     * STATE_UNAVAILABLE，而不可用的磁贴 Android 根本不会回调 onClick ——
     * 用户看到的就是「没打开 App 的情况下，磁贴点了没反应」。
     * 现在保持可点，并在面板开着的时候每秒多读几次文件，等守护把副本写出来。
     */
    private static final long REFRESH_MS = 1200;
    private static final int REFRESH_TRIES = 8;
    private int refreshLeft = 0;

    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Handler ui = new Handler(Looper.getMainLooper());
    private volatile String lastErr = "尚未初始化";

    @Override
    public void onCreate() {
        super.onCreate();
        // 自钉 oom_score_adj：HyperOS 的 freezer 会把"没有前台也没有常驻服务"
        // 的进程冻住（实测进程名变成 do_freezer_trap），冻住之后控制中心点磁贴
        // 的那一下就丢了 —— 用户看到的就是「点了没反应，尤其 App 没在后台时」。
        // 进程一起来就把自己钉成 -900（等同常驻应用），系统不再当缓存进程冻。
        // 单独开线程：su 没应答时最多卡 6 秒，绝不能挡住点击（io 是点击用的）。
        new Thread(() -> su("for p in $(pidof " + getPackageName()
                + "); do echo -900 > /proc/$p/oom_score_adj 2>/dev/null; done"),
                "tile-pin").start();
    }

    @Override
    public void onStartListening() {
        super.onStartListening();
        String st = readStateFile();   // 纯读文件，0 次 su
        applyState(st);
        if (st == null) fallbackStatus();   // 快路径拿不到才退回 su，慢也只慢这一次
        startRefreshing();
    }

    @Override
    public void onStopListening() {
        stopRefreshing();
        super.onStopListening();
    }

    private final Runnable refresher = new Runnable() {
        @Override public void run() {
            String st = readStateFile();
            if (st != null) {
                applyState(st);
                // 副本已经是守护刚写的（不是重启前的陈货），就不用再刷了
                if (!isStale(kv(st, "TS"))) { stopRefreshing(); return; }
            }
            if (--refreshLeft > 0) ui.postDelayed(this, REFRESH_MS);
        }
    };

    private void startRefreshing() {
        ui.removeCallbacks(refresher);
        refreshLeft = REFRESH_TRIES;
        ui.postDelayed(refresher, REFRESH_MS);
    }

    private void stopRefreshing() {
        refreshLeft = 0;
        ui.removeCallbacks(refresher);
    }

    /**
     * 兜底：状态副本没写进来（模块没装 / SELinux 拦了 root 写 App 目录）时，
     * 才退回到起 su 跑 status。正常情况下永远不会走到这里。
     */
    private void fallbackStatus() {
        io.execute(new Runnable() {
            @Override public void run() {
                final String out = su(RESOLVE + "sh \"$P\" status");
                final String err = pickErr(out);
                ui.post(new Runnable() {
                    @Override public void run() {
                        if (err != null) {
                            lastErr = err;
                            // 这里也绝不置 STATE_UNAVAILABLE：不可用的磁贴不回调 onClick，
                            // 而"点一下"正是触发 root 授权弹窗的唯一途径。
                            // 刚开机 / 还没授权时把它灰掉，磁贴就彻底点不动了。
                            Tile t = getQsTile();
                            if (t != null) {
                                t.setState(Tile.STATE_INACTIVE);
                                setSubtitle(t, err);
                                t.updateTile();
                            }
                        } else {
                            applyState(out);
                        }
                    }
                });
            }
        });
    }

    @Override
    public void onTileAdded() {
        super.onTileAdded();
        applyState(readStateFile());
    }

    @Override
    public void onClick() {
        super.onClick();
        if (isLocked()) {
            unlockAndRun(new Runnable() {
                @Override public void run() { flipAsync(); }
            });
            return;
        }
        flipAsync();
    }

    @Override
    public void onDestroy() {
        io.shutdownNow();
        super.onDestroy();
    }

    // ---------------- 点击：一次 su，只做 flip ----------------

    private void flipAsync() {
        final String before = readStateFile();
        /* 明确告诉后台要开还是要关，别让它按 MODE 猜。
           以前发无参 flip：界面状态和配置文件差一拍时会被判成反方向，
           表现就是"点了没反应"或"关不掉"。 */
        /* 关用的是 cancel 而不是 off：cancel = 「立即旁充」按钮那个"恢复"，
           即"原来在按阈值自动、且还没到停止值"时退回按阈值自动；
           已经是 auto 停在阈值上（MANUAL_FROM 空 / 已到停止值）时落到 force_off。
           这样磁贴的第二层语义和 WebUI 的「立即旁充」开关完全一致。 */
        final boolean wantOn = !isBypassing(before);
        applyOptimistic(before);          // 先给反馈，绝不等 su

        io.execute(new Runnable() {
            @Override public void run() {
                String out = su(RESOLVE + "sh \"$P\" flip " + (wantOn ? "on" : "cancel"));
                final String err = pickErr(out);
                final String mode = kv(out, "MODE");
                // flip 末尾自己写了状态副本，直接读回来就是真值，
                // 不必再靠 patch 猜 BP（猜错的话"auto 停在阈值上"会画错颜色）
                final String fresh = readStateFile();
                ui.post(new Runnable() {
                    @Override public void run() {
                        if (mode != null) {
                            applyState(fresh != null ? fresh : patch(before, mode));
                            /* 不再自弹 toast：HyperOS 控制中心点磁贴时自己会弹
                               「旁路充电已开启 / 已关闭」，我们再弹一条就是两条，
                               叠加起来看像「旁路充电开启已开启」。细节交给副标题。 */
                            // 守护被戳醒后还会按新 MODE 再写一轮，稍后以文件为准校正
                            ui.postDelayed(new Runnable() {
                                @Override public void run() { applyState(readStateFile()); }
                            }, 1500);
                        } else {
                            applyState(before);          // 回滚
                            toast(err != null ? err : "操作失败 · 请打开「旁路供电」授权 root");
                        }
                    }
                });
            }
        });
    }

    private void applyOptimistic(String st) {
        Tile t = getQsTile();
        if (t == null) return;
        boolean on = isBypassing(st);
        t.setState(on ? Tile.STATE_INACTIVE : Tile.STATE_ACTIVE);
        t.setLabel(LABEL);
        setSubtitle(t, on ? "正在关闭…" : "正在开启…");
        t.updateTile();
    }

    /**
     * 「正在旁充」的判据，和 WebUI 的按钮完全一致：
     *   · force_on                    —— 手动立即旁充
     *   · auto 且 BP=1                —— 按阈值自动已经充到停止值，物理上就是在旁充
     * 只看 MODE 的话，阈值自动停在 80% 时磁贴还是灰的，而 App 里按钮已经变成
     * 「现在恢复充电」，就是你说的"两边不同步"。
     */
    private static boolean isBypassing(String st) {
        if (st == null || st.isEmpty()) return false;
        String mode = kv(st, "MODE");
        if ("force_on".equals(mode)) return true;
        return "auto".equals(mode) && "1".equals(kv(st, "BP"));
    }


    // ---------------- 画磁贴 ----------------

    private void applyState(String st) {
        Tile t = getQsTile();
        if (t == null) return;

        String mode = kv(st, "MODE");
        String level = kv(st, "LEVEL");
        String onch = kv(st, "ON_CHARGER");
        String ts = kv(st, "TS");
        String lv = (level == null || level.isEmpty()) ? "--" : level;
        String tail = "";
        if (st != null && !st.isEmpty() && isStale(ts)) tail = " · 守护未运行";
        boolean plugged = "1".equals(onch);

        // 没有状态副本 ≠ 关掉：可能是刚开机守护还没写。
        // 关键是绝不置 STATE_UNAVAILABLE —— 不可用的磁贴不回调 onClick，点了就是没反应。
        if (st == null || st.isEmpty()) {
            t.setState(Tile.STATE_INACTIVE);
            t.setLabel(LABEL);
            setSubtitle(t, "正在加载状态…");
            t.updateTile();
            return;
        }

        if ("0".equals(kv(st, "ENABLED"))) {
            // 总开关在 WebUI 里，磁贴不越权替它打开，但要给一句话说明
            t.setState(Tile.STATE_INACTIVE);
            t.setLabel(LABEL);
            setSubtitle(t, "总开关未开 · 去 App 开启" + tail);
            t.updateTile();
            return;
        }

        if (isBypassing(st)) {
            t.setState(Tile.STATE_ACTIVE);
            t.setLabel(LABEL);
            String src = "force_on".equals(mode) ? "立即旁充" : "阈值 " + lv + "% 已停";
            setSubtitle(t, src + (plugged ? "" : " · 未插电") + tail);
        } else if ("force_off".equals(mode)) {
            t.setState(Tile.STATE_INACTIVE);
            t.setLabel(LABEL);
            setSubtitle(t, "正常充电 · " + lv + "%" + tail);
        } else {
            t.setState(Tile.STATE_INACTIVE);
            t.setLabel(LABEL);
            setSubtitle(t, "按阈值自动 · 到 " + lv + "% 停" + tail);
        }
        t.updateTile();
    }

    private void setSubtitle(Tile t, String s) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) t.setSubtitle(s);
    }

    private static boolean isStale(String ts) {
        if (ts == null) return false;
        try {
            long t = Long.parseLong(ts.trim());
            return (System.currentTimeMillis() / 1000L) - t > STALE_SEC;
        } catch (Exception e) {
            return false;
        }
    }

    /** 把新 MODE 打进旧的 KV 串，用于 su 刚返回、守护还没写盘的空档。 */
    private static String patch(String st, String mode) {
        if (st == null) return "MODE=" + mode;
        StringBuilder sb = new StringBuilder();
        boolean hit = false;
        for (String line : st.split("\n")) {
            if (line.startsWith("MODE=")) { sb.append("MODE=").append(mode); hit = true; }
            else sb.append(line);
            sb.append('\n');
        }
        if (!hit) sb.append("MODE=").append(mode).append('\n');
        return sb.toString();
    }

    // ---------------- 读模块写下的状态副本 ----------------

    private String readStateFile() {
        // 内部私有目录 → 外部私有目录，哪个能用读哪个
        String st = readOne(new File(getFilesDir(), STATE));
        if (st != null) return st;
        File ext = getExternalFilesDir(null);
        return ext == null ? null : readOne(new File(ext, STATE));
    }

    private String readOne(File f) {
        if (!f.exists() || !f.canRead()) return null;
        FileInputStream in = null;
        try {
            in = new FileInputStream(f);
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            byte[] buf = new byte[2048];
            int n;
            while ((n = in.read(buf)) > 0) bo.write(buf, 0, n);
            return bo.toString("UTF-8");
        } catch (Exception e) {
            Log.w(TAG, "read state", e);
            return null;
        } finally {
            if (in != null) try { in.close(); } catch (Exception ignored) {}
        }
    }

    // ---------------- su（只在点击时用一次） ----------------

    private String su(String shCmd) {
        Process p = null;
        try {
            p = new ProcessBuilder("su", "-c", shCmd).redirectErrorStream(true).start();
            StringBuilder sb = new StringBuilder();
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), "UTF-8"));
            String line;
            while ((line = r.readLine()) != null) sb.append(line).append('\n');
            r.close();
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (!p.waitFor(6, TimeUnit.SECONDS)) {
                    p.destroy();
                    return "ERR|su 超时 · root 授权没应答";
                }
            } else {
                p.waitFor();
            }
            return sb.toString();
        } catch (Exception e) {
            Log.w(TAG, "su", e);
            return "ERR|没有 root 权限 · 打开桌面「旁路供电」授权一次";
        } finally {
            if (p != null) p.destroy();
        }
    }

    private static String kv(String txt, String key) {
        if (txt == null) return null;
        String prefix = key + "=";
        for (String part : txt.split("[|\n]")) {
            String l = part.trim();
            if (l.startsWith(prefix)) return l.substring(prefix.length()).trim();
        }
        return null;
    }

    /** 注意：不能按 '|' 切分后再找 "ERR|"，那样前缀自己就被切掉了。 */
    private static String pickErr(String out) {
        if (out == null) return null;
        int i = out.indexOf("ERR|");
        if (i < 0) return null;
        String rest = out.substring(i + 4);
        int end = rest.length();
        for (int k = 0; k < rest.length(); k++) {
            char ch = rest.charAt(k);
            if (ch == '|' || ch == '\n') { end = k; break; }
        }
        String m = rest.substring(0, end).trim();
        return m.isEmpty() ? "操作失败" : m;
    }

    private void toast(String m) {
        try { Toast.makeText(this, m, Toast.LENGTH_SHORT).show(); } catch (Throwable ignored) {}
    }
}
