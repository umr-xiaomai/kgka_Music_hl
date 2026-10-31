# SuperLyricApi 混淆规则
-keep class com.hchen.superlyricapi.** { *; }

# ===== R8 full mode 保活规则 =====
# full mode 比 compat 模式更激进地重写/内联，下面这些依赖反射或运行时
# 按名字加载的入口必须显式保留，否则会出现「构建成功但运行时崩溃」。

# Flutter 引擎通过反射实例化插件（GeneratedPluginRegistrant / MethodChannel）
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# audio_service / just_audio 通过 MediaSession、Service、Handler 反射回调
-keep class com.ryanheise.audio_session.** { *; }
-keep class com.ryanheise.just_audio.** { *; }
-keep class com.ryanheise.audioservice.** { *; }
-keep class * extends android.app.Service
-keep class * extends android.content.BroadcastReceiver
-keep class * implements android.os.Handler$Callback

# 项目自身通过 MethodChannel 调用的原生实现（kgka_music_hl/screen 等）
-keep class com.hoilai.mm.music.** { *; }

# 序列化与注解需要保留运行时元数据
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# 依赖中缺失的可选类，避免 R8 因找不到引用而失败
-dontwarn org.jetbrains.annotations.**
-dontwarn javax.annotation.**
