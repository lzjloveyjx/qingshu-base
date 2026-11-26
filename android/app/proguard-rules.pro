# R8 keep rules for the JNI contracts and the Flutter embedding.
#
# The bundled native libraries resolve Java symbols by NAME, so obfuscation
# breaks them at runtime with an UnsatisfiedLinkError -- the build still
# succeeds, which is why these keeps are written out explicitly rather than
# relying on the transitive consumer rules that androidx.annotation ships for
# @Keep. A JNI contract must not depend on an indirect dependency.
#
# The Rust core (libfqapi_core.so) has NO Java JNI surface: Flutter reaches it
# through flutter_rust_bridge over dart:ffi, so no keep rule is needed for it.

# --- libshortplay_crypto.so (native/android/jni_bridge.c) ----------------
# Exports Java_com_example_shortplay_CryptoNative_*. The package name is part
# of the exported symbol, so it must survive obfuscation.
-keep class com.example.shortplay.CryptoNative { *; }

# jni_bridge.c resolves these five static methods on the class handed to
# nativeInit() through GetStaticMethodID, i.e. by the literal strings
# "httpSize", "streamPrepare", "streamConnect", "streamRead", "streamClose".
# Renaming or changing any signature makes nativeInit fail with
# "HttpBridge does not implement the native streaming I/O contract".
-keep class com.example.shortplay.HttpBridge { *; }

# --- generic JNI safety net ---------------------------------------------
# Keeps the class and method name of every native method, which is what the
# JNI naming convention depends on.
-keepclasseswithmembernames class * {
    native <methods>;
}

# --- Flutter plugins registered from MainActivity ------------------------
# These are referenced directly so R8 keeps them alive, but their channel
# handlers are wired at runtime. Keeping the names makes stack traces and
# channel diagnostics readable after obfuscation.
-keep class com.fqapp.fqapp.MainActivity { *; }
-keep class com.fqapp.fqapp.NativePlayerPlugin { *; }
-keep class com.fqapp.fqapp.ReaderDevicePlugin { *; }
-keep class com.fqapp.fqapp.NativeVideoOutput { *; }
-keep class com.fqapp.fqapp.ReaderBrightnessSession { *; }

# --- Flutter embedding ---------------------------------------------------
# The embedding is reached from the generated registrant and from native code
# in libflutter.so; keep it whole, as the Flutter release guidance advises.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }

# shared_preferences and package:jni resolve Kotlin coroutine types by name.
-keep interface kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.CoroutineSingletons { *; }
-keep class kotlin.coroutines.intrinsics.IntrinsicsKt* { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.Unit { *; }
-keep class kotlin.jvm.internal.DefaultConstructorMarker { *; }

# --- optional Play Core integration -------------------------------------
# Flutter's PlayStoreDeferredComponentManager references the Play Core split
# install API, which is only on the classpath when the app opts into deferred
# components. This app ships a single APK and declares none, so the code path
# is unreachable and the references are safe to silence. Without this, R8 fails
# the build with "Missing classes detected" listing 11
# com.google.android.play.core.* types.
-dontwarn com.google.android.play.core.**

# --- attributes ----------------------------------------------------------
# Signature/annotations are needed by reflection in the AndroidX and Media3
# stack; EnclosingMethod/InnerClasses keep Kotlin lambdas and nested types
# consistent in crash reports.
-keepattributes Signature, InnerClasses, EnclosingMethod, *Annotation*

# The SMB sync connection uses NTLM on Android. SMBJ also carries an optional
# desktop GSS/Kerberos authenticator, whose JDK classes are unavailable here.
-dontwarn org.ietf.jgss.**

# --- audio_service（Kazumi 播放器 / 朗读） -------------------------------
# audio_service 0.18 没有提供 consumer proguard 规则，而本项目
# isMinifyEnabled = true。R8 看不到这些类被直接引用（MainActivity 的父类、
# Manifest 里按类名字符串声明的 Service / Receiver），会把它们连同
# AudioServiceActivity 一起裁掉，表现为运行时
# "The Activity class declared in your AndroidManifest.xml is wrong or
#  has not provided the correct FlutterEngine"。
-keep class com.ryanheise.audioservice.** { *; }
-keep class * extends com.ryanheise.audioservice.AudioServiceActivity { *; }

# MainActivity 继承的是 audio_service 的基类，父类被裁会直接
# NoClassDefFoundError，这里显式保住整条继承链。
-keep class com.fqapp.fqapp.MainActivity { *; }
-keep class io.flutter.embedding.android.FlutterActivity { *; }
