# bansos-aman-demo-2026

Demo wrapper for [bansos-aman-2026](https://github.com/abdshomad/bansos-aman-2026) (Android / Kotlin / Jetpack Compose). The app lives in the `bansos-aman-2026` git submodule; this repo adds a build script that compiles an APK **without changing tracked submodule source**.

## Prerequisites

- JDK 17 or newer
- Git (for submodule checkout)
- Android SDK with **API 36** and **Build-Tools 36.0.0**, **or** let the script install them (see below)

## Build APK

```bash
git submodule update --init --recursive
chmod +x build-apk.sh
./build-apk.sh
```

Output: `dist/bansos-aman-debug.apk`

### First-time SDK install (optional)

If `ANDROID_HOME` is not set and the SDK is missing, bootstrap into `.android-sdk` at the repo root:

```bash
./build-apk.sh --install-sdk

# If only a JRE is installed (no javac), also bootstrap JDK 17:
./build-apk.sh --install-jdk --install-sdk
```

### Release APK

Requires a upload keystore and passwords (see submodule `app/build.gradle.kts` signing config):

```bash
BUILD_TYPE=release \
  KEYSTORE_PATH=/path/to/upload.jks \
  STORE_PASSWORD='...' \
  KEY_PASSWORD='...' \
  ./build-apk.sh --type release
```

### Environment

| Variable | Purpose |
|----------|---------|
| `GEMINI_API_KEY` | Written to gitignored `bansos-aman-2026/.env` if missing |
| `ANDROID_HOME` / `ANDROID_SDK_ROOT` | Android SDK location |
| `BUILD_TYPE` | `debug` (default) or `release` |

You can also place a `.env` file at the repo root; it is copied into the submodule at build time (gitignored there).

## What the script touches

- **Repo root:** Gradle wrapper (`gradlew`), `dist/`, optional `.android-sdk`, `.gradle-user-home`
- **Submodule (gitignored only):** `local.properties`, `.env`, `debug.keystore`, Gradle/Android `build/` dirs

Tracked Kotlin, Gradle, and resource files inside `bansos-aman-2026/` are never modified.
