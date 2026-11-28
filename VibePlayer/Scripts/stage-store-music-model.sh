#!/bin/sh
set -eu

# A store archive needs a working music renderer from its first launch.
if [ "${VIBEPLAYER_STORE_ARCHIVE:-NO}" != YES ] || [ "${ACTION:-}" != install ]; then
    exit 0
fi

source=${VIBEPLAYER_MUSIC_MODEL_DIR:-}
if [ -z "$source" ] || [ ! -d "$source" ]; then
    echo "error: Set VIBEPLAYER_MUSIC_MODEL_DIR to the licensed YuE2MetalAssets for this platform."
    exit 1
fi
platform=$(/usr/bin/plutil -extract compilerPlatform raw -o - "$source/build-settings.json")
version=$(/usr/bin/plutil -extract version raw -o - "$source/manifest.json")
if [ "$platform" != "$PLATFORM_NAME" ] || [ "$version" != 3 ]; then
    echo "error: YuE2MetalAssets must be a version 3 bundle compiled for $PLATFORM_NAME."
    exit 1
fi
for file in Autoregressive.mlmodelc Waveform.mlmodelc metal-decoder.json embeddings.f16 tokenizer.tiktoken; do
    if [ ! -e "$source/$file" ]; then
        echo "error: YuE2MetalAssets is missing $file."
        exit 1
    fi
done

target="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/YuE2MetalAssets"
/bin/mkdir -p "$target"
for file in "$source"/*.mlmodelc "$source"/manifest.json "$source"/metal-decoder.json "$source"/embeddings.f16 "$source"/tokenizer.tiktoken; do
    /usr/bin/ditto "$file" "$target/$(/usr/bin/basename "$file")"
done
