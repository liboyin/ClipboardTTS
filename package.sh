#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

xcodebuild \
  -project ClipboardTTSApp.xcodeproj \
  -scheme ClipboardTTSApp \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  build

APP="$(pwd)/build/Build/Products/Release/ClipboardTTSApp.app"

cat <<EOF

Built: $APP

--- Share the following with users ---

ClipboardTTSApp first-run instructions:

1. Move ClipboardTTSApp.app to /Applications.
2. In Terminal, run:
     xattr -dr com.apple.quarantine /Applications/ClipboardTTSApp.app
3. Launch ClipboardTTSApp from /Applications. Look for its icon in the menu bar
   (the app has no Dock icon).

Step 2 is required because the app is ad-hoc signed, not notarized by Apple;
without it, Gatekeeper will refuse to open it.
EOF
