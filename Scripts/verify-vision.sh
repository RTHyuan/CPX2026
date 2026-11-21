#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build-local/vision
xcrun swiftc -module-cache-path .build-local/vision/ModuleCache Core/Signs.swift Core/ScanGate.swift App/SignVision.swift Scripts/verify-camera-frames.swift Scripts/verify-vision.swift -o .build-local/vision/check
exec .build-local/vision/check "$@"
