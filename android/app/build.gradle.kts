plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties

// Política de chave (Fase 0 - Opção A): a chave DEBUG é a oficial da linha.
// O release build assina com ela de forma EXPLÍCITA via key.properties (o
// CI injeta via secret; localmente, se o arquivo não existir, cai no debug).
// Nunca substitua esta política sem a migração da Fase 0-B — assinatura
// divergente = instalados não atualizam por cima (I-1).
fun loadReleaseKeystore(): Properties? {
    val props = Properties()
    val file = rootProject.file("key.properties")
    if (!file.exists()) return null
    file.inputStream().use { props.load(it) }
    if (props["storeFile"] == null || props["storePassword"] == null ||
        props["keyAlias"] == null || props["keyPassword"] == null
    ) return null
    return props
}

android {
    namespace = "com.example.goanime_tv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.goanime_tv"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val p = loadReleaseKeystore() ?: return@create
            storeFile = rootProject.file(p["storeFile"] as String)
            storePassword = p["storePassword"] as String
            keyAlias = p["keyAlias"] as String
            keyPassword = p["keyPassword"] as String
        }
    }

    buildTypes {
        release {
            val p = loadReleaseKeystore()
            if (p != null) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Local sem key.properties: fallback na chave debug (mesma
                // política oficial — o CI sempre injeta key.properties).
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // FileProvider (fallback ACTION_VIEW do updater) vem do androidx.core.
    implementation("androidx.core:core-ktx:1.13.1")
}

flutter {
    source = "../.."
}
