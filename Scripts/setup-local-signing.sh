#!/bin/bash
set -euo pipefail

identity_name="${LARK_PEEK_CODESIGN_IDENTITY:-Lark Peek Local Code Signing}"
login_keychain="$(security default-keychain -d user | tr -d ' \"')"

if security find-identity -v -p codesigning "$login_keychain" 2>/dev/null \
    | grep -Fq "\"$identity_name\""; then
  echo "Signing identity already exists: $identity_name"
  exit 0
fi

if security find-certificate -c "$identity_name" "$login_keychain" >/dev/null 2>&1; then
  trust_dir="$(mktemp -d "${TMPDIR:-/tmp}/lark-peek-trust.XXXXXX")"
  cleanup_trust_dir() {
    if [[ -d "$trust_dir" ]]; then
      find "$trust_dir" -type f -delete
      find "$trust_dir" -depth -type d -delete
    fi
  }
  trap cleanup_trust_dir EXIT
  cert_path="$trust_dir/certificate.pem"
  security find-certificate -c "$identity_name" -p "$login_keychain" \
    | openssl x509 -out "$cert_path"
  security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$login_keychain" \
    "$cert_path"
  if ! security find-identity -v -p codesigning "$login_keychain" \
      | grep -Fq "\"$identity_name\""; then
    echo "The existing certificate is still not a valid code-signing identity." >&2
    exit 1
  fi
  echo "Trusted existing signing identity: $identity_name"
  exit 0
fi

signing_dir="$(mktemp -d "${TMPDIR:-/tmp}/lark-peek-signing.XXXXXX")"
cleanup() {
  if [[ -d "$signing_dir" ]]; then
    find "$signing_dir" -type f -delete
    find "$signing_dir" -depth -type d -delete
  fi
}
trap cleanup EXIT

key_path="$signing_dir/private-key.pem"
cert_path="$signing_dir/certificate.pem"
p12_path="$signing_dir/identity.p12"
p12_pass="$(openssl rand -hex 24)"

openssl req \
  -x509 \
  -newkey rsa:3072 \
  -sha256 \
  -nodes \
  -days 3650 \
  -subj "/CN=$identity_name/O=Lark Peek Local Development" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout "$key_path" \
  -out "$cert_path"

openssl pkcs12 \
  -export \
  -inkey "$key_path" \
  -in "$cert_path" \
  -name "$identity_name" \
  -passout "pass:$p12_pass" \
  -out "$p12_path"

security import "$p12_path" \
  -k "$login_keychain" \
  -P "$p12_pass" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

# Trust only this self-signed certificate for code signing. macOS may show a
# one-time authentication dialog while changing the user's trust settings.
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$login_keychain" \
  "$cert_path"

if ! security find-identity -v -p codesigning "$login_keychain" \
    | grep -Fq "\"$identity_name\""; then
  echo "Created the certificate, but macOS does not consider it a valid code-signing identity." >&2
  exit 1
fi

echo "Created signing identity: $identity_name"
