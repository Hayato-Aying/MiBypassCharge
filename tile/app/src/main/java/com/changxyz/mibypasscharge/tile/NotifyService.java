package com.changxyz.mibypasscharge.tile;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

/**
 * 充电提醒的第二个入口：由守护进程用 `am start-service` 直接拉起。
 *
 * 为什么广播不够用：HyperOS 3 / Android 16 上，App 进程落到 cached 之后，
 * 点名广播虽然被 AMS 记成 delivered（哪怕加了 --receiver-foreground），
 * 实际根本不会执行到 onReceive —— 实测 HOME 后 30 秒起，3 条广播一条都没到 App。
 * 而 root 调 am start-service 属于显式拉起，能穿透这层限制。
 *
 * 用法与广播一致：
 *   am start-service -n com.changxyz.mibypasscharge.tile/.NotifyService \
 *      -a com.changxyz.mibypasscharge.tile.NOTIFY --es text "已开启旁路供电 75%"
 *   am start-service -n com.changxyz.mibypasscharge.tile/.NotifyService \
 *      -a com.changxyz.mibypasscharge.tile.NOTIFY --ez cancel true
 */
public class NotifyService extends Service {

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        NotifyReceiver.handle(this, intent);
        stopSelf(startId);
        return START_NOT_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
