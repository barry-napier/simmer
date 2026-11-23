#!/usr/bin/env bash
# One-time setup: puts the 5 secrets the Release workflow needs into GitHub.
# Run it yourself in Terminal, so macOS can show its keychain prompts.
#
#   ./scripts/setup-secrets.sh
#
# It asks for your Apple ID and an app-specific password (make one at
# account.apple.com > Sign-In and Security > App-Specific Passwords).
# No secret is printed or kept on disk.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="barry-napier/simmer"
SPARKLE_BIN="build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/generate_keys" ]] || { echo "error: run scripts/build.sh once first." >&2; exit 1; }

WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "1/3  Copying your Developer ID certificate from the keychain."
echo "     macOS may ask for your login password. Click Allow (or Always Allow)."
TEMP_PASS=$(openssl rand -hex 16)
security export -k ~/Library/Keychains/login.keychain-db -t identities -f pkcs12 \
  -P "$TEMP_PASS" -o "$WORK/all.p12"
openssl pkcs12 -in "$WORK/all.p12" -passin pass:"$TEMP_PASS" -nodes -out "$WORK/all.pem" 2>/dev/null \
  || openssl pkcs12 -in "$WORK/all.p12" -passin pass:"$TEMP_PASS" -nodes -legacy -out "$WORK/all.pem"
# Keep only the Developer ID certificate and its key, not your other identities.
python3 -I - "$WORK" <<'PY'
import re, sys
work = sys.argv[1]
text = open(f"{work}/all.pem").read()
blocks = re.findall(r"(Bag Attributes.*?-----END [A-Z ]+-----\n?)", text, re.S)
def attr(b, n):
    m = re.search(n + r": ?(.*)", b)
    return m.group(1).strip() if m else None
cert = next(b for b in blocks if "CERTIFICATE" in b
            and (attr(b, "friendlyName") or "").startswith("Developer ID Application"))
key = next(b for b in blocks if "PRIVATE KEY" in b and attr(b, "localKeyID") == attr(cert, "localKeyID"))
strip = lambda b: b[b.index("-----BEGIN"):]
open(f"{work}/dev.pem", "w").write(strip(cert) + strip(key))
PY
CERT_PASS=$(openssl rand -base64 24 | tr -d '/+=')
openssl pkcs12 -export -legacy -in "$WORK/dev.pem" -name "Developer ID Application" \
    -passout pass:"$CERT_PASS" -out "$WORK/dev.p12" 2>/dev/null \
  || openssl pkcs12 -export -in "$WORK/dev.pem" -name "Developer ID Application" \
    -passout pass:"$CERT_PASS" -out "$WORK/dev.p12"
base64 -i "$WORK/dev.p12" | gh secret set MACOS_CERT_P12 --repo "$REPO"
printf '%s' "$CERT_PASS" | gh secret set MACOS_CERT_PASSWORD --repo "$REPO"

echo "2/3  Copying Simmer's update key."
"$SPARKLE_BIN/generate_keys" --account com.barrynapier.simmer -x "$WORK/sparkle.key" >/dev/null
gh secret set SPARKLE_PRIVATE_KEY --repo "$REPO" < "$WORK/sparkle.key"

echo "3/3  Your Apple notary login."
read -r -p "     Apple ID email: " APPLE_ID
read -r -s -p "     App-specific password: " APP_PASS
echo
printf '%s' "$APPLE_ID" | gh secret set NOTARY_APPLE_ID --repo "$REPO"
printf '%s' "$APP_PASS" | gh secret set NOTARY_PASSWORD --repo "$REPO"

echo
gh secret list --repo "$REPO"
echo "Done. Ship the first release with: ./scripts/ship.sh 0.1.0"
