#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
obs_args=(-DKIRA_BUILD_OBS=OFF)
if [[ "${1:-}" == "--obs" ]]; then
  obs_source="${KIRA_OBS_SOURCE:-$PWD/.deps/obs-studio}"
  if [[ ! -f "$obs_source/libobs/obs.h" ]]; then
    mkdir -p .deps
    git clone --depth 1 --branch 32.2.2 https://github.com/obsproject/obs-studio.git "$obs_source"
  fi
  if [[ ! -f .deps/simde/simde/x86/sse2.h ]]; then
    mkdir -p .deps
    git clone --depth 1 --branch v0.8.2 https://github.com/simd-everywhere/simde.git .deps/simde
  fi
  [[ "$(git -C "$obs_source" rev-parse HEAD)" == "ba2f32bdf791005443988a4955e963663e16b1ed" ]] || { printf 'OBS headers must match 32.2.2 (ba2f32b).\n'; exit 1; }
  [[ "$(git -C .deps/simde rev-parse HEAD)" == "71fd833d9666141edcd1d3c109a80e228303d8d7" ]] || { printf 'SIMDe headers must match the pinned v0.8.2 commit.\n'; exit 1; }
  obs_args=(-DKIRA_BUILD_OBS=ON "-DKIRA_OBS_SOURCE=$obs_source")
fi
cmake -S . -B build/native -DCMAKE_BUILD_TYPE=Release "${obs_args[@]}"
cmake --build build/native -j 4
bundle="$PWD/build/KiraRaki.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Library/LaunchAgents"
cp app/Info.plist "$bundle/Contents/Info.plist"
cp engine/Effects.metal "$bundle/Contents/Resources/Effects.metal"
cp service/jp.meowkawaii.KiraRaki.render.plist "$bundle/Contents/Library/LaunchAgents/"
cp build/native/KiraRakiService build/native/KiraRakiCLI "$bundle/Contents/MacOS/"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -import-objc-header app/Bridge.h -I shared app/StudioModel.swift app/MIDIController.swift app/KiraRakiApp.swift \
  -L build/native -lKiraEngine -lKiraCore -lc++ \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework Metal -framework MetalKit -framework CoreImage -framework CoreMIDI -framework ServiceManagement \
  -framework IOSurface -framework Vision -framework CoreML -framework Accelerate -framework Security \
  -o "$bundle/Contents/MacOS/KiraRaki"
codesign --force --sign - "$bundle/Contents/MacOS/KiraRakiService"
codesign --force --sign - "$bundle/Contents/MacOS/KiraRakiCLI"
codesign --force --sign - "$bundle"
if [[ -d build/native/obs/kiraraki.plugin ]]; then codesign --force --sign - build/native/obs/kiraraki.plugin; fi
printf 'Built: %s\n' "$bundle"
