#!/bin/bash
# Klik dua kali file ini untuk menghapus DynaIsland dari Mac.
clear
echo "Menghapus DynaIsland..."

pkill -x DynaIsland 2>/dev/null || true
sleep 0.3
rm -rf "/Applications/DynaIsland.app"
defaults delete local.dynaisland.app >/dev/null 2>&1 || true        # pengaturan (maskot, kota, dll.)
tccutil reset AppleEvents local.dynaisland.app >/dev/null 2>&1 || true   # izin Automation
tccutil reset All local.dynaisland.app >/dev/null 2>&1 || true           # izin lain
security delete-keychain "${HOME}/Library/Keychains/dynaisland-signing.keychain-db" >/dev/null 2>&1 || true

osascript -e 'display notification "DynaIsland sudah dihapus dari Mac." with title "DynaIsland"' >/dev/null 2>&1
echo
echo "Selesai. DynaIsland sudah dihapus. Jendela ini boleh ditutup."
