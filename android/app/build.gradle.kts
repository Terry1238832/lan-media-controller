plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.local.lanmediacontroller"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.local.lanmediacontroller"
        minSdk = 26
        targetSdk = 34
        versionCode = 210
        versionName = "2.1.0"
    }

    signingConfigs {
        create("release") {
            val ksPath = System.getenv("ANDROID_KEYSTORE_PATH")
            if (!ksPath.isNullOrBlank() && file(ksPath).exists()) {
                storeFile = file(ksPath)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASS") ?: "lmc2026pass"
                keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "lmc"
                keyPassword = System.getenv("ANDROID_KEY_PASS") ?: "lmc2026pass"
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            val ksPath = System.getenv("ANDROID_KEYSTORE_PATH")
            signingConfig = if (!ksPath.isNullOrBlank() && file(ksPath).exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
}
