#!/bin/bash
# Prépare build/PillChat.zip à joindre à une release GitHub.
# Signature ad hoc (pas de certificat local) : la même app pour tout le monde.
set -euo pipefail
cd "$(dirname "$0")/.."

NO_DEV_CERT=1 ./scripts/build.sh
rm -f build/PillChat.zip
ditto -c -k --sequesterRsrc --keepParent build/PillChat.app build/PillChat.zip
echo "📦 build/PillChat.zip"
