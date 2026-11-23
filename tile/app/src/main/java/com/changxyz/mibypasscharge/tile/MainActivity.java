package com.changxyz.mibypasscharge.tile;

import android.app.Activity;
import android.content.ComponentName;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.service.quicksettings.TileService;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.ConsoleMessage;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * App 就是模块 WebUI 的宿主。
 *
 * 原来桌面图标只用来"点一次拿 root 授权"，界面还在 KSU 管理器的 WebUI 里，
 * 两个入口两套 UI。现在把模块 webroot 打进 APK 的 assets，用 WebView 加载，
 * 通过 MibcBridge 假装成 window.ksu —— index.html 一行不用改就能同时跑在
 * KSU 管理器和这里。
 *
 * 为什么不直接读 /data/adb 里的 webroot：那个目录是 0700 root-only，
 * App 的 uid 根本进不去，所以只能打包内副本（刷模块时 APK 和 webroot 同一个 zip，
 * 版本天然一致），WebUI 里的实时数据全部走 su 现读，不依赖文件是否新。
 */
public class MainActivity extends Activity {

    /** assets 里的入口。webroot/ 由构建脚本从 src/webroot 复制过来。 */
    private static final String HOME = "file:///android_asset/webroot/index.html";

    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Handler ui = new Handler(Looper.getMainLooper());

