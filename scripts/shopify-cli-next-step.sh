#!/usr/bin/env bash
set -euo pipefail

echo "HENVALT Shopify CLI environment"
shopify version

echo
echo "1. Authenticate to the Shopify account that owns Client ID 1c0fd15c032fa26cd15ad7a63577a506:"
echo "   shopify auth login"
echo
echo "2. Generate a temporary native Web Pixel scaffold to obtain Shopify's generated UID:"
echo "   shopify app generate extension --template web_pixel --name henvalt-uid-bootstrap"
echo "   Choose JavaScript."
echo
echo "3. Copy the generated uid line from extensions/henvalt-uid-bootstrap/shopify.extension.toml"
echo "   into extensions/henvalt-web-pixel/shopify.extension.toml, then delete the temporary folder."
echo
echo "4. Create an unreleased app version for validation:"
echo "   shopify app deploy --no-release"
echo
echo "Review the app/extension mapping and warnings. Do not release until the generated UID is committed and reviewed."
