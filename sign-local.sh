#!/bin/bash
# Menandatangani DynaIsland.app dengan sertifikat milik Mac ini (dibuat sekali, otomatis).
# Dengan tanda tangan yang sama di setiap update, macOS mengingat izin yang sudah diberikan
# (Aksesibilitas, Kalender, folder, kontrol musik) dan tidak menanyakannya lagi.
#
# Pemakaian:  ./sign-local.sh /Applications/DynaIsland.app
# Sertifikat dan kuncinya hanya disimpan di Mac ini, di keychain terpisah "dynaisland-signing".
set -u

APP="${1:?pakai: sign-local.sh /path/ke/DynaIsland.app}"
NAME="DynaIsland Local Signing"
KEYCHAIN="${HOME}/Library/Keychains/dynaisland-signing.keychain-db"
PASSWORD="dynaisland-local-signing"

fallback() {
  echo "• Tanda tangan lokal tidak bisa dibuat ($1), pakai tanda tangan biasa."
  for FRAMEWORK in "${APP}"/Contents/Frameworks/*.framework; do
    [[ -d "${FRAMEWORK}" ]] && codesign --force --sign - "${FRAMEWORK}" >/dev/null 2>&1
  done
  codesign --force --sign - "${APP}" >/dev/null 2>&1
  exit 0
}

if [[ ! -f "${KEYCHAIN}" ]]; then
  security create-keychain -p "${PASSWORD}" "${KEYCHAIN}" >/dev/null 2>&1 || fallback "keychain"
fi
security unlock-keychain -p "${PASSWORD}" "${KEYCHAIN}" >/dev/null 2>&1 || fallback "unlock"
security set-keychain-settings "${KEYCHAIN}" >/dev/null 2>&1   # never auto-lock

if ! security find-certificate -c "${NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
  WORK="$(mktemp -d)"
  cat > "${WORK}/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${NAME}
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "${WORK}/cert.cnf" \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" >/dev/null 2>&1 || fallback "openssl req"
  /usr/bin/openssl pkcs12 -export -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" -name "${NAME}" \
    -out "${WORK}/cert.p12" -passout "pass:${PASSWORD}" >/dev/null 2>&1 || fallback "openssl pkcs12"
  security import "${WORK}/cert.p12" -k "${KEYCHAIN}" -P "${PASSWORD}" -T /usr/bin/codesign >/dev/null 2>&1 \
    || fallback "import"
  # Lets codesign use the key without asking for a password.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${PASSWORD}" "${KEYCHAIN}" >/dev/null 2>&1
  rm -rf "${WORK}"
fi

# codesign looks for identities in the keychain search list.
if ! security list-keychains -d user | grep -q "dynaisland-signing"; then
  # shellcheck disable=SC2046
  security list-keychains -d user -s "${KEYCHAIN}" $(security list-keychains -d user | tr -d '"') >/dev/null 2>&1
fi

# Bundled frameworks first (Now Playing adapter), then the app itself.
for FRAMEWORK in "${APP}"/Contents/Frameworks/*.framework; do
  [[ -d "${FRAMEWORK}" ]] || continue
  codesign --force --sign "${NAME}" --keychain "${KEYCHAIN}" "${FRAMEWORK}" >/dev/null 2>&1 || fallback "framework"
done
codesign --force --sign "${NAME}" --keychain "${KEYCHAIN}" "${APP}" >/dev/null 2>&1 || fallback "codesign"
codesign --verify "${APP}" >/dev/null 2>&1 || fallback "verify"
echo "• Ditandatangani dengan sertifikat Mac ini (izin tidak perlu diulang saat update)"
