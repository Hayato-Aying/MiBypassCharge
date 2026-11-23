plugins {
    id("com.android.application")
}

// 控制中心磁贴 APK：MainActivity 是 WebUI 的宿主（桌面图标、磁贴长按都进它），
// TileService 是磁贴本身，复用模块的 bg-ctl.sh 状态机。
// 没有 androidx、没有 Kotlin stdlib，dex 只有几 KB。
// 版本号不在这里写死：build-app.sh 用 module/module.prop 的 version/versionCode
// 覆盖（下面的 1 / "1.0" 只在直接跑 Gradle 时才生效）。
android {
    namespace = "com.changxyz.mibypasscharge.tile"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.changxyz.mibypasscharge.tile"
        minSdk = 24          // TileService 从 24 才有
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
