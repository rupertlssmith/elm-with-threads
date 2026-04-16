#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

mkdir -p build

echo "Building Elm..."
elm make src/Main.elm --output=build/elm.js

echo "Bundling JS..."
node esbuild.config.mjs

echo "Running..."
node build/index.js
