#!/bin/bash
# Builds stretched-projector.plugin (universal arm64 + x86_64).
#
#   ./build.sh            build into ./build
#   ./build.sh install    build and copy into ~/Library/Application Support/obs-studio/plugins
#
# Headers come from OBS 28.0.0 (first Qt6 / Apple Silicon release). Symbols are
# resolved at load time from the running OBS, so one binary works on OBS 28+.
set -euo pipefail

cd "$(dirname "$0")"

OBS_TAG="${OBS_TAG:-28.0.0}"
DEPS="$PWD/.deps/obs-studio-$OBS_TAG"
OUT="$PWD/build/stretched-projector.plugin"
PLUGIN_DIR="$HOME/Library/Application Support/obs-studio/plugins"

if [ ! -f "$DEPS/libobs/obs-module.h" ]; then
	echo "Fetching OBS $OBS_TAG headers..."
	rm -rf "$DEPS"
	git clone -q --depth 1 --filter=blob:none --sparse -b "$OBS_TAG" \
		https://github.com/obsproject/obs-studio "$DEPS" 2>/dev/null
	git -C "$DEPS" sparse-checkout set libobs UI/obs-frontend-api
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"

clang -bundle -fobjc-arc -O2 -Wall \
	-arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
	-I "$DEPS/libobs" -I "$DEPS/UI/obs-frontend-api" \
	-framework Cocoa \
	-undefined dynamic_lookup \
	-o "$OUT/Contents/MacOS/stretched-projector" \
	stretched-projector.m

cat > "$OUT/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>stretched-projector</string>
	<key>CFBundleIdentifier</key>
	<string>us.hyunjae.obs-stretched-projector</string>
	<key>CFBundleName</key>
	<string>stretched-projector</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
</dict>
</plist>
EOF

codesign --force --sign - "$OUT" >/dev/null
echo "Built $OUT"

if [ "${1:-}" = "install" ]; then
	mkdir -p "$PLUGIN_DIR"
	rm -rf "$PLUGIN_DIR/stretched-projector.plugin"
	cp -R "$OUT" "$PLUGIN_DIR/"
	xattr -dr com.apple.quarantine "$PLUGIN_DIR/stretched-projector.plugin" 2>/dev/null || true
	echo "Installed to $PLUGIN_DIR/stretched-projector.plugin (restart OBS)"
fi
