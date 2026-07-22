#!/bin/bash
# OPTIONAL, run ONCE. Creates a stable self-signed code-signing identity ("OpenSong Local")
# in your login keychain so that macOS permissions (Automation/Music, Screen Recording)
# PERSIST across rebuilds. Without this, install.sh signs ad-hoc and permissions re-prompt
# after each update. May prompt for your login password when importing the key.
set -euo pipefail
NAME="OpenSong Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Identity “$NAME” already exists — nothing to do."; exit 0
fi

TMP="$(mktemp -d)"; cd "$TMP"
echo "Generating a self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass: -name "$NAME" >/dev/null 2>&1

echo "Importing into your login keychain (you may be asked for your login password)…"
security import id.p12 -k "$KEYCHAIN" -P "" -T /usr/bin/codesign >/dev/null 2>&1 || {
  echo "Import failed. You can also create it in Keychain Access →"
  echo "  Certificate Assistant → Create a Certificate → Name: '$NAME', Type: Code Signing, Self-Signed."
  exit 1
}
# Allow codesign to use the key without an interactive prompt each time.
security set-key-partition-list -S apple-tool:,apple: -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "✅ Created identity “$NAME”. Now run ./Scripts/install.sh — it will sign with it,"
  echo "   and your macOS permissions will persist across future updates."
else
  echo "Created the cert but it isn't showing as a codesigning identity yet; a reboot or"
  echo "Keychain Access trust setting may be needed. install.sh will fall back to ad-hoc."
fi
