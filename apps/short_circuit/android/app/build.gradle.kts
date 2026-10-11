import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firebase (events and crash reports). The config file is not in the repository: without
// it the build is identical to before and the app's Firebase code does nothing. CI writes
// it from a secret; locally, drop the file from the Firebase console at
// android/app/google-services.json (git-ignored).
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
    apply(plugin = "com.google.firebase.crashlytics")
}

// Release signing. android/key.properties (git-ignored) names a keystore; CI writes
// it from repository secrets. Without it the release build falls back to the debug
// key, so local `flutter run --release` keeps working.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.valay.circuit.short_circuit"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.valay.circuit.short_circuit"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 28 (Android 9): releases are signed with the v3 scheme only, which is what carries
        // the key-rotation proof (see tool/sign_with_lineage.sh), and v3 needs Android 9.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        // The version is NOT taken from pubspec.yaml or from `flutter build --build-number`: a
        // hand-picked number above the tester build's once forced an uninstall that wiped the
        // app's settings and keys. CI sets APP_VERSION_CODE and APP_VERSION_NAME; a build made
        // anywhere else is numbered by the clock (10-second steps since 2026-01-01 UTC, the same
        // formula CI uses), so the build made last always has the higher number.
        versionCode = System.getenv("APP_VERSION_CODE")?.toIntOrNull()
            ?: ((System.currentTimeMillis() / 1000 - 1767225600L) / 10).toInt()
        versionName = System.getenv("APP_VERSION_NAME") ?: "local"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // The relay service reports its own events (see Diagnostics.kt). Same Firebase version
    // as the FlutterFire plugins; without google-services.json nothing is sent.
    implementation(platform("com.google.firebase:firebase-bom:34.19.0"))
    implementation("com.google.firebase:firebase-analytics")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}

flutter {
    source = "../.."
}
