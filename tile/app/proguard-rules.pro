# TileService 由 SystemUI 通过 PackageManager 反射/绑定拉起，不能被裁剪
-keep class * extends android.service.quicksettings.TileService { *; }
