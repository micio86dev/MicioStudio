#!/usr/bin/env bash
# One-time: create a STABLE self-signed code-signing identity in the login keychain.
#
# Why: the app is signed with this identity (see app/project.yml CODE_SIGN_IDENTITY).
# Ad-hoc ("-") signing changes the code hash on every rebuild, which INVALIDATES the
# Screen Recording / Accessibility (TCC) grants — macOS then re-prompts forever and
# recording fails. A stable identity keeps those grants valid across rebuilds.
#
# Idempotent: does nothing if the identity already exists. No sudo required (login
# keychain). After running, grant the app its permissions ONCE; they then persist.
set -euo pipefail

CN="MicioDev Local Signing"

if security find-identity -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "Identity '$CN' already present — nothing to do."
  exit 0
fi

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

echo "Creating self-signed code-signing certificate '$CN'…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$W/key.pem" -out "$W/cert.pem" -subj "/CN=$CN" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# -legacy: macOS `security` can't import OpenSSL 3's default PKCS12 MAC.
openssl pkcs12 -export -legacy -out "$W/id.p12" -inkey "$W/key.pem" -in "$W/cert.pem" \
  -name "$CN" -passout pass:miciodev >/dev/null 2>&1

security import "$W/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P miciodev -A -T /usr/bin/codesign >/dev/null

echo "Done. codesign can now sign with '$CN' (trust is not required for local signing)."
echo "Next: build the app, launch it, and grant its permissions once."
