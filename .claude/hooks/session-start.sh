#!/bin/bash
# SessionStart hook for Claude Code on the web.
#
# Pockr is a Flutter/Dart app. The only local tooling its linter
# (flutter_lints, via analysis_options.yaml) and its test runner
# (flutter_test) need is the Flutter SDK plus `flutter pub get`.
#
# Deliberately NOT installed here: the Android SDK / Gradle / JDK toolchain
# that scripts/build_apk.sh uses. Building the actual APK is documented as
# Docker-Desktop-only (scripts/README.md: "Rule: Docker only") and pulls in
# gigabytes of SDK platforms/build-tools that `flutter analyze` / `flutter
# test` never touch — installing it here would only slow down every session
# for a capability this hook doesn't need to provide.
set -euo pipefail

# Web-only: local sessions already have a dev machine set up.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

FLUTTER_VERSION="3.22.2"
FLUTTER_HOME="${HOME}/flutter"

# Idempotent: skip the ~750MB download/extract if a matching SDK is already
# in place (container state is cached after this hook completes, so repeat
# sessions on the same container should hit this branch).
if [ ! -x "${FLUTTER_HOME}/bin/flutter" ] || ! "${FLUTTER_HOME}/bin/flutter" --version 2>/dev/null | grep -q "${FLUTTER_VERSION}"; then
  echo "Installing Flutter ${FLUTTER_VERSION} to ${FLUTTER_HOME}..."
  rm -rf "${FLUTTER_HOME}"
  TMP_TAR="$(mktemp -t flutter-XXXXXX.tar.xz)"
  curl -fsSL -o "${TMP_TAR}" \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  tar -xf "${TMP_TAR}" -C "${HOME}"
  rm -f "${TMP_TAR}"
fi

export PATH="${FLUTTER_HOME}/bin:${PATH}"

# The web sandbox runs as root; git and flutter both refuse to operate on
# repos/SDKs they don't own without this.
git config --global --add safe.directory "${FLUTTER_HOME}" || true
git config --global --add safe.directory "${CLAUDE_PROJECT_DIR}" || true

flutter config --no-analytics >/dev/null 2>&1 || true

# Fetch pub dependencies for the app (prefer `pub get` over `pub get
# --enforce-lockfile` so it self-heals rather than hard-failing on a stale
# lockfile in a cached container).
cd "${CLAUDE_PROJECT_DIR}"
flutter pub get

# Persist PATH for the rest of the session (this script's own `export`
# above only covers this process).
echo "export PATH=\"${FLUTTER_HOME}/bin:\${PATH}\"" >> "${CLAUDE_ENV_FILE}"
