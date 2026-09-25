#!/bin/bash
# Run the Swift test suite. With only the Command Line Tools installed (no
# Xcode), Swift Testing lives outside the default search paths, so point every
# target — including SwiftPM's generated test runner — at it.
set -euo pipefail
cd "$(dirname "$0")/../app"
CLT=/Library/Developer/CommandLineTools/Library/Developer
FLAGS=()
if [[ ! -d /Applications/Xcode.app && -d "$CLT/Frameworks/Testing.framework" ]]; then
  FLAGS=(-Xswiftc -F -Xswiftc "$CLT/Frameworks"
         -Xlinker -F -Xlinker "$CLT/Frameworks"
         -Xlinker -rpath -Xlinker "$CLT/Frameworks"
         -Xlinker -rpath -Xlinker "$CLT/usr/lib")
fi
exec swift test "${FLAGS[@]}" "$@"
