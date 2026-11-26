#!/bin/sh
# Makes the self-signed certificate "Phone Link Dev" in the login keychain. build.sh signs the app with it.
# With a stable signature, macOS keeps the Accessibility and Screen Recording permissions after each build.
# Ad hoc signatures change with each build, and macOS then asks for the permissions again.
set -e
NAME="Phone Link Dev"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "The certificate \"$NAME\" is already in the keychain."
  exit 0
fi
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/cert.conf" <<EOF
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
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$DIR/cert.conf" -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
PASS=$(openssl rand -hex 16)
# macOS reads only the old PKCS12 algorithms (3DES, SHA-1). OpenSSL 3 uses AES and SHA-256 by default.
openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "$NAME" -out "$DIR/id.p12" -passout "pass:$PASS"
security import "$DIR/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Made the certificate \"$NAME\"."
