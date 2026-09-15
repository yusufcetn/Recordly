#!/usr/bin/env bash
# Creates a self-signed code signing identity in the login keychain for local
# macOS builds (npm run build:mac:local).
#
# macOS ties Accessibility permission to the app's code signature. An unsigned
# (ad-hoc) build gets a new signature on every rebuild, and its signature
# identifier ("Electron") does not match the bundle ID, so the native cursor
# helper is denied even when Recordly itself shows as allowed. Signing every
# local build with this one certificate keeps the permission across rebuilds.
set -euo pipefail

IDENTITY_NAME="${RECORDLY_SIGNING_IDENTITY:-Recordly Local Code Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "\"$IDENTITY_NAME\""; then
	echo "Signing identity \"$IDENTITY_NAME\" already exists."
	exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat >"$WORK_DIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# Use the system LibreSSL: its PKCS#12 output is importable by `security`
# without the -legacy flag Homebrew's OpenSSL 3 would need.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
	-keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" -config "$WORK_DIR/cert.cnf"

# Throwaway passphrase that only protects the temporary .p12 file.
P12_PASSPHRASE="$(uuidgen)"
/usr/bin/openssl pkcs12 -export -name "$IDENTITY_NAME" \
	-inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
	-out "$WORK_DIR/identity.p12" -passout "pass:$P12_PASSPHRASE"

security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSPHRASE" -T /usr/bin/codesign

echo "Trusting the certificate for code signing (macOS will ask for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK_DIR/cert.pem"

security find-identity -v -p codesigning | grep -F "\"$IDENTITY_NAME\""
echo "Done. Build with: npm run build:mac:local"
