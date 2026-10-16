#!/bin/zsh
# Command Line Tools ship Testing.framework outside the default search path,
# and the default build system fails on this toolchain, so pin both here.
set -e -o pipefail
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
cd "${0:A:h}/.."
swift test --build-system native \
  -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F "$@" 2>&1 \
  | grep -v "build-system native' has been deprecated"
