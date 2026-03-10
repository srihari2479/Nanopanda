allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    plugins.withId("com.android.library") {
        val android = extensions.findByType(com.android.build.gradle.LibraryExtension::class)
        if (android != null && android.namespace == null) {
            val manifestFile = android.sourceSets
                .findByName("main")
                ?.manifest
                ?.srcFile
            if (manifestFile != null && manifestFile.exists()) {
                val text = manifestFile.readText()
                val match = Regex("""package\s*=\s*["']([^"']+)["']""").find(text)
                if (match != null) {
                    android.namespace = match.groupValues[1]
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}