#!/bin/sh
# Builds the universal app and zips it as Work-from-a-List.zip, the file get.sh downloads.
#   VERSION=1.0 ./release.sh
set -eu
cd "$(dirname "$0")"
UNIVERSAL=1 ./build.sh
"Work from a List.app/Contents/MacOS/WorkFromAList" --test
rm -f Work-from-a-List.zip
ditto -c -k --keepParent "Work from a List.app" Work-from-a-List.zip
echo "Made Work-from-a-List.zip"
