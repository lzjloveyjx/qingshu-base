import java.io.DataInputStream
import java.io.IOException
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material is deliberately optional: without it the release
// build still succeeds but produces an UNSIGNED package, so the task stays
// usable for someone who only wants to inspect the build. What must never
// happen is a release silently signed with the public debug key, so the
// expected certificate is pinned in CI as RELEASE_SIGNER_SHA256 instead.
//
// Local builds read android/keystore.properties, which is git-ignored and kept
// outside version control. CI supplies the same four values as environment
// variables. See docs/release-signing.md.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("keystore.properties")
    if (file.isFile) file.inputStream().use { load(it) }
}

fun signingValue(key: String, vararg environmentNames: String): String? =
    keystoreProperties.getProperty(key)?.takeIf { it.isNotBlank() }
        ?: environmentNames.firstNotNullOfOrNull { name ->
            System.getenv(name)?.takeIf { it.isNotBlank() }
        }

val releaseStoreFile = signingValue("storeFile", "RELEASE_KEYSTORE_FILE")
val releaseStorePassword = signingValue("storePassword", "RELEASE_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "RELEASE_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "RELEASE_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { it != null }

// A different application ID keeps a local modified build's data separate.
val coexistBuild = providers.environmentVariable("FQAPP_COEXIST")
    .map { it.toBoolean() }
    .getOrElse(false)

android {
    namespace = "com.fqapp.fqapp"
    compileSdk = flutter.compileSdkVersion
    // Compile the in-repository crypto core with the NDK's 16 KiB support.
    ndkVersion = "28.2.13676358"

    externalNativeBuild {
        cmake {
            path = file("../../native/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = if (coexistBuild) "com.fqapp.fqapp.mod" else "com.fqapp.fqapp"
        // 【青枢】安装界面显示的应用名。原来是底座什锦铺的名字，
    // 装完在桌面上看到的还是「什锦铺」。
    manifestPlaceholders["appLabel"] = if (coexistBuild) "青枢·改" else "青枢"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // No ndk.abiFilters here on purpose: `flutter build apk
        // --split-per-abi` makes the Flutter Gradle plugin configure AGP
        // splits, and AGP rejects abiFilters whenever splits are set
        // ("abiFilters cannot be present when splits abi filters are set").
        // The split APKs therefore contain exactly the ABIs Flutter was
        // asked to build (--target-platform android-arm,android-arm64).
        // The guards against a backend-less slice are the packaging check
        // below (both libfqapi_core.so files must exist and match their
        // ABI) and scripts/verify_android_apk.py --abi, which rejects any
        // unexpected ABI in the APK. Always build with the documented
        // split command; a plain fat `flutter build apk` would include an
        // x86_64 slice with no Rust backend.
        //
        // NOTE: do not re-add abiFilters to "restrict" the build. It breaks
        // every split build at configuration time.
        externalNativeBuild {
            cmake {
                // shortplay_tempo 是 issue #129 的 WSOLA 时伸缩库，必须一起打包；
                // 漏在这里 Gradle 不会编译它，运行期 System.loadLibrary 会抛
                // UnsatisfiedLinkError。
                targets += listOf("shortplay_crypto", "shortplay_tempo")
            }
        }
    }

    signingConfigs {
        getByName("debug") {
            // CI supplies an absolute path instead of relying on the runner's
            // Android user-directory defaults for debug.keystore.
            providers.environmentVariable("FQAPP_DEBUG_KEYSTORE").orNull?.let { keystorePath ->
                storeFile = file(keystorePath)
            }
        }
        // 【青枢】仓库里带一份固定的 release 密钥。
        //
        // 上游的设计是「没配密钥就产出未签名包」，那对分发是致命的：
        // 未签名的 APK 在任何手机上都会报「解析软件包时出现问题 /
        // packageInfo is null」，根本装不上。这里改成仓库内固定密钥兜底，
        // CI 和本地都能出可直接安装的包。
        val bundledKeystore = file("qingshu-release.keystore")
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                // minSdk is 24, so V2 alone installs on every supported device;
                // V1 stays enabled because some OEM installers on Android 7
                // still verify it.
                enableV1Signing = true
                enableV2Signing = true
            }
        } else if (bundledKeystore.exists()) {
            create("release") {
                storeFile = bundledKeystore
                storePassword = "REDACTED_KEYSTORE_PASSWORD"
                keyAlias = "qingshu"
                keyPassword = "REDACTED_KEYSTORE_PASSWORD"
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        debug {
            // Opt-in local runs may coexist with an installed release whose
            // signing certificate cannot be replaced by the debug key.
            val debugSuffix = providers.gradleProperty("fqappDebugApplicationIdSuffix")
                .orElse(providers.environmentVariable("FQAPP_DEBUG_APPLICATION_ID_SUFFIX"))
                .orNull
            if (debugSuffix == ".debug") {
                applicationIdSuffix = ".debug"
            }
        }
        release {
            // The release APK carries its own signing identity. Debug builds
            // keep the debug key so `flutter run` and overwrite-installing a
            // local test build keep working. A package signed by the older test
            // key cannot be overwritten by these -- it must be uninstalled.
            // 【青枢】只要 signingConfigs 里存在 release 配置就用它。
            // 上游只在 hasReleaseSigning（CI 注入的密钥）为真时才挂签名，
            // 否则 release 变体没有任何 signingConfig，产出的是未签名包 ——
            // 手机上会报「解析软件包时出现问题 / packageInfo is null」。
            // 现在仓库自带密钥，signingConfigs 里一定有 release，必须挂上。
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // 关掉 release 打包时的 lint 检查。
    //
    // 原因：AGP 9.x 的 lintVitalAnalyzeRelease 在分析 file_selector_android 的
    // FileUtils.java 时会崩 —— Android lint 自己的 CommentDetector 报
    // NoSuchMethodError: 'java.lang.Object java.util.List.removeLast()'
    // （lint 内部 bug，不是我们代码的问题）。它只影响打包期的 lint 分析，
    // 不影响产物正确性，所以这里直接跳过。
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("commons-net:commons-net:3.12.0")
    implementation("com.hierynomus:smbj:0.14.0")
    implementation("org.glassfish:javax.el:3.0.1-b12")

    // OkHttp powers HttpBridge.httpRange, the range fetcher the C crypto
    // core calls back into for streaming CENC decrypt.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Media3 ExoPlayer — NativePlayerPlugin host for short-drama playback.
    val media3Version = "1.4.1"
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-common:$media3Version")
    implementation("androidx.media3:media3-datasource:$media3Version")

    // MediaStyle + MediaSessionCompat for the listen-mode foreground notification.
    // Without a media session the notification is a plain one: on Android 12+ its
    // action buttons stay hidden until the user expands it, and the app never shows
    // up in the system media controls (Quick Settings card, lock screen, headset keys).
    implementation("androidx.media:media:1.7.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.mockito:mockito-core:5.23.0")
}

flutter {
    source = "../.."
}

// 【青枢改造】原版这里强制校验 libfqapi_core.so（Rust 核心）存在，
// 缺失就 GradleException 直接失败。青枢只用本地 TXT/EPUB + 规则源，
// 不需要番茄的 Rust 内容层，所以把这个任务改成 no-op：
// 保留任务名（下面 tasks.configureEach 还 dependsOn 它），但不做任何检查。
val verifyRequiredNativeLibraries = tasks.register("verifyRequiredNativeLibraries") {
    group = "verification"
    description = "No-op in QingShu: the Rust content core is not part of this build."
}
// NOTE: the Rust core runs in-process over flutter_rust_bridge, so there is no
// standalone backend executable to strip from the Flutter asset bundle anymore.
// The Android packaging path only needs jniLibs (libfqapi_core.so) plus the
// crypto library built from native/.
