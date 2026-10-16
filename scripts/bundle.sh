#!/bin/zsh
# Build release and assemble a signed build/Xlate.app. Signing with the same
# identity every time keeps the audio capture permission across rebuilds.
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
codesign --force --options runtime --timestamp=none --sign "$XLATE_SIGN_ID" $APP
echo "built $APP"
