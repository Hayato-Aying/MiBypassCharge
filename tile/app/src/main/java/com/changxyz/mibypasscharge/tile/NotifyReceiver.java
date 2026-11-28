package com.changxyz.mibypasscharge.tile;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.res.Resources;
import android.os.Build;
import android.util.Log;

/**
 * 充电提醒的发射器。
 *
 * 为什么不让 shell 直接 `cmd notification post`：那条路发出的通知归属 com.android.shell，
 * 在部分 ROM（实测 Android 16 / HyperOS 3）上以 root uid 调用会被系统静默丢弃；而且
 * 小图标只能是系统那套灰图，看着不像本模块。改成由本 App 发，通知自动带 App 图标，
 * 点一下还能直接打开面板。
 *
 * 触发方式（守护进程是 root，用显式广播绕过 Android 8+ 的隐式广播限制）：
 *   am broadcast -n com.changxyz.mibypasscharge.tile/.NotifyReceiver \
 *      -a com.changxyz.mibypasscharge.tile.NOTIFY --es text "已开启旁路电量 75%"
 *
 * 只用 getIdentifier 取图标，不引用 R 类 —— build-app.sh 是 aapt2 手工链，没生成 R.java，
 * 这样不用改构建脚本也不会编译失败。
 */
public class NotifyReceiver extends BroadcastReceiver {

    public static final String ACTION = "com.changxyz.mibypasscharge.tile.NOTIFY";
    public static final String EXTRA_TEXT = "text";
    /** 收通知用：`am broadcast ... --ez cancel true`。 */
    public static final String EXTRA_CANCEL = "cancel";

    private static final String TAG = "BypassNotify";
    private static final String CHANNEL_ID = "bypass_charge";
    private static final String CHANNEL_NAME = "旁路供电";
    /** 固定 id：新提醒覆盖旧提醒，和原来 shell 那条共用一个 tag 的行为一致。 */
    private static final int NOTI_ID = 0x4D42;

    private static void dbg(Context ctx, String msg) {
        try {
            java.io.File dir = ctx.getExternalFilesDir(null);
            if (dir == null) return;
            java.io.FileWriter w = new java.io.FileWriter(new java.io.File(dir, "nr.log"), true);
            w.write(new java.text.SimpleDateFormat("HH:mm:ss").format(new java.util.Date()) + " " + msg + "\n");
            w.close();
        } catch (Throwable ignored) {
        }
    }

    @Override
    public void onReceive(Context ctx, Intent intent) {
        dbg(ctx, "onReceive cancel=" + (intent != null && intent.getBooleanExtra(EXTRA_CANCEL, false))
                + " text=" + (intent == null ? null : intent.getStringExtra(EXTRA_TEXT)));
        handle(ctx, intent);
    }

    /** 广播和前台服务共用这一套逻辑：后台 App 收不到广播时改走 am start-service。 */
    public static void handle(Context ctx, Intent intent) {
        if (ctx == null || intent == null) return;
        if (intent.getBooleanExtra(EXTRA_CANCEL, false)) {
            try {
                NotificationManager nm =
                        (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
                if (nm != null) nm.cancel(NOTI_ID);
            } catch (Throwable t) {
                Log.w(TAG, "cancel failed: " + t);
            }
            return;
        }
        String text = intent.getStringExtra(EXTRA_TEXT);
        if (text == null) text = intent.getStringExtra("message");
        if (text == null || text.trim().isEmpty()) return;
        try {
            post(ctx, text.trim());
            dbg(ctx, "posted ok");
        } catch (Throwable t) {
            // 通知发不出去绝不能把广播进程带崩
            Log.w(TAG, "post failed: " + t);
            dbg(ctx, "post failed: " + t);
        }
    }

    private static void post(Context ctx, String text) {
        NotificationManager nm =
                (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) return;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel ch = new NotificationChannel(
                    CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW);
            // 充电提醒是"看一眼就行"的信息，不响不震不挂角标
            ch.setShowBadge(false);
            ch.enableVibration(false);
            ch.setSound(null, null);
            ch.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
            nm.createNotificationChannel(ch);
        }

        Notification.Builder b = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                ? new Notification.Builder(ctx, CHANNEL_ID)
                : new Notification.Builder(ctx);
        b.setContentTitle(CHANNEL_NAME)
                .setContentText(text)
                .setStyle(new Notification.BigTextStyle().bigText(text))
                .setAutoCancel(true)
                .setShowWhen(true)
                .setWhen(System.currentTimeMillis());
        int icon = smallIcon(ctx);
        if (icon != 0) b.setSmallIcon(icon);
        // 低版本没有渠道静音，逐个通知关掉声音振动
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            b.setDefaults(0);
        }
        try {
            Intent open = new Intent(ctx, MainActivity.class);
            open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags |= PendingIntent.FLAG_IMMUTABLE;
            }
            b.setContentIntent(PendingIntent.getActivity(ctx, 0, open, flags));
        } catch (Throwable ignored) {
            // 没有 PendingIntent 也照样把通知发出去
        }

        nm.notify(NOTI_ID, b.build());
    }

    /** ic_tile 是纯白矢量，正好符合通知小图标的单色要求。 */
    private static int smallIcon(Context ctx) {
        try {
            Resources r = ctx.getResources();
            String pkg = ctx.getPackageName();
            int id = r.getIdentifier("ic_tile", "drawable", pkg);
            if (id == 0) id = r.getIdentifier("ic_launcher_fg", "drawable", pkg);
            return id;
        } catch (Throwable t) {
            return 0;
        }
    }
}
