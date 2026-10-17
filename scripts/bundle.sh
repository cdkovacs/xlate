#!/bin/zsh
# Build release and assemble a signed build/Xlate.app. Signing with the same
# identity every time keeps the audio capture permission across rebuilds.
#
# Release builds (packaging/build_pkg.sh) also set:
#   VERSION=1.2.3          stamp CFBundleShortVersionString/CFBundleVersion
#   XLATE_TIMESTAMP=1      secure timestamp, which notarization requires
#   XLATE_KEYCHAIN=path    sign from a dedicated build keychain
#   XLATE_SIGN_ID=-        ad-hoc sign (unsigned test builds)
set -e -o pipefail
cd "${0:A:h}/.."
: ${XLATE_SIGN_ID:=5537036EB2AB6A874BE56556B6ED1EB56729BA71}
swift build -c release --build-system native 2>&1 | grep -v "has been deprecated"
BIN=$(swift build -c release --build-system native --show-bin-path 2>/dev/null)
APP=build/Xlate.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
cp $BIN/Xlate $APP/Contents/MacOS/Xlate
cp Resources/Info.plist $APP/Contents/Info.plist
if [[ -n $VERSION ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" $APP/Contents/Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" $APP/Contents/Info.plist
fi
SIGN_ARGS=(--force --options runtime --sign "$XLATE_SIGN_ID")
[[ $XLATE_TIMESTAMP == 1 ]] && SIGN_ARGS+=(--timestamp) || SIGN_ARGS+=(--timestamp=none)
[[ -n $XLATE_KEYCHAIN ]] && SIGN_ARGS+=(--keychain "$XLATE_KEYCHAIN")
codesign $SIGN_ARGS $APP
echo "built $APP"
