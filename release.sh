#!/bin/sh
# Builds the universal app and zips it as Today-HUD.zip, the file get.sh downloads.
#   VERSION=1.0 ./release.sh
set -eu
cd "$(dirname "$0")"
UNIVERSAL=1 ./build.sh
"Today HUD.app/Contents/MacOS/TodayHUD" --test
rm -f Today-HUD.zip
ditto -c -k --keepParent "Today HUD.app" Today-HUD.zip
echo "Made Today-HUD.zip"
