plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.notesapp.notes_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.notesapp.notes_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Desert Ant's Android SDK needs API 24.
        minSdk = maxOf(24, flutter.minSdkVersion)
        // Phones only: arm64-v8a. Phonon, Align and Title are built for nothing else, and an x86_64 copy of
        // every library would only serve emulators. A universal APK only: --split-per-abi sets its own ABI
        // splits, which may not be combined with these (the packaging rule below covers both).
        if (!project.hasProperty("split-per-abi")) ndk { abiFilters += listOf("arm64-v8a") }
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The Desert Ant models, packed in the APK so the app needs no network (tool/fetch_models.py
    // fills .models/; OfflineModels.kt copies them out on first launch). Stored uncompressed:
    // the weights barely compress and inflating 1.7 GB would slow that first launch.
    // NOTES_BUNDLE_MODELS=0 leaves them out (a far smaller APK); push them instead with tool/push_models.sh.
    // tool/stage_models.py stages them (all but Voz, which the user can import) into .models-bundle.
    if (System.getenv("NOTES_BUNDLE_MODELS") != "0") sourceSets["main"].assets.srcDir("../../.models-bundle")
    androidResources {
        noCompress += listOf("tflite", "f16", "f32", "i8", "bin", "json", "safetensors", "jinja")
    }

    // A release key when the environment names one (tool/release.sh, CI secrets), else the debug key.
    val keystore = System.getenv("DOCKET_KEYSTORE")
    if (keystore != null) {
        signingConfigs.create("docket") {
            storeFile = file(keystore)
            storePassword = System.getenv("DOCKET_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("DOCKET_KEY_ALIAS")
            keyPassword = System.getenv("DOCKET_KEY_PASSWORD")
        }
    }

    buildTypes {
        release {
            // Names native code looks up (JNI) survive R8: proguard-rules.pro.
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName(if (keystore != null) "docket" else "debug")
        }
    }
}

android {
    // Whatever a dependency carries for other ABIs (Desert Ant's and LiteRT's x86_64 libraries) stays out.
    packaging { jniLibs { excludes += listOf("lib/x86_64/**", "lib/x86/**", "lib/armeabi-v7a/**") } }
}

// Align and Title are built, not kept in git: say how, rather than fail on Kotlin's unresolved imports.
val desertAntLibs = file("libs")
val checkDesertAntLibs by tasks.registering {
    doFirst {
        for (model in listOf("align", "title")) {
            if (!desertAntLibs.resolve("$model-release.aar").isFile) {
                throw GradleException("android/app/libs/$model-release.aar is missing: run tool/build_desert_ant.sh")
            }
        }
    }
}
tasks.named("preBuild") { dependsOn(checkDesertAntLibs) }

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Desert Ant's on-device models (desertant.com), the versions tool/fetch_models.py pins.
    val desertAnt = "4.3.0"
    implementation("ai.desertant:core:$desertAnt")
    implementation("ai.desertant:clear:$desertAnt")
    implementation("ai.desertant:ear:$desertAnt")
    implementation("ai.desertant:voz:$desertAnt")
    implementation("ai.desertant:who:$desertAnt")
    implementation("ai.desertant:gist:$desertAnt")
    implementation("ai.desertant:emo:$desertAnt")
    // Align and Title for Android: built from Desert Ant's source and Docket's patches by
    // tool/build_desert_ant.sh (tool/ci.sh and tool/release.sh run it), not kept in git.
    implementation(fileTree("libs") { include("*.aar") })
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
    // The real org.json for JVM unit tests (Android's is a stub there).
    testImplementation("org.json:json:20240303")
}
