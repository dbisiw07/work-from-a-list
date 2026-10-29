#!/bin/sh
# Builds the app from this folder and installs it (see get.sh).
set -eu
cd "$(dirname "$0")"
./build.sh
./get.sh "Work from a List.app"
