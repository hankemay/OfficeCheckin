#!/bin/zsh

# Creates a self-contained, ad-hoc signed OfficeCheckin.app ZIP.
# Requires a full Xcode installation (not Command Line Tools alone).
set -euo pipefail

ROOT="${0:A:h:h}"
PROJECT="$ROOT/OfficeCheckin.xcodeproj"
DERIVED_DATA="$ROOT/build/DerivedData"
PRODUCT="$DERIVED_DATA/Build/Products/Release/OfficeCheckin.app"
RELEASE_DIRECTORY="$ROOT/release"
ARCHIVE="$RELEASE_DIRECTORY/OfficeCheckin-macOS.zip"

if ! xcodebuild -version >/dev/null 2>&1; then
  print -u2 "Full Xcode is required. Select it with: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

rm -rf "$DERIVED_DATA" "$RELEASE_DIRECTORY"
mkdir -p "$RELEASE_DIRECTORY"

xcodebuild \
  -project "$PROJECT" \
  -scheme OfficeCheckin \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

if [[ ! -d "$PRODUCT" ]]; then
  print -u2 "Build completed without producing OfficeCheckin.app."
  exit 1
fi

# Ad-hoc signing makes the bundle executable on the build Mac and keeps this
# script usable without an Apple Developer certificate. It is not notarization.
codesign --force --deep --sign - "$PRODUCT"
ditto -c -k --sequesterRsrc --keepParent "$PRODUCT" "$ARCHIVE"

print "Created: $ARCHIVE"
print "Install: unzip it, move OfficeCheckin.app to Applications, then Control-click > Open the first time."
