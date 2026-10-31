import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    //id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名信息从 android/key.properties 读取（该文件已被 .gitignore 忽略，不入库）。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

/** key.properties 是否已填好完整签名信息。 */
fun hasReleaseSigning(): Boolean = keystorePropertiesFile.exists() &&
    !keystoreProperties.getProperty("storeFile").isNullOrBlank() &&
    !keystoreProperties.getProperty("storePassword").isNullOrBlank() &&
    !keystoreProperties.getProperty("keyAlias").isNullOrBlank() &&
    !keystoreProperties.getProperty("keyPassword").isNullOrBlank()

android {
    namespace = "com.hoilai.mm.music"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning()) {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        val customPkg = (project.findProperty("customPackageName") as? String)?.trim()
        applicationId = if (!customPkg.isNullOrEmpty()) customPkg else "com.hoilai.mm.music"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 不能用 flutter.minSdkVersion（CI 的 Flutter 3.47.1 解析为 24）：
        // 车载歌词依赖 SuperLyricApi 3.4 的 AAR 清单声明 minSdk 26（Android 8.0），
        // 低于 26 会在 Manifest 合并阶段直接失败：
        //   "uses-sdk:minSdkVersion 24 cannot be smaller than version 26 declared
        //    in library com.github.HChenX:SuperLyricApi"
        // Android 8.0（2017 年发布）覆盖 99%+ 活跃设备，直接提到 26。
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // key.properties 填好后，命令行与 Android Studio 打包统一使用 release 正式签名；
            // 未配置完整信息时回退 debug 签名，保证开发期构建不被阻塞。
            if (hasReleaseSigning()) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                println("Warning: android/key.properties 未配置完整签名信息，release 构建将回退使用 debug 签名。")
                signingConfig = signingConfigs.getByName("debug")
            }
            ndk {
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
            }
            isMinifyEnabled = true
            // Flutter Gradle 插件在 apply 阶段默认打开 release.shrinkResources，
            // 资源裁剪必须与代码裁剪同时开启，否则 AGP 会报
            // "Removing unused resources requires unused code shrinking to be turned on"。
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            isMinifyEnabled = false
        }
    }
}
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}


// === 依赖解析策略：对 JitPack 等按需构建的仓库不缓存失败结果，确保一次冷启动失败后
// 等若干秒再次构建时能重新尝试拉取（而不是被 Gradle 本地缓存的 "404 / module not found"
// 结果一直挡住）。
configurations.all {
    resolutionStrategy {
        // changing 模块（例如 JitPack 的版本号固定但 artifact 是懒构建）不缓存
        cacheChangingModulesFor(0, "seconds")
        // 动态版本（1.+、[1.0, 2.0) 等）不缓存，本项目未用，保留默认即可。
    }
}

dependencies {
    // SuperLyricApi（https://github.com/HChenX/SuperLyricApi 3.4）
    // AAR 通过 JitPack 发布。JitPack 是"首次请求时才在服务器端懒构建"，
    // 所以把该依赖标记为 `changing = true`，配合上面的
    // `cacheChangingModulesFor(0 seconds)` 让 Gradle 不会永远缓存首次 404。
    // 同时在 CI workflow 里做了 JitPack 冷启动失败 → sleep 90s → 重试的兜底。
    implementation("com.github.HChenX:SuperLyricApi:3.4") {
        isChanging = true
    }
}

flutter {
    source = "../.."
}