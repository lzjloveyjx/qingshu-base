pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // Keep local mirror priority; overseas CI can use official sources only.
        val useMirrors = providers.environmentVariable("FQAPP_USE_MAVEN_MIRRORS")
            .orNull?.equals("false", ignoreCase = true) != true
        if (useMirrors) {
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            maven { url = uri("https://maven.aliyun.com/repository/central") }
            maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
            maven { url = uri("https://maven.aliyun.com/repository/public") }
        }
        google()
        mavenCentral()
        // 【青枢】mavenCentral 在 GitHub Actions 上会被限流：
        //   429 Too Many Requests  while resolving
        //   org.jetbrains.kotlin:kotlin-gradle-plugins-bom
        // 一旦命中，Gradle 会把整个 Gradle Central Plugin Repository 标成
        // disabled，后续所有插件解析都失败，构建直接挂在 settings 第 29 行。
        // 2026-11-28 的 v2.6.0 tag 构建就是这样失败的（同代码 master 构建
        // 同一时段是成功的，纯属请求撞上限流）。
        // 换成 Google 的 Maven Central 镜像，避开与 Maven Central 共享的出口配额。
        maven {
            url = uri("https://maven-central.storage-download.googleapis.com/maven2")
        }
        gradlePluginPortal()
        // 兜底：Google 镜像若也不可达，退回阿里云（本地开发本来就走它）。
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // 对齐 Kazumi 侧的 9.3.1：9.3.3 会拒绝 flutter_inappwebview_android 1.1.3
    // 里的 getDefaultProguardFile('proguard-android.txt')（新版 AGP 只认
    // proguard-android-optimize.txt）。9.3.1 仍然接受旧写法。
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

include(":app")
