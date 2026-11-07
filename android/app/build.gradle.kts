plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.overcode.kelly"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.overcode.kelly"
        minSdk = 26
        targetSdk = 35
        versionCode = 27
        versionName = "2.7.0"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}