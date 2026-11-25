plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "com.onevcat.prowl.mirror"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.onevcat.prowl.mirror"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0-experimental"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    sourceSets.getByName("test").resources.srcDir("../../Fixtures/conversation")
    buildFeatures { compose = true; buildConfig = true }
    composeOptions { kotlinCompilerExtensionVersion = "1.5.14" }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    packaging { resources.excludes += "META-INF/versions/**/OSGI-INF/MANIFEST.MF" }
}
// Ship the MIT notices with every distributed copy of the app (assets/LICENSE and
// assets/THIRD_PARTY_NOTICES).
abstract class CopyLicenseAsset : DefaultTask() {
    @get:InputFile abstract val license: RegularFileProperty
    @get:InputFile abstract val notices: RegularFileProperty
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        license.get().asFile.copyTo(outputDir.get().file("LICENSE").asFile, overwrite = true)
        notices.get().asFile.copyTo(outputDir.get().file("THIRD_PARTY_NOTICES").asFile, overwrite = true)
    }
}
val copyLicenseAsset = tasks.register<CopyLicenseAsset>("copyLicenseAsset") {
    license.set(rootProject.layout.projectDirectory.file("LICENSE"))
    notices.set(rootProject.layout.projectDirectory.file("ThirdPartyNotices/agent-icons.txt"))
}
androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(copyLicenseAsset, CopyLicenseAsset::outputDir)
    }
}
dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.06.00"))
    implementation("androidx.activity:activity-compose:1.9.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("com.google.code.gson:gson:2.11.0")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation("org.bouncycastle:bctls-jdk18on:1.83")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
    androidTestImplementation(platform("androidx.compose:compose-bom:2024.06.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
