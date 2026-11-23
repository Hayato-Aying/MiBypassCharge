plugins {
    id("com.android.application")
}

// 无界面伴生 APK：只有一个 TileService，复用模块的 bg-ctl.sh 状态机。
// 没有 androidx、没有 Kotlin stdlib，dex 只有几 KB。
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
