#!/bin/bash
# Create the Pockr release keystore. Run this once, then back the file and both
# passwords up in your password manager: a lost keystore means existing installs can
# never be updated, because Android only accepts an update signed by the same key.
#
# Usage:
#   ./scripts/make_release_keystore.sh                 # writes $HOME/.pockr/release.keystore
#   ./scripts/make_release_keystore.sh /path/to/x.keystore
#
# keytool runs inside the builder image (JDK 17), so no Java is needed on the host.
# It asks for the passwords itself, so they never appear on a command line or in
# shell history. Run `./scripts/build_apk.sh` once first so the image exists.
#
# Afterwards, for release builds:
#   export POCKR_KEYSTORE_FILE=$HOME/.pockr/release.keystore
#   export POCKR_KEYSTORE_PASSWORD=...   POCKR_KEY_PASSWORD=...   POCKR_KEY_ALIAS=pockr

set -e

OUT="${1:-$HOME/.pockr/release.keystore}"
IMAGE_NAME="docker-app-builder"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

mkdir -p "$(dirname "${OUT}")"
OUT_DIR="$(cd "$(dirname "${OUT}")" && pwd)"
OUT_FILE="$(basename "${OUT}")"

case "${OUT_DIR}/" in
    "${PROJECT_ROOT}"/*)
        echo "ERROR: ${OUT_DIR} is inside the repo. Choose a path outside ${PROJECT_ROOT}."
        exit 1 ;;
esac
if [ -e "${OUT_DIR}/${OUT_FILE}" ]; then
    echo "ERROR: ${OUT_DIR}/${OUT_FILE} already exists. Refusing to overwrite a signing key."
    exit 1
fi
if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
    echo "ERROR: builder image '${IMAGE_NAME}' not found. Run ./scripts/build_apk.sh once first."
    exit 1
fi

chmod 700 "${OUT_DIR}" 2>/dev/null || true
docker run --rm -it \
    --platform linux/amd64 \
    --user "$(id -u):$(id -g)" \
    -v "${OUT_DIR}:/keys" \
    "${IMAGE_NAME}" \
    keytool -genkeypair -v \
        -keystore "/keys/${OUT_FILE}" \
        -alias pockr \
        -keyalg RSA -keysize 4096 \
        -validity 10000

chmod 600 "${OUT_DIR}/${OUT_FILE}"
echo ""
echo "Created ${OUT_DIR}/${OUT_FILE}  (alias: pockr)"
echo "Back it up now, together with both passwords."
