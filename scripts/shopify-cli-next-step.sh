#!/usr/bin/env bash
set -euo pipefail

echo "HENVALT Shopify CLI environment"
shopify version

echo
echo "Next: authenticate to the Shopify account that owns Client ID 1c0fd15c032fa26cd15ad7a63577a506."
echo "Run: shopify auth login"
echo
echo "Then run the one-time UID mapping and create an unreleased version:"
echo "shopify app deploy --no-release"
echo
echo "Review the CLI confirmation carefully. Do not release the app version yet."
