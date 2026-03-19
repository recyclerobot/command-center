#!/bin/bash
set -e

cd "$(dirname "$0")/RecycleRobotCommandCenter"

echo "Building recyclerobot command center..."
xcodebuild -project RecycleRobotCommandCenter.xcodeproj \
  -scheme RecycleRobotCommandCenter \
  -configuration Debug \
  build 2>&1 | grep -E '(error:|warning:|BUILD|FAILED|SUCCEEDED)'

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "RecycleRobotCommandCenter.app" -type d 2>/dev/null | head -1)

if [ -n "$APP_PATH" ]; then
  echo ""
  echo "App built at: $APP_PATH"
  echo ""
  read -p "Launch now? (y/n) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    open "$APP_PATH"
    echo "Launched!"
  fi
else
  echo "ERROR: Could not find built app"
  exit 1
fi
