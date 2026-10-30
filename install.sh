#!/bin/bash
# Pasang atau perbarui DynaIsland dengan satu baris di Terminal:
#   curl -fsSL https://raw.githubusercontent.com/barisbaru19-ux/dynaisland/main/install.sh | bash
#
# Mengunduh app siap pakai dari GitHub Releases (tidak perlu Xcode / Command Line Tools).
# Kalau belum ada, build dari kode sumber (butuh Command Line Tools).
set -euo pipefail

REPO="barisbaru19-ux/dynaisland"
APP_NAME="DynaIsland"
DEST="/Applications/${APP_NAME}.app"
RELEASE_URL="https://github.com/${REPO}/releases/latest/download/${APP_NAME}-app.zip"
SOURCE_URL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/main"

echo ""
echo "  DynaIsland — memasang..."
echo ""

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "DynaIsland hanya untuk Mac."
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

if curl -fsSL "${RELEASE_URL}" -o "${TMP}/app.zip"; then
  echo "• App siap pakai terunduh"
  ditto -x -k "${TMP}/app.zip" "${TMP}/app"
  pkill -x "${APP_NAME}" 2>/dev/null || true
  sleep 0.5
  rm -rf "${DEST}"
  ditto "${TMP}/app/${APP_NAME}.app" "${DEST}"
  xattr -cr "${DEST}" 2>/dev/null || true
  open "${DEST}"
else
  echo "• Versi siap pakai belum ada, build dari kode sumber..."
  if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    echo ""
    echo "Command Line Tools dari Apple perlu dipasang dulu (jendelanya sudah muncul)."
    echo "Setelah selesai, jalankan perintah ini lagi."
    exit 1
  fi
  mkdir -p "${TMP}/src"
  curl -fsSL "${SOURCE_URL}" | tar -xz -C "${TMP}/src"
  cd "${TMP}"/src/*/
  /bin/bash ./build.sh --install
fi

osascript -e 'display notification "Sudah terpasang dan berjalan. Cari ikon kapsul di menu bar." with title "DynaIsland"' >/dev/null 2>&1 || true
echo ""
echo "  Selesai! DynaIsland sudah jalan — lihat ikon kapsul di menu bar."
echo "  Untuk memperbarui nanti: ikon kapsul → Perbarui DynaIsland."
echo ""
