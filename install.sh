#!/bin/bash
set -e

cd "$(dirname "$0")/RecycleRobotCommandCenter"

echo "Building recyclerobot command center (Release)..."
xcodebuild -project RecycleRobotCommandCenter.xcodeproj \
  -scheme RecycleRobotCommandCenter \
  -configuration Release \
  build 2>&1 | grep -E '(error:|warning:|BUILD|FAILED|SUCCEEDED)'

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Release/RecycleRobotCommandCenter.app" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
  echo "ERROR: Could not find built app"
  exit 1
fi

# Quit the app if it's running
osascript -e 'quit app "RecycleRobotCommandCenter"' 2>/dev/null || true
sleep 1

rm -rf /Applications/RecycleRobotCommandCenter.app
cp -R "$APP_PATH" /Applications/

echo "Installed to /Applications/RecycleRobotCommandCenter.app"

open /Applications/RecycleRobotCommandCenter.app
echo "Launched!"