    private WebView web;
    private MibcBridge bridge;
    private LinearLayout gate;
    private TextView gateText;
    private Button gateBtn;
    private volatile boolean pageLoaded = false;
    private volatile boolean destroyed = false;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.parseColor("#0a0a0c"));

        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#0a0a0c"));
        root.addView(web, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        gate = buildGate();
        root.addView(gate, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        setContentView(root);

        try {
            getWindow().setStatusBarColor(Color.parseColor("#0a0a0c"));
            getWindow().setNavigationBarColor(Color.parseColor("#0a0a0c"));
        } catch (Throwable ignored) {
        }

        setupWebView();
        checkRoot();
    }

    private LinearLayout buildGate() {
        int pad = dp(24);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setGravity(Gravity.CENTER);
        box.setPadding(pad, pad, pad, pad);
        box.setBackgroundColor(Color.parseColor("#0a0a0c"));

        ProgressBar pb = new ProgressBar(this);
        box.addView(pb, lp(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, true));

        gateText = new TextView(this);
        gateText.setText("正在申请 root 权限…\n首次使用会在 KernelSU / Magisk 里弹出授权窗，请点「允许」。");
        gateText.setTextColor(Color.parseColor("#c7c7cc"));
        gateText.setTextSize(14);
        gateText.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams tl = lp(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT, true);
        tl.topMargin = dp(16);
        box.addView(gateText, tl);

        gateBtn = new Button(this);
        gateBtn.setText("重新申请");
        gateBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { checkRoot(); }
        });
        LinearLayout.LayoutParams bl = lp(ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT, true);
        bl.topMargin = dp(12);
        box.addView(gateBtn, bl);

        gateBtn.setVisibility(View.GONE);
        return box;
    }

    private LinearLayout.LayoutParams lp(int w, int h, boolean center) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(w, h);
        if (center) p.gravity = Gravity.CENTER_HORIZONTAL;
        return p;
    }

    private void setupWebView() {
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(false);
        s.setTextZoom(100);
        s.setMediaPlaybackRequiresUserGesture(true);

        bridge = new MibcBridge(web);
        // 必须在 loadUrl 之前注入，否则 index.html 里的 window.ksu 判断会走空
        web.addJavascriptInterface(bridge, "ksu");

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest req) {
                // 内嵌 UI 不外跳，所有链接都当无效处理
                String u = req.getUrl() == null ? "" : req.getUrl().toString();
                return !u.startsWith("file://");
            }

            @Override
            public void onPageFinished(WebView v, String url) {
                ui.postDelayed(new Runnable() {
                    @Override public void run() {
                        if (!destroyed) gate.setVisibility(View.GONE);
                    }
                }, 120);
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage m) {
                return true;   // 静默：不弹 JS 错误对话框，也不污染 logcat
            }
        });
    }

    /** root 通不过就别加载页面：WebUI 一上来要跑好几条 su，全失败只会显示一堆报错。 */
    private void checkRoot() {
        gate.setVisibility(View.VISIBLE);
        gateBtn.setVisibility(View.GONE);
        gateText.setText("正在申请 root 权限…\n首次使用会在 KernelSU / Magisk 里弹出授权窗，请点「允许」。");
        io.execute(new Runnable() {
            @Override public void run() {
                final String out = probe();
                ui.post(new Runnable() {
                    @Override public void run() {
                        if (destroyed) return;
                        if (out == null) {
                            gateBtn.setVisibility(View.VISIBLE);
                            gateText.setText("拿不到 root。\n\n请在 KernelSU / Magisk 管理器里给「旁路供电」授权，然后点下面的按钮重试。");
                            return;
                        }
                        if (!out.contains("OK")) {
                            gateBtn.setVisibility(View.VISIBLE);
                            gateText.setText("root 已授权，但没找到模块脚本。\n\n请先在 KernelSU / Magisk 里刷入 MiBypassCharge 模块并重启。\n\n" + out);
                            return;
                        }
                        try {
                            TileService.requestListeningState(MainActivity.this,
                                    new ComponentName(MainActivity.this, BypassTile.class));
                        } catch (Throwable ignored) {
                        }
                        openPage();
                    }
                });
            }
        });
    }

    /** 一条命令同时验 root 和模块存在，省一次 su 的开销。 */
    private String probe() {
        return runOnce("su -c 'u=$(id -u 2>/dev/null); f=/data/adb/modules/MiBypassCharge/bin/bg-ctl.sh; "
                + "g=/data/adb/modules_update/MiBypassCharge/bin/bg-ctl.sh; "
                + "if [ \"$u\" = 0 ] && { [ -f \"$f\" ] || [ -f \"$g\" ]; }; then echo OK; "
                + "elif [ \"$u\" = 0 ]; then echo NOMODULE; else echo NOROOT; fi'");
    }

    private void openPage() {
        if (pageLoaded) {
            gate.setVisibility(View.GONE);
            return;
        }
        pageLoaded = true;
        web.loadUrl(HOME);
    }

    /** 从最近任务/磁贴长按回到前台时，让页面立刻刷新一次而不是等 3 秒。 */
    @Override
    protected void onResume() {
        super.onResume();
        if (pageLoaded && web != null) {
            ui.postDelayed(new Runnable() {
                @Override public void run() {
                    if (!destroyed && web != null) web.evaluateJavascript(
                            "window.__bgWake && window.__bgWake()", null);
                }
            }, 150);
        }
    }

    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) web.goBack();
        else super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        destroyed = true;
        io.shutdownNow();
        if (bridge != null) bridge.shutdown();
        if (web != null) {
            try {
                web.loadUrl("about:blank");
                web.destroy();
            } catch (Throwable ignored) {
            }
            web = null;
        }
        super.onDestroy();
    }

    private String runOnce(String cmd) {
        Process p = null;
        try {
            p = new ProcessBuilder("sh", "-c", cmd).redirectErrorStream(true).start();
            java.io.BufferedReader r = new java.io.BufferedReader(
                    new java.io.InputStreamReader(p.getInputStream(), "UTF-8"));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) sb.append(line).append(' ');
            r.close();
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                // 授权弹窗要等人点，给足时间；超时也不能把界面卡死
                if (!p.waitFor(30, java.util.concurrent.TimeUnit.SECONDS)) {
                    p.destroy();
                    return null;
                }
            } else {
                p.waitFor();
            }
            return sb.toString().trim();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return null;
        } catch (Exception e) {
            return null;
        } finally {
            if (p != null) p.destroy();
        }
    }

    private int dp(float v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
