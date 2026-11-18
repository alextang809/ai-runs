#!/usr/bin/env bash
# Creates a self-signed code signing identity, "AI Runs Local Signing", in the
# login keychain. Run once per Mac. package_app.sh then signs every build with
# it, so macOS keeps the Accessibility permission across rebuilds instead of
# treating each ad-hoc signed build as a new app.
#
# The certificate is only for builds on this Mac; it is not trusted by anyone
# else and is never used for releases.
set -euo pipefail

NAME="AI Runs Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; then
    echo "\"$NAME\" already exists."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/req.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# Apple's /usr/bin/openssl (LibreSSL) writes a PKCS#12 file the keychain can import.
OPENSSL=/usr/bin/openssl
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/req.cnf" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout pass:airuns

# -T lets codesign use the key without asking each time.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P airuns -T /usr/bin/codesign >/dev/null

echo "Created \"$NAME\" in the login keychain."
echo "Rebuild with ./Scripts/install_local.sh and allow Accessibility once more; later builds keep it."
