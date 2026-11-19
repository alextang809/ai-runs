#!/usr/bin/env bash
# Creates or checks a self-signed "AI Runs Local Signing" identity in the login
# keychain. Reusing this identity lets macOS recognize later local app builds.
# It is never used for releases or trusted by other machines.
set -euo pipefail
umask 077

NAME="AI Runs Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Self-signed identities can be usable without a trusted certificate anchor.
# An enumeration error must not create another identity and change the app's key.
if ! identities="$(security find-identity -p codesigning 2>/dev/null)"; then
    echo "Could not inspect signing identities. Existing keys were left unchanged." >&2
    exit 1
fi

signing_tmp="$(mktemp -d)"
trap 'rm -rf "$signing_tmp"' EXIT

if grep -qF "\"$NAME\"" <<< "$identities"; then
    echo "\"$NAME\" already exists."
else
    cat > "$signing_tmp/req.cnf" <<CNF
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

    # Apple's LibreSSL writes a PKCS#12 file the keychain can import.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$signing_tmp/key.pem" -out "$signing_tmp/cert.pem" -config "$signing_tmp/req.cnf" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$signing_tmp/key.pem" -in "$signing_tmp/cert.pem" \
        -name "$NAME" -out "$signing_tmp/identity.p12" -passout pass:airuns

    # Register codesign for this key only. macOS can still require user approval.
    security import "$signing_tmp/identity.p12" -k "$KEYCHAIN" -P airuns -T /usr/bin/codesign >/dev/null
    echo "Created \"$NAME\" in the login keychain."
fi

echo "Checking that codesign can use \"$NAME\"."
echo "If macOS asks, enter your login keychain password in the macOS dialog and choose Always Allow for codesign."
echo "This script never reads or stores that password."
cp /usr/bin/true "$signing_tmp/signing-check"
if ! codesign --force --sign "$NAME" "$signing_tmp/signing-check"; then
    echo "Signing check failed. Keep the existing identity and rerun this script after approving codesign in macOS." >&2
    exit 1
fi
codesign --verify --strict "$signing_tmp/signing-check"
echo "Signing check passed. Rebuild with ./Scripts/install_local.sh."
echo "Allow Accessibility once for the signed app; later builds with this identity keep it."
