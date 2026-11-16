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
    // tool/stage_models.py stages them (Phonon's; the Desert Ant models are downloaded in the app) into .models-bundle.
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
    packaging {
        jniLibs {
            excludes += listOf("lib/x86_64/**", "lib/x86/**", "lib/armeabi-v7a/**")
            // LiteRT 2.3.2 comes with both ai.desertant:core and LiteRT's own package: the same file (one sha256).
            pickFirsts += "lib/arm64-v8a/libLiteRt.so"
        }
    }
}

// Desert Ant's models are built from source, not kept in git (tool/build_desert_ant.sh): their Kotlin in
// libs/<model>-release.aar, all their native code in one library, libs/jni/arm64-v8a/libDesertAntAndroid.so.
// Say how to build them, rather than fail on Kotlin's unresolved imports or at the first model loaded.
val desertAntLibs = file("libs")
android { sourceSets["main"].jniLibs.srcDir(desertAntLibs.resolve("jni")) }
val checkDesertAntLibs by tasks.registering {
    doFirst {
        val needed = listOf("clear", "ear", "who", "gist", "align", "title").map { "$it-release.aar" } +
            "jni/arm64-v8a/libDesertAntAndroid.so"
        for (file in needed) {
            if (!desertAntLibs.resolve(file).isFile) {
                throw GradleException("android/app/libs/$file is missing: run tool/build_desert_ant.sh")
            }
        }
        // Mirage's shim (picture tags), built beside them.
        if (!desertAntLibs.resolve("jni/arm64-v8a/libmirage_jni.so").isFile) {
            throw GradleException("android/app/libs/jni/arm64-v8a/libmirage_jni.so is missing: run tool/build_mirage_jni.sh")
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
    // Desert Ant's on-device models (desertant.com), the versions tool/fetch_models.py pins: the core
    // (LiteRT) from Maven; Clear, Ear, Who, Gist, Align and Title built from Desert Ant's source and Docket's
    // patches by tool/build_desert_ant.sh (tool/ci.sh and tool/release.sh run it), sharing one native library.
    implementation("ai.desertant:core:4.3.0")
    // EmbeddingGemma 2 (search by meaning, text and pictures): its graphs on the same LiteRT as Desert Ant's models,
    // through LiteRT's Kotlin API (its JNI opens the app's one libLiteRt.so); its model is downloaded.
    implementation("com.google.ai.edge.litert:litert-api:2.3.2") {
        // Only CompiledModel is used: not LiteRT's model delivery through Play (ai-delivery brings WorkManager and
        // Room, whose start-up provider crashed the app) nor the Guava futures only that delivery uses.
        exclude(group = "com.google.android.play", module = "ai-delivery")
        exclude(group = "com.google.guava")
        exclude(group = "org.jetbrains.kotlinx", module = "kotlinx-coroutines-guava")
    }
    implementation(fileTree("libs") { include("*.aar") })
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
    // The real org.json for JVM unit tests (Android's is a stub there).
    testImplementation("org.json:json:20240303")
}
