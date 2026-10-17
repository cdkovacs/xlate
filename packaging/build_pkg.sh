#!/bin/zsh
# Build the Xlate .pkg: assembles Xlate.app with scripts/bundle.sh, wraps it in an
# installer that drops it into /Applications, then signs, notarizes and staples.
# Apple Silicon only, matching the app's macOS 26 floor and CoreML speech engine.
#
# Quick unsigned test build (ad-hoc signed app; Gatekeeper will warn):
#     SIGN=0 packaging/build_pkg.sh
#
# Full signed + notarized build:
#     SIGN=1 VERSION=1.2.3 \
#     DEVID_APP="Developer ID Application: Your Name (TEAMID)" \
#     DEVID_INSTALLER="Developer ID Installer: Your Name (TEAMID)" \
#     NOTARY_PROFILE="xlate-notary" \
#     SIGN_KEYCHAIN="$HOME/Library/Keychains/xlate-build.keychain-db" \
#     packaging/build_pkg.sh
set -eu

# ----------------------------- configuration -----------------------------
VERSION="${VERSION:-0.0.0}"
PKG_ID="${PKG_ID:-dev.ckovacs.xlate.pkg}"

SIGN="${SIGN:-1}"
DEVID_APP="${DEVID_APP:-}"
DEVID_INSTALLER="${DEVID_INSTALLER:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-xlate-notary}"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-}"
NOTARIZE="${NOTARIZE:-$SIGN}"

HERE="${0:A:h}"
REPO="${HERE:h}"
BUILD="$HERE/build"
OUT="$HERE/dist"
KEYCHAIN_ARG=()
[ -n "$SIGN_KEYCHAIN" ] && KEYCHAIN_ARG=(--keychain "$SIGN_KEYCHAIN")

# A locked keychain makes codesign fail with errSecInternalComponent. Unlock it
# (and re-assert that Apple tools may use the key without a GUI prompt) when a
# password is supplied.
if [ "$SIGN" = "1" ] && [ -n "$SIGN_KEYCHAIN" ] && [ -n "${SIGN_KEYCHAIN_PASSWORD:-}" ]; then
    echo "==> unlock signing keychain"
    security unlock-keychain -p "$SIGN_KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -k "$SIGN_KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
fi

echo "==> clean staging"
rm -rf "$BUILD" && mkdir -p "$BUILD/payload" "$BUILD/scripts" "$OUT"

# ----------------------------- app bundle -----------------------------
echo "==> build + sign Xlate.app ($VERSION)"
if [ "$SIGN" = "1" ]; then
    : "${DEVID_APP:?set DEVID_APP for a signed build (or use SIGN=0)}"
    VERSION="$VERSION" XLATE_SIGN_ID="$DEVID_APP" XLATE_TIMESTAMP=1 \
        XLATE_KEYCHAIN="$SIGN_KEYCHAIN" "$REPO/scripts/bundle.sh"
else
    VERSION="$VERSION" XLATE_SIGN_ID=- "$REPO/scripts/bundle.sh"
fi
codesign --verify --strict --verbose=2 "$REPO/build/Xlate.app"
ditto "$REPO/build/Xlate.app" "$BUILD/payload/Xlate.app"

echo "==> stage installer scripts"
cp "$HERE/scripts/preinstall" "$HERE/scripts/postinstall" "$BUILD/scripts/"
chmod +x "$BUILD/scripts/preinstall" "$BUILD/scripts/postinstall"

# --component-plist keeps the bundle non-relocatable, so Installer always writes
# /Applications/Xlate.app instead of "upgrading" a dev copy in build/.
echo "==> pkgbuild component"
pkgbuild --root "$BUILD/payload" --component-plist "$HERE/component.plist" \
    --scripts "$BUILD/scripts" --identifier "$PKG_ID" --version "$VERSION" \
    --install-location /Applications "$BUILD/Xlate-component.pkg"

# ----------------------------- product + sign -----------------------------
echo "==> productbuild"
DIST="$BUILD/distribution.xml"
sed -e "s|__VERSION__|$VERSION|g" "$HERE/distribution.xml" > "$DIST"
PRODUCT_UNSIGNED="$BUILD/Xlate-unsigned.pkg"
productbuild --distribution "$DIST" --resources "$HERE/resources" \
    --package-path "$BUILD" "$PRODUCT_UNSIGNED"

FINAL="$OUT/Xlate-$VERSION.pkg"
if [ "$SIGN" = "1" ]; then
    : "${DEVID_INSTALLER:?set DEVID_INSTALLER for a signed build}"
    echo "==> productsign (Developer ID Installer)"
    productsign --sign "$DEVID_INSTALLER" "${KEYCHAIN_ARG[@]}" "$PRODUCT_UNSIGNED" "$FINAL"
else
    cp "$PRODUCT_UNSIGNED" "$FINAL"
fi

if [ "$NOTARIZE" = "1" ]; then
    echo "==> notarize (uploads to Apple and waits)"
    xcrun notarytool submit "$FINAL" --keychain-profile "$NOTARY_PROFILE" \
        "${KEYCHAIN_ARG[@]}" --wait
    echo "==> staple"
    xcrun stapler staple "$FINAL"
    echo "==> gatekeeper check"
    spctl -a -vvv --type install "$FINAL" || true
    pkgutil --check-signature "$FINAL" || true
fi

echo
echo "Built installer: $FINAL"
[ "$SIGN" = "1" ] || echo "   (SIGN=0: unsigned, for local testing only)"
