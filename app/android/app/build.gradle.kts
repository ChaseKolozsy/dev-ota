// Imported rather than fully qualified: inside `signingConfigs` the `java`
// identifier resolves to Gradle's java extension, so `java.util.Properties`
// fails to compile there.
import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val devotaApplicationId: String = providers
    .environmentVariable("DEVOTA_APPLICATION_ID")
    .orElse("io.github.chasekolozsy.devota")
    .get()

android {
    namespace = "io.github.chasekolozsy.devota"
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
        applicationId = devotaApplicationId
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        // Override the auto-generated debug keystore with a stable, committed one
        // so locally-built and GH-Actions-built debug APKs share a signing identity.
        // This is what makes self-update via the DevOTA a one-tap update
        // instead of an uninstall-then-reinstall.
        getByName("debug") {
            storeFile = rootProject.file("../keystores/dev.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
        create("release") {
            // Sideload-friendly release signing: defaults to the committed dev.keystore
            // so local and GitHub Actions builds share the same upgrade identity.
            // Override with keystore.properties or DEVOTA_KEYSTORE_* env vars for private signing.
            val keystorePropsFile = rootProject.file("keystore.properties")
            val keystoreProps = Properties()
            if (keystorePropsFile.exists()) {
                keystorePropsFile.inputStream().use { keystoreProps.load(it) }
            }
            fun propOrEnv(propKey: String, vararg envKeys: String): String? {
                for (k in envKeys) {
                    val v = providers.environmentVariable(k).orElse("").get()
                    if (v.isNotBlank()) return v
                }
                return keystoreProps.getProperty(propKey)
            }
            val storeFileProp = propOrEnv("storeFile", "DEVOTA_KEYSTORE_FILE", "ANDROID_KEYSTORE_FILE", "KEYSTORE_FILE")
                ?: "../keystores/dev.keystore"
            val storePasswordProp = propOrEnv("storePassword", "DEVOTA_KEYSTORE_PASSWORD", "ANDROID_KEYSTORE_PASSWORD", "KEYSTORE_PASSWORD")
                ?: "android"
            val keyAliasProp = propOrEnv("keyAlias", "DEVOTA_KEY_ALIAS", "ANDROID_KEY_ALIAS", "KEY_ALIAS")
                ?: "androiddebugkey"
            val keyPasswordProp = propOrEnv("keyPassword", "DEVOTA_KEY_PASSWORD", "ANDROID_KEY_PASSWORD", "KEY_PASSWORD")
                ?: "android"
            // Resolve storeFile relative to the app module unless absolute.
            val f = File(storeFileProp)
            storeFile = if (f.isAbsolute) f else rootProject.file(storeFileProp)
            storePassword = storePasswordProp
            keyAlias = keyAliasProp
            keyPassword = keyPasswordProp
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
