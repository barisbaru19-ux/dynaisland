#!/usr/bin/env bash
# Build DynaIsland.app tanpa Xcode — cukup Command Line Tools.
#   ./build.sh            → build lalu jalankan dari folder build/
#   ./build.sh --install  → build, pasang ke /Applications, lalu jalankan
#   ./build.sh --release  → build universal (Apple Silicon + Intel) untuk dibagikan, tanpa menjalankan
# Variabel opsional: BUILD_NUMBER=12 (nomor versi yang dicek oleh menu "Perbarui").
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DynaIsland"
APP="build/${APP_NAME}.app"
MODE="${1:-}"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "❌ Swift compiler belum ada."
  echo "   Jalankan:  xcode-select --install"
  echo "   lalu ulangi ./build.sh"
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
if [[ "${MODE}" == "--release" ]]; then
  ARCHS=(arm64 x86_64)
else
  ARCHS=("$(uname -m)")                 # arm64 di M1
fi

rm -rf "${APP}" build/obj
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" build/obj

BINARIES=()
for ARCH in "${ARCHS[@]}"; do
  echo "Compile untuk ${ARCH}..."
  xcrun swiftc \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -sdk "${SDK}" \
    -target "${ARCH}-apple-macos12.0" \
    Sources/*.swift \
    -o "build/obj/${APP_NAME}-${ARCH}"
  BINARIES+=("build/obj/${APP_NAME}-${ARCH}")
done

if [[ ${#BINARIES[@]} -gt 1 ]]; then
  lipo -create "${BINARIES[@]}" -output "${APP}/Contents/MacOS/${APP_NAME}"
else
  cp "${BINARIES[0]}" "${APP}/Contents/MacOS/${APP_NAME}"
fi

cp Info.plist "${APP}/Contents/Info.plist"

# Ikon app: Resources/AppIcon.png (1024 px) → AppIcon.icns
make_icon() {
  [[ -f Resources/AppIcon.png ]] || return 0
  local ICONSET="build/obj/AppIcon.iconset"
  rm -rf "${ICONSET}"
  mkdir -p "${ICONSET}"
  for SIZE in 16 32 128 256 512; do
    sips -z "${SIZE}" "${SIZE}" Resources/AppIcon.png --out "${ICONSET}/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z "$((SIZE * 2))" "$((SIZE * 2))" Resources/AppIcon.png --out "${ICONSET}/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  iconutil -c icns "${ICONSET}" -o "${APP}/Contents/Resources/AppIcon.icns"
}
make_icon || echo "⚠️  Ikon app dilewati"
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  plutil -replace CFBundleVersion -string "${BUILD_NUMBER}" "${APP}/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string "1.${BUILD_NUMBER}" "${APP}/Contents/Info.plist"
fi
if [[ "${MODE}" == "--release" ]]; then
  codesign --force --sign - "${APP}" >/dev/null 2>&1   # each Mac re-signs it with its own certificate
else
  /bin/bash ./sign-local.sh "${APP}"
fi
echo "✅ Build selesai: ${APP}"

if [[ "${MODE}" == "--release" ]]; then
  exit 0
fi

# Tutup versi lama yang mungkin masih jalan
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.3

if [[ "${MODE}" == "--install" ]]; then
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "${APP}" /Applications/
  open "/Applications/${APP_NAME}.app"
  echo "📦 Terpasang di /Applications dan sudah jalan."
else
  open "${APP}"
  echo "🚀 Sudah jalan. Pakai  ./build.sh --install  untuk memasang ke /Applications."
fi
