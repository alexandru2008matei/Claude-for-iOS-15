#!/bin/bash
# Run on a Mac with Xcode 15+. Makes UNSIGNED ipa (for TrollStore/AltStore/Sideloadly/jailbreak).
set -e
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
xcodebuild -project ClaudeChat.xcodeproj -scheme ClaudeChat -configuration Release \
  -sdk iphoneos -archivePath build/ClaudeChat.xcarchive CODE_SIGNING_ALLOWED=NO archive
rm -rf Payload ClaudeChat.ipa && mkdir Payload
cp -R build/ClaudeChat.xcarchive/Products/Applications/ClaudeChat.app Payload/
zip -qr ClaudeChat.ipa Payload && rm -rf Payload
echo "Done: ClaudeChat.ipa"
