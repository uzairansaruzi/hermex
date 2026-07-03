// Top-level build file. Per-module configuration lives in app/build.gradle.kts;
// the locked dependency list lives in gradle/libs.versions.toml (see AGENTS.md).
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.ksp) apply false
}
