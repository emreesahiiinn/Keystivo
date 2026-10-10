#!/bin/bash
# Creates a self-signed code-signing certificate in the login keychain and points
# Config/Local.xcconfig at it.
#
# Why: macOS ties privacy permissions (Accessibility, Screen Recording) to the
# app's code signature. Ad-hoc signatures change with every build, so grants are
# lost after each rebuild. A certificate gives the app a stable identity
# ("identifier … and certificate leaf = H…") that survives rebuilds.
#
# The certificate only exists on this Mac and is only used for local builds.
# Remove it any time in Keychain Access (login › My Certificates).
#
# Usage: Scripts/make-signing-cert.sh [certificate name]
set -euo pipefail

NAME="${1:-Keystivo Local Signing}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
LOCAL_CONFIG="$ROOT/Config/Local.xcconfig"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "✓ Certificate \"$NAME\" already exists."
else
    WORK="$(mktemp -d)"
    trap 'rm -rf "${WORK:?}"' EXIT
    cat > "$WORK/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
    PASSWORD="$(/usr/bin/openssl rand -hex 16)"
    /usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -out "$WORK/cert.p12" -passout "pass:$PASSWORD"
    # -T lets codesign use the key without a keychain prompt on every build.
    security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
    echo "✓ Created certificate \"$NAME\" in the login keychain."
fi

if [ -f "$LOCAL_CONFIG" ]; then
    echo "• $LOCAL_CONFIG already exists; left unchanged."
else
    cat > "$LOCAL_CONFIG" <<EOF
// Machine-specific signing (git-ignored). Created by Scripts/make-signing-cert.sh.
// A stable certificate keeps Accessibility / Screen Recording grants across rebuilds.
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = $NAME
DEVELOPMENT_TEAM =
KEYSTIVO_ADHOC_REQUIREMENT =
EOF
    echo "✓ Wrote $LOCAL_CONFIG"
fi

echo
echo "Next: rebuild, then in System Settings › Privacy & Security remove the old"
echo "Keystivo entries (−) once and grant access again. Grants now survive rebuilds."
