#!/bin/bash
set -euo pipefail

package_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
source=${1:-https://github.com/0xShug0/audio.cpp.git}
revision=v0.9.6
work=$(mktemp -d "${TMPDIR:-/tmp}/vibe-yue2-ios.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

git clone --quiet --depth 1 --branch "$revision" -- "$source" "$work/audio.cpp"
git -C "$work/audio.cpp" apply \
    "$package_dir/Patches/audio-cpp-v0.9.6-waveform.patch" \
    "$package_dir/Patches/audio-cpp-v0.9.6-wide-attention.patch" \
    "$package_dir/Patches/audio-cpp-v0.9.6-oobleck-metal-snake.patch" \
    "$package_dir/Patches/audio-cpp-v0.9.6-metal-vector-concat.patch" \
    "$package_dir/Patches/audio-cpp-v0.9.6-acoustic-kernels.patch" \
    "$package_dir/Patches/audio-cpp-v0.9.6-metal-allocation-failure.patch"

# The vendored SentencePiece uses this ios-cmake helper for its CLI targets.
cat > "$work/ios.cmake" <<'EOF'
function(set_xcode_property target property value config)
    set_property(TARGET "${target}" PROPERTY "XCODE_ATTRIBUTE_${property}" "${value}")
endfunction()
EOF

cmake -G 'Unix Makefiles' -S "$work/audio.cpp" -B "$work/build" \
    -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES="$work/ios.cmake" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-headerpad_max_install_names \
    -DAUDIOCPP_VERSION="${revision#v}" -DAUDIOCPP_BUILD_C_API=ON \
    -DAUDIOCPP_MODEL_SET=custom -DAUDIOCPP_MODELS=yue2 -DBUILD_SHARED_LIBS=OFF \
    -DENGINE_ENABLE_METAL=ON -DENGINE_ENABLE_NATIVE_CPU=OFF -DENGINE_ENABLE_OPENMP=OFF \
    -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_BLAS=OFF \
    -DENGINE_BUILD_TESTS=OFF -DENGINE_BUILD_MODEL_TESTS=OFF -DENGINE_BUILD_EXAMPLES=OFF
cmake --build "$work/build" --parallel "${VIBE_BUILD_JOBS:-8}" --target audiocpp

framework="$work/YuE2Audio.framework"
mkdir -p "$framework"
cp -L "$work/build/bin/libaudiocpp.dylib" "$framework/YuE2Audio"
install_name_tool -id @rpath/YuE2Audio.framework/YuE2Audio "$framework/YuE2Audio"
cp "$work/audio.cpp/LICENSE" "$framework/LICENSE"
cat > "$framework/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>YuE2Audio</string>
    <key>CFBundleIdentifier</key><string>com.vibeplayer.runtime.yue2</string>
    <key>CFBundleName</key><string>YuE2Audio</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>0.9.6</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
    <key>MinimumOSVersion</key><string>18.0</string>
</dict>
</plist>
EOF

destination="$package_dir/.build/apple-mobile/YuE2Audio.framework"
mkdir -p "$(dirname "$destination")"
ditto "$framework" "$destination"
printf 'Built %s\n' "$destination"
