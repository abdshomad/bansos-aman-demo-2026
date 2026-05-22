#!/usr/bin/env bash
# Build Bansos Aman APK from the bansos-aman-2026 git submodule without editing
# tracked submodule source. Only gitignored build artifacts (.env, local.properties,
# debug.keystore, Gradle/Android build dirs) may be written inside the submodule.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBMODULE_DIR="${REPO_ROOT}/bansos-aman-2026"
GRADLEW="${REPO_ROOT}/gradlew"
DIST_DIR="${REPO_ROOT}/dist"
GRADLE_VERSION="9.3.1"

# debug (default) or release
BUILD_TYPE="${BUILD_TYPE:-debug}"
# Set INSTALL_ANDROID_SDK=1 to bootstrap SDK into REPO_ROOT/.android-sdk
INSTALL_ANDROID_SDK="${INSTALL_ANDROID_SDK:-0}"
# Set INSTALL_JDK=1 to download Temurin JDK 17 into REPO_ROOT/.jdk
INSTALL_JDK="${INSTALL_JDK:-0}"
# Optional Gemini key (written to gitignored bansos-aman-2026/.env)
GEMINI_API_KEY="${GEMINI_API_KEY:-}"

usage() {
  cat <<'EOF'
Usage: ./build-apk.sh [options]

Build the Android app in bansos-aman-2026/ into dist/*.apk without modifying
tracked files in the git submodule.

Options:
  -t, --type TYPE     Build type: debug (default) or release
  -i, --install-sdk   Download Android SDK into .android-sdk (first run)
  -j, --install-jdk   Download Temurin JDK 17 into .jdk (if system has no javac)
  -h, --help          Show this help

Environment:
  ANDROID_HOME / ANDROID_SDK_ROOT   Android SDK location (auto-detected if unset)
  GEMINI_API_KEY                    API key for secrets plugin (.env)
  KEYSTORE_PATH, STORE_PASSWORD, KEY_PASSWORD   Required for release signing

Examples:
  ./build-apk.sh
  BUILD_TYPE=release KEYSTORE_PATH=./upload.jks STORE_PASSWORD=*** KEY_PASSWORD=*** ./build-apk.sh
  INSTALL_ANDROID_SDK=1 ./build-apk.sh --install-sdk
EOF
}

log() { printf '[build-apk] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--type)
        BUILD_TYPE="${2:-}"
        shift 2
        ;;
      -i|--install-sdk)
        INSTALL_ANDROID_SDK=1
        shift
        ;;
      -j|--install-jdk)
        INSTALL_JDK=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1 (use --help)"
        ;;
    esac
  done
  case "$BUILD_TYPE" in
    debug|release) ;;
    *) die "BUILD_TYPE must be 'debug' or 'release', got: $BUILD_TYPE" ;;
  esac
}

ensure_submodule() {
  if [[ ! -f "${SUBMODULE_DIR}/settings.gradle.kts" ]]; then
    die "Submodule missing at ${SUBMODULE_DIR}. Run: git submodule update --init --recursive"
  fi
}

install_jdk() {
  local jdk_root="${REPO_ROOT}/.jdk"
  local version="17.0.14+7"
  local archive="OpenJDK17U-jdk_x64_linux_hotspot_${version//+/_}.tar.gz"
  local url="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-${version}/${archive}"
  local cache="${REPO_ROOT}/.cache/${archive}"

  if [[ -x "${jdk_root}/bin/javac" ]]; then
    printf '%s' "$jdk_root"
    return 0
  fi

  mkdir -p "${REPO_ROOT}/.cache"
  log "Downloading Temurin JDK 17..."
  curl -fsSL -o "$cache" "$url"
  rm -rf "${jdk_root}"
  mkdir -p "$jdk_root"
  tar -xzf "$cache" -C "$jdk_root" --strip-components=1
  [[ -x "${jdk_root}/bin/javac" ]] || die "JDK install failed under ${jdk_root}"
  printf '%s' "$jdk_root"
}

find_jdk_home() {
  if [[ -d "${REPO_ROOT}/.jdk" && -x "${REPO_ROOT}/.jdk/bin/javac" ]]; then
    printf '%s' "${REPO_ROOT}/.jdk"
    return 0
  fi
  local candidates=()
  if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/javac" ]]; then
    candidates+=("$JAVA_HOME")
  fi
  local jvm_dir="/usr/lib/jvm"
  if [[ -d "$jvm_dir" ]]; then
    local entry
    for entry in "$jvm_dir"/java-*-openjdk-* "$jvm_dir"/jdk-*; do
      [[ -d "$entry" && -x "$entry/bin/javac" ]] && candidates+=("$entry")
    done
  fi
  local dir
  for dir in "${candidates[@]}"; do
    local major
    major="$("$dir/bin/java" -version 2>&1 | head -1 | sed -n 's/.*version "\([0-9]*\).*/\1/p')"
    if [[ -n "$major" && "$major" -ge 17 ]]; then
      printf '%s' "$dir"
      return 0
    fi
  done
  return 1
}

