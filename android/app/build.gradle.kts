plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.nanospark"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.example.nanospark"
        minSdk = flutter.minSdkVersion

        // FIXED: Hardcoded to 34 instead of flutter.targetSdkVersion (which = 36).
        // Android 35/36 enforces BAL_BLOCK (Background Activity Launch) — any
        // startActivity() from a FOREGROUND_SERVICE state is blocked completely,
        // including PendingIntents and full-screen notifications.
        // targetSdk = 34 exempts us from this restriction while the app still
        // runs fine on Android 14/15/16 devices.
        targetSdk = 34

        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters.clear()
            abiFilters += "arm64-v8a"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

flutter {
    source = "../.."
}