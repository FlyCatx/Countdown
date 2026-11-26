plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.countdown.countdown_app"
    // 目标编译版本固定为 36，host 只使用平台 API 与 AndroidX Core，不跟踪 Flutter 的默认值变化。
    compileSdk = 36
    // 本项目没有 C/C++ 源码或 native 依赖，不声明 ndkVersion：
    // 声明后 AGP 会要求本机安装约 1 GB 的对应 NDK，而构建与运行都用不到。

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.countdown.countdown_app"
        // 产品基线是 Android 7.0（API 24）：不能为编译方便抬高最低版本。
        minSdk = 24
        targetSdk = 36
        // 版本号来自 pubspec.yaml 的 version 字段（构建号）；Flutter 的 split APK 会另加
        // 1000 * ABI 后缀，需要强制使用原值时加 -P force-version-code-ignoring-abi=true。
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 发布签名需用户确认；当前沿用调试签名，保证侧载覆盖安装时数据可延续。
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 仅用于 NotificationCompat / NotificationManagerCompat / ContextCompat，不引入其它第三方库。
    implementation("androidx.core:core-ktx:1.13.1")
}

flutter {
    source = "../.."
}
