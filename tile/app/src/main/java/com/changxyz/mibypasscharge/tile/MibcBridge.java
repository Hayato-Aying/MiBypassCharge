package com.changxyz.mibypasscharge.tile;

import android.app.Activity;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;
import android.widget.Toast;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.Charset;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;

/**
 * window.ksu 桥 —— 让模块原来的 WebUI 一行不改就能跑在本 App 的 WebView 里。
 *
 * 契约（照抄 KernelSU 的 ksu webui 注入）：
 *   exec(cmd, cbName)  异步：跑完后调 window[cbName](errno, stdout)
 *   exec(cmd)          同步：只回 stdout 的最后一行（WebUI 在 20s 超时时才用它兜底）
 *   toast(msg)         系统 Toast
 *   isApp()            本 App 专有，WebUI 用它区分"磁贴内嵌"和"KSU 管理器里"
 *
 * 命令一律经 su 执行，和桌面图标时代完全一致；root 授权被拒就返回 errno!=0，
 * WebUI 那边会显示"状态读取失败"，不会假装成功。
 */
public class MibcBridge {

    private static final String TAG = "MibcBridge";
    private static final Pattern SAFE_CB = Pattern.compile("[A-Za-z0-9_$]{1,64}");
    private static final Charset UTF8 = Charset.forName("UTF-8");

    /** WebUI 偶尔会连着发好几条（改阈值连发两条 set），串行执行最简单也最稳。 */
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final WebView web;
    private final ToastHolder toasts = new ToastHolder();

    /** 同步 exec 的等待上限。比 WebUI 的 20s 兜底短，保证它拿得到结果。 */
    private static final long SYNC_TIMEOUT_MS = 15000;
    /** 异步 exec 的上限。bg-ctl on/auto 最坏要睡 24s 等物理停充。 */
    private static final long ASYNC_TIMEOUT_MS = 45000;

    public MibcBridge(WebView web) {
        this.web = web;
    }

    @JavascriptInterface
    public boolean isApp() {
        return true;
    }

    @JavascriptInterface
    public String version() {
        return BuildConfigBridge.VERSION;
    }

    /** 异步：WebUI 的主路径。 */
    @JavascriptInterface
    public void exec(final String cmd, final String cbName) {
        if (cbName == null || !SAFE_CB.matcher(cbName).matches()) {
            Log.w(TAG, "reject callback name: " + cbName);
            return;
        }
        io.execute(new Runnable() {
            @Override public void run() {
                final Result r = runSu(cmd, ASYNC_TIMEOUT_MS, true);
                final String js = "window['" + cbName + "'] && window['" + cbName + "']("
                        + r.errno + "," + JSONObject.quote(r.stdout) + ")";
                ui.post(new Runnable() {
                    @Override public void run() {
                        try { web.evaluateJavascript(js, null); }
                        catch (Exception e) { Log.w(TAG, "callback", e); }
                    }
                });
            }
        });
    }

    /** 同步：只在 WebUI 的 20s 兜底路径里用到，返回最后一行（和 KSU 行为一致）。 */
    @JavascriptInterface
    public String exec(final String cmd) {
        Result r = runSu(cmd, SYNC_TIMEOUT_MS, false);
        String out = r.stdout;
        if (out.isEmpty()) return "";
        int i = out.length();
        while (i > 0 && (out.charAt(i - 1) == '\n' || out.charAt(i - 1) == '\r')) i--;
        int s = out.lastIndexOf('\n', i - 1);
        return out.substring(s + 1, i);
    }

    @JavascriptInterface
    public void toast(final String msg) {
        if (msg == null || msg.isEmpty()) return;
        final String text = msg.length() > 400 ? msg.substring(0, 400) : msg;
        ui.post(new Runnable() {
            @Override public void run() { toasts.show(text); }
        });
    }

    /** 关掉 Activity 时调用：不再往已经销毁的 WebView 里回注 JS。 */
    public void shutdown() {
        io.shutdownNow();
    }

    // ---------------- 执行 ----------------

    private static final class Result {
        final int errno;
        final String stdout;
        Result(int e, String s) { errno = e; stdout = s; }
    }

    /**
     * mergeStderr=true：WebUI 的 sh() 只读 stdout，把 stderr 并进来看得到 su 的拒绝原因。
     * 同步路径不合并，避免最后一行被报错信息污染。
     */
    private Result runSu(String cmd, long timeoutMs, boolean mergeStderr) {
        if (cmd == null) cmd = "";
        cmd = cmd.trim();
        if (cmd.isEmpty()) return new Result(1, "");
        Process p = null;
        try {
            ProcessBuilder pb = new ProcessBuilder("su", "-c", cmd);
            if (mergeStderr) pb.redirectErrorStream(true);
            p = pb.start();
            StringBuilder sb = new StringBuilder();
            BufferedReader br = new BufferedReader(new InputStreamReader(p.getInputStream(), UTF8));
            String line;
            long deadline = System.currentTimeMillis() + timeoutMs;
            int shown = 0;
            while ((line = br.readLine()) != null) {
                sb.append(line).append('\n');
                if (++shown > 4000) { sb.append("...(输出过长已截断)\n"); break; }
                if (System.currentTimeMillis() > deadline) {
                    return new Result(124, sb + "ERR|命令超时（su 或脚本卡住）\n");
                }
            }
            br.close();
            int code;
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                long left = deadline - System.currentTimeMillis();
                if (!p.waitFor(Math.max(left, 200), TimeUnit.MILLISECONDS)) {
                    p.destroy();
                    return new Result(124, sb + "ERR|命令超时\n");
                }
                code = p.exitValue();
            } else {
                code = p.waitFor();
            }
            String out = sb.toString();
            if (code != 0 && out.trim().isEmpty()) {
                out = "ERR|命令失败 exit=" + code + "\n";
            }
            return new Result(code, out);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return new Result(130, "ERR|已取消\n");
        } catch (Exception e) {
            Log.w(TAG, "su failed", e);
            return new Result(126, "ERR|无法执行 root 命令：" + e.getMessage() + "\n");
        } finally {
            if (p != null) {
                try { p.getInputStream().close(); } catch (Exception ignored) {}
                try { p.getErrorStream().close(); } catch (Exception ignored) {}
                try { p.getOutputStream().close(); } catch (Exception ignored) {}
                p.destroy();
            }
        }
    }

    /** Toast 复用同一个对象，免得 WebUI 连点三下排三个队。 */
    private final class ToastHolder {
        private Toast cur;
        void show(String text) {
            if (cur != null) cur.cancel();
            Activity a = (web.getContext() instanceof Activity) ? (Activity) web.getContext() : null;
            cur = (a != null) ? Toast.makeText(a, text, Toast.LENGTH_SHORT)
                              : Toast.makeText(web.getContext(), text, Toast.LENGTH_SHORT);
            try { cur.show(); } catch (Exception ignored) {}
        }
    }
}
