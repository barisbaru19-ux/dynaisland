#!/bin/bash
# Klik dua kali file ini untuk memasang atau memperbarui DynaIsland.
cd "$(dirname "$0")" || exit 1
clear
echo "==============================="
echo "  Memasang DynaIsland..."
echo "==============================="
echo

# File hasil download diberi tanda karantina oleh macOS. Lepaskan dari folder ini
# supaya "Hapus DynaIsland" nanti bisa dibuka tanpa peringatan lagi.
xattr -dr com.apple.quarantine . 2>/dev/null || true
chmod +x build.sh "Hapus DynaIsland.command" 2>/dev/null || true

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Command Line Tools (compiler Swift) belum terpasang."
  echo "Jendela pemasangnya akan muncul. Setelah selesai, klik dua kali"
  echo "\"Pasang DynaIsland\" lagi."
  xcode-select --install >/dev/null 2>&1 || true
  osascript -e 'display dialog "Pasang Command Line Tools dulu lewat jendela yang muncul (gratis, sekitar 5–10 menit). Setelah selesai, klik dua kali “Pasang DynaIsland” lagi." buttons {"OK"} default button 1 with title "DynaIsland"' >/dev/null 2>&1
  exit 1
fi

if ./build.sh --install; then
  osascript -e 'display notification "Sudah terpasang dan berjalan. Cari ikon kapsul di menu bar." with title "DynaIsland"' >/dev/null 2>&1
  echo
  echo "Selesai! DynaIsland sudah terpasang di Applications dan sedang berjalan."
  echo "Jendela ini boleh ditutup."
else
  echo
  echo "Build gagal. Salin pesan error di atas untuk minta bantuan."
  osascript -e 'display alert "DynaIsland gagal dipasang" message "Salin pesan error di jendela Terminal untuk minta bantuan."' >/dev/null 2>&1
  exit 1
fi
