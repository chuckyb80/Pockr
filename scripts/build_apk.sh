#!/bin/bash
# Build the Flutter Android APK entirely inside Docker.
#
# Usage:
#   ./scripts/build_apk.sh            # debug build (default)
#   ./scripts/build_apk.sh release    # release build (needs the release keystore, see below)
#
# Release builds are signed with a keystore that lives OUTSIDE this repo. Set these
# in your shell first (create the keystore once with scripts/make_release_keystore.sh):
#   POCKR_KEYSTORE_FILE       path to the keystore, e.g. $HOME/.pockr/release.keystore
#   POCKR_KEYSTORE_PASSWORD   keystore password
#   POCKR_KEY_ALIAS           key alias (make_release_keystore.sh uses "pockr")
#   POCKR_KEY_PASSWORD        key password
# Debug builds keep using the committed debug.keystore so `adb install -r` can upgrade
# in place. That key is public and is never used for a release.
#
# Output:
#   build/app-debug.apk   or
#   build/app-release.apk
#
# Requirements: Docker only.  No Flutter, Java, or Android SDK on the host.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_TYPE="${1:-debug}"
IMAGE_NAME="docker-app-builder"
OUTPUT_DIR="${PROJECT_ROOT}/build"

# ── Release signing inputs ────────────────────────────────────────────────────
# Checked before Docker so a missing key fails in a second, not after the image build.
# Only the variable NAMES are passed to `docker run` (-e NAME), so the passwords never
# appear on a command line or in `ps`.
SIGNING_ARGS=()
if [ "${BUILD_TYPE}" = "release" ]; then
    missing=""
    for v in POCKR_KEYSTORE_FILE POCKR_KEYSTORE_PASSWORD POCKR_KEY_ALIAS POCKR_KEY_PASSWORD; do
        [ -n "${!v:-}" ] || missing="${missing} ${v}"
    done
    if [ -n "${missing}" ]; then
        echo "ERROR: a release build must be signed with the release key. Not set:${missing}"
        echo "       Create a keystore once with: ./scripts/make_release_keystore.sh"
        echo "       Release builds are never signed with debug.keystore."
        exit 1
    fi
    if [ ! -f "${POCKR_KEYSTORE_FILE}" ]; then
        echo "ERROR: POCKR_KEYSTORE_FILE does not exist: ${POCKR_KEYSTORE_FILE}"
        exit 1
    fi
    KEYSTORE_ABS="$(cd "$(dirname "${POCKR_KEYSTORE_FILE}")" && pwd)/$(basename "${POCKR_KEYSTORE_FILE}")"
    case "${KEYSTORE_ABS}" in
        "${PROJECT_ROOT}"/*)
            echo "ERROR: the release keystore is inside the repo (${KEYSTORE_ABS})."
            echo "       Keep it outside the project tree, e.g. \$HOME/.pockr/release.keystore"
            exit 1 ;;
    esac
    SIGNING_ARGS=(
        -v "${KEYSTORE_ABS}:/run/pockr/release.keystore:ro"
        -e POCKR_KEYSTORE_FILE=/run/pockr/release.keystore
        -e POCKR_KEYSTORE_PASSWORD
        -e POCKR_KEY_ALIAS
        -e POCKR_KEY_PASSWORD
    )
fi

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is required."
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

# ── Build the builder image if it doesn't exist (always amd64 for consistency) ─
if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
    echo "=== Building Docker build environment (first run — ~10 min) ==="
    docker build \
        --platform linux/amd64 \
        -f "${PROJECT_ROOT}/docker/Dockerfile.build" \
        -t "${IMAGE_NAME}" \
        "${PROJECT_ROOT}"
    echo ""
fi

echo "=== Building Flutter APK (${BUILD_TYPE}) inside Docker ==="
echo "Project : ${PROJECT_ROOT}"
echo "Output  : ${OUTPUT_DIR}/app-${BUILD_TYPE}.apk"
echo ""

# ── Run the build inside Docker ───────────────────────────────────────────────
# Strategy:
#   1. flutter create scaffolds a complete Android project (gradlew, gradle
#      wrapper, res/, etc.) in /tmp/workspace
#   2. We copy our source files (lib/, pubspec.yaml, Android sources) on top
#   3. flutter pub get + flutter build apk
#   4. APK is copied to the mounted /out volume

docker run --rm \
    --platform linux/amd64 \
    -v "${PROJECT_ROOT}:/src:ro" \
    -v "${OUTPUT_DIR}:/out" \
    "${SIGNING_ARGS[@]}" \
    "${IMAGE_NAME}" \
    bash -c "
set -e
git config --global --add safe.directory /opt/flutter 2>/dev/null || true

echo '--- Step 1: Scaffold fresh Flutter project ---'
flutter create \
    --no-pub \
    --project-name pockr \
    --org com.example.dockerapp \
    --platforms android \
    /tmp/workspace

echo ''
echo '--- Step 2: Apply our sources over the scaffold ---'
cd /tmp/workspace

# Flutter Dart sources
cp -r /src/lib/. lib/
cp /src/pubspec.yaml pubspec.yaml
cp /src/analysis_options.yaml . 2>/dev/null || true

# Android app module
cp /src/android/app/build.gradle            android/app/build.gradle
cp /src/android/app/src/main/AndroidManifest.xml \
                                            android/app/src/main/AndroidManifest.xml
cp /src/android/build.gradle               android/build.gradle
cp /src/android/settings.gradle            android/settings.gradle
cp /src/android/gradle.properties          android/gradle.properties

# Kotlin sources (replace scaffold's MainActivity with ours)
rm -rf android/app/src/main/kotlin/
cp -r /src/android/app/src/main/kotlin     android/app/src/main/

# Android resources (network_security_config.xml, etc.) — merge into scaffold res/
cp -r /src/android/app/src/main/res/.  android/app/src/main/res/

# Assets (bootstrap scripts; qemu/ and vm/ dirs contain placeholders only)
mkdir -p android/app/src/main/assets
cp -r /src/android/app/src/main/assets/.  android/app/src/main/assets/

# Flutter assets (logo, images)
[ -d /src/assets ] && cp -r /src/assets/. assets/ || true

# Native libs (QEMU + all shared libs — arm64-v8a)
mkdir -p android/app/src/main/jniLibs
cp -r /src/android/app/src/main/jniLibs/. android/app/src/main/jniLibs/

# Debug signing keystore — a stable (public) signature so debug builds upgrade in place
# with adb install -r. Release builds ignore it and use the keystore passed in above.
[ -f /src/android/app/debug.keystore ] && cp /src/android/app/debug.keystore android/app/debug.keystore || true

echo ''
echo '--- Step 2b: Fix Gradle wrapper to 8.3 (required by AGP 8.1.0) ---'
sed -i 's|distributionUrl=.*|distributionUrl=https\://services.gradle.org/distributions/gradle-8.3-all.zip|' \
    android/gradle/wrapper/gradle-wrapper.properties
echo \"Gradle: \$(grep distributionUrl android/gradle/wrapper/gradle-wrapper.properties)\"

# Write local.properties so settings.gradle can locate flutter.sdk
printf 'flutter.sdk=/opt/flutter\nsdk.dir=/opt/android-sdk\n' > android/local.properties

echo ''
echo '--- Step 3: flutter pub get ---'
flutter pub get

echo ''
echo '--- Step 3b: Generate launcher icons from logo ---'
dart run flutter_launcher_icons

echo ''
echo '--- Step 4: flutter build apk (${BUILD_TYPE}) ---'
flutter build apk --${BUILD_TYPE} --verbose 2>&1 | tail -50

echo ''
echo '--- Step 5: Copy APK to output ---'
APK_SRC=\"build/app/outputs/flutter-apk/app-${BUILD_TYPE}.apk\"
APK_OUT=\"pockr-${BUILD_TYPE}.apk\"
if [ -f \"\$APK_SRC\" ]; then
    cp \"\$APK_SRC\" /out/\$APK_OUT
    echo \"APK size: \$(du -sh /out/\$APK_OUT | cut -f1)\"
else
    echo 'ERROR: APK not found at \$APK_SRC'
    ls -la build/app/outputs/flutter-apk/ 2>/dev/null || true
    exit 1
fi
"

echo ""
echo "✅  Build complete: ${OUTPUT_DIR}/pockr-${BUILD_TYPE}.apk"
echo ""
echo "Install on connected device:"
echo "  adb install ${OUTPUT_DIR}/pockr-${BUILD_TYPE}.apk"
