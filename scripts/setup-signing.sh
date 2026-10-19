#!/bin/zsh
# Creates a self-signed "Claude Eye Local Signing" certificate in your login keychain.
# build.sh signs with it so macOS keeps the Screen Recording permission across rebuilds.
# Run once. The private key only lives in your keychain; temporary files are deleted.
set -euo pipefail

NAME="Claude Eye Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists in your keychain."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=$(openssl rand -hex 16)

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

# macOS's keychain only understands the older PKCS#12 encryption; OpenSSL 3+ needs -legacy.
LEGACY=()
openssl version | grep -qE '^OpenSSL [3-9]' && LEGACY=(-legacy)
openssl pkcs12 -export "${LEGACY[@]}" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"

security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". Run ./build.sh again."