ensure_jdk() {
  local jdk_home
  if ! jdk_home="$(find_jdk_home)"; then
    if [[ "$INSTALL_JDK" == "1" ]]; then
      jdk_home="$(install_jdk)"
    else
      die "JDK 17+ with javac is required. Install openjdk-17-jdk or run: INSTALL_JDK=1 $0 --install-jdk"
    fi
  fi
  export JAVA_HOME="$jdk_home"
  export PATH="${JAVA_HOME}/bin:${PATH}"
  local version
  version="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | sed -n 's/.*version "\([^"]*\)".*/\1/p')"
  log "Using JDK ${version} at ${JAVA_HOME}"
}

resolve_android_sdk() {
  local candidates=()
  if [[ -n "${ANDROID_HOME:-}" ]]; then candidates+=("$ANDROID_HOME"); fi
  if [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then candidates+=("$ANDROID_SDK_ROOT"); fi
  candidates+=(
    "${REPO_ROOT}/.android-sdk"
    "${HOME}/Android/Sdk"
    "/usr/lib/android-sdk"
    "/opt/android-sdk"
  )
  local dir
  for dir in "${candidates[@]}"; do
    if [[ -n "$dir" && -d "$dir" && -f "$dir/platforms/android-36/android.jar" ]]; then
      printf '%s' "$dir"
      return 0
    fi
  done
  # Accept SDK root even if platform 36 not installed yet (sdkmanager will add it)
  for dir in "${candidates[@]}"; do
    if [[ -n "$dir" && -d "$dir" ]]; then
      printf '%s' "$dir"
      return 0
    fi
  done
  printf '%s' "${REPO_ROOT}/.android-sdk"
}

install_android_sdk() {
  local sdk_root="$1"
  local tools_dir="${sdk_root}/cmdline-tools/latest"
  local sdkmanager="${tools_dir}/bin/sdkmanager"
  local url="https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
  local tmp_zip="${REPO_ROOT}/.cache/cmdline-tools.zip"

  mkdir -p "${REPO_ROOT}/.cache" "${sdk_root}"
  if [[ ! -x "$sdkmanager" ]]; then
    log "Downloading Android command-line tools..."
    curl -fsSL -o "$tmp_zip" "$url"
    rm -rf "${sdk_root}/cmdline-tools"
    mkdir -p "${sdk_root}/cmdline-tools"
    unzip -q -o "$tmp_zip" -d "${sdk_root}/cmdline-tools"
    if [[ -d "${sdk_root}/cmdline-tools/cmdline-tools" ]]; then
      mv "${sdk_root}/cmdline-tools/cmdline-tools" "${sdk_root}/cmdline-tools/latest"
    fi
  fi
  [[ -x "$sdkmanager" ]] || die "sdkmanager not found after install at ${sdkmanager}"

  log "Installing SDK packages (platform-tools, android-36, build-tools 36.0.0)..."
  yes | "$sdkmanager" --sdk_root="$sdk_root" --licenses >/dev/null || true
  "$sdkmanager" --sdk_root="$sdk_root" \
    "platform-tools" \
    "platforms;android-36" \
    "build-tools;36.0.0"
}

configure_android_sdk() {
  local sdk_root
  sdk_root="$(resolve_android_sdk)"

  if [[ ! -f "${sdk_root}/platforms/android-36/android.jar" ]]; then
    if [[ "$INSTALL_ANDROID_SDK" == "1" ]]; then
      install_android_sdk "$sdk_root"
    else
      die "Android SDK 36 not found at ${sdk_root}. Set ANDROID_HOME, install SDK 36, or run: INSTALL_ANDROID_SDK=1 $0 --install-sdk"
    fi
  fi

  export ANDROID_HOME="$sdk_root"
  export ANDROID_SDK_ROOT="$sdk_root"
  # gitignored in submodule — does not modify tracked source
  printf 'sdk.dir=%s\n' "$sdk_root" > "${SUBMODULE_DIR}/local.properties"
  log "Android SDK: ${sdk_root}"
}

ensure_debug_keystore() {
  local keystore="${SUBMODULE_DIR}/debug.keystore"
  if [[ -f "$keystore" ]]; then
    return 0
  fi
  local encoded="${SUBMODULE_DIR}/debug.keystore.base64"
  [[ -f "$encoded" ]] || die "Missing ${encoded} (cannot create debug.keystore)"
  log "Creating gitignored debug.keystore from debug.keystore.base64"
  base64 -d "$encoded" > "$keystore"
}

ensure_env_file() {
  local env_file="${SUBMODULE_DIR}/.env"
  if [[ -f "$env_file" ]]; then
    return 0
  fi
  if [[ -n "$GEMINI_API_KEY" ]]; then
    log "Writing gitignored .env from GEMINI_API_KEY"
    printf 'GEMINI_API_KEY=%s\n' "$GEMINI_API_KEY" > "$env_file"
    return 0
  fi
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    log "Copying ${REPO_ROOT}/.env -> bansos-aman-2026/.env"
    cp "${REPO_ROOT}/.env" "$env_file"
    return 0
  fi
  if [[ -f "${SUBMODULE_DIR}/.env.example" ]]; then
    log "Using .env.example as gitignored .env (set GEMINI_API_KEY for production)"
    cp "${SUBMODULE_DIR}/.env.example" "$env_file"
    return 0
  fi
  die "No .env found. Set GEMINI_API_KEY or add ${REPO_ROOT}/.env"
}

validate_release_signing() {
  if [[ "$BUILD_TYPE" != "release" ]]; then
    return 0
  fi
  local keystore="${KEYSTORE_PATH:-${SUBMODULE_DIR}/my-upload-key.jks}"
  if [[ ! -f "$keystore" ]]; then
    die "Release build requires keystore at KEYSTORE_PATH or ${SUBMODULE_DIR}/my-upload-key.jks"
  fi
  [[ -n "${STORE_PASSWORD:-}" ]] || die "Release build requires STORE_PASSWORD"
  [[ -n "${KEY_PASSWORD:-}" ]] || die "Release build requires KEY_PASSWORD"
  export KEYSTORE_PATH="$keystore"
}

run_gradle_build() {
  [[ -x "$GRADLEW" ]] || die "Missing ${GRADLEW}. Re-clone repo or restore gradle wrapper at repo root."
  local task="assembleDebug"
  [[ "$BUILD_TYPE" == "release" ]] && task="assembleRelease"

  log "Running Gradle ${GRADLE_VERSION}: ${task}"
  (
    cd "$REPO_ROOT"
    export GRADLE_USER_HOME="${REPO_ROOT}/.gradle-user-home"
    ./gradlew -p "$SUBMODULE_DIR" ":app:${task}" --no-daemon --stacktrace
  )
}

copy_apk() {
  local apk_dir="${SUBMODULE_DIR}/app/build/outputs/apk/${BUILD_TYPE}"
  local apk
  apk="$(find "$apk_dir" -maxdepth 1 -name '*.apk' -type f | head -1)"
  [[ -n "$apk" ]] || die "APK not found under ${apk_dir}"

  mkdir -p "$DIST_DIR"
  local out="${DIST_DIR}/bansos-aman-${BUILD_TYPE}.apk"
  cp -f "$apk" "$out"
  log "APK ready: ${out}"
  log "Size: $(du -h "$out" | awk '{print $1}')"
}

main() {
  parse_args "$@"
  ensure_submodule
  ensure_jdk
  configure_android_sdk
  ensure_debug_keystore
  ensure_env_file
  validate_release_signing
  run_gradle_build
  copy_apk
}

main "$@"
