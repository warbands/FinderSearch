#!/bin/zsh
# Make a self-signed code-signing identity for local builds. macOS ties Full
# Disk Access and Keychain access to an app's signature, and an ad-hoc
# signature changes with every build, so each rebuild loses both. Signed with
# this identity, rebuilds keep them. scripts/build.sh uses it when present.
#
# Only for builds on this Mac: releases need a Developer ID (docs/RELEASING.md).
# To remove it: security delete-identity -c "FinderSearch Local Dev"
set -euo pipefail
name="FinderSearch Local Dev"
if security find-certificate -c "$name" >/dev/null 2>&1; then
    print "\"$name\" is already in your keychain."
    exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
# The system's LibreSSL writes a .p12 the Keychain imports as is.
ssl=/usr/bin/openssl
"$ssl" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
pass="$("$ssl" rand -hex 16)"
"$ssl" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" \
    -passout "pass:$pass" -out "$tmp/identity.p12"
# Only codesign may use the private key without asking.
security import "$tmp/identity.p12" -k "$(security login-keychain | tr -d ' "')" \
    -P "$pass" -T /usr/bin/codesign >/dev/null
print "Added \"$name\" to your login keychain; scripts/build.sh signs with it from now on."
