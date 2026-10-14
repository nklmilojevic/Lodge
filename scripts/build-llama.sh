#!/usr/bin/env bash
# Builds llama.cpp (MIT) for the semantic search model: the pinned tag plus scripts/llama.cpp-no-logits.patch, as one
# universal static library in Packages/LlamaEmbedding/Vendor/CLlama.xcframework (not in git). Metal shaders are embedded.
# CMake comes from PATH, or from a uv virtual environment in the build folder. Does nothing when the pinned build exists.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=b11461   # EmbeddingGemma 2 (text, vision, audio) needs b11452 or later
COMMIT=4d756bc72bf00a4aacf410ae15a2d315f3db400d
PATCH=scripts/llama.cpp-no-logits.patch
WORK="${LLAMA_WORK:-build/llama}"
SOURCE="$WORK/llama.cpp"
BUILD="$WORK/build"
OUT=Packages/LlamaEmbedding/Vendor/CLlama.xcframework
STAMP="$TAG $(shasum -a 256 "$PATCH" | cut -c1-12) $(shasum -a 256 "$0" | cut -c1-12)"

if [[ -f "$OUT/Info.plist" && "$(cat "$OUT/../BUILD" 2>/dev/null)" == "$STAMP" ]]; then
  exit 0
fi

mkdir -p "$WORK"
if [[ ! -d "$SOURCE" ]]; then
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SOURCE"
fi
if [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$COMMIT" ]]; then
  echo "llama.cpp $TAG is not commit $COMMIT" >&2
  exit 1
fi
# Without the patch, every input token reserves 1 MiB of logits that an embedding model never produces.
if git -C "$SOURCE" apply --check "$PWD/$PATCH" 2>/dev/null; then
  git -C "$SOURCE" apply "$PWD/$PATCH"
fi

if ! command -v cmake > /dev/null; then
  if [[ ! -x "$WORK/cmake-venv/bin/cmake" ]]; then
    uv venv --quiet "$WORK/cmake-venv" --python 3.12
    uv pip install --quiet --python "$WORK/cmake-venv/bin/python" cmake==4.4.4 ninja==1.13.2
  fi
  export PATH="$PWD/$WORK/cmake-venv/bin:$PATH"
fi
GENERATOR=$(command -v ninja > /dev/null && echo Ninja || echo "Unix Makefiles")

STAGE="$WORK/stage"
rm -rf "$STAGE" && mkdir -p "$STAGE/include"
# One build per architecture: a combined build falls back to ggml's generic CPU code.
for ARCH in arm64 x86_64; do
  B="$BUILD-$ARCH"
  cmake -S "$SOURCE" -B "$B" -G "$GENERATOR" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DLLAMA_BUILD_MTMD=ON \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF > /dev/null
  cmake --build "$B" --config Release -j "$(sysctl -n hw.ncpu)" --target llama mtmd > /dev/null
  xcrun libtool -static -no_warning_for_no_symbols -o "$STAGE/libllamacpp-$ARCH.a" \
    $B/src/libllama.a $B/tools/mtmd/libmtmd.a $B/ggml/src/libggml.a $B/ggml/src/libggml-base.a \
    $B/ggml/src/libggml-cpu.a $B/ggml/src/ggml-metal/libggml-metal.a $B/ggml/src/ggml-blas/libggml-blas.a \
    $B/vendor/hash/libvendor-hash.a
done
lipo -create "$STAGE/libllamacpp-arm64.a" "$STAGE/libllamacpp-x86_64.a" -output "$STAGE/libllamacpp.a"
cp "$SOURCE/include/llama.h" "$SOURCE"/ggml/include/*.h "$SOURCE/tools/mtmd/mtmd.h" \
  "$SOURCE/tools/mtmd/mtmd-helper.h" "$STAGE/include/"
cat > "$STAGE/include/module.modulemap" <<'MAP'
module CLlama {
  header "llama.h"
  header "mtmd.h"
  header "mtmd-helper.h"
  link "c++"
  link framework "Accelerate"
  link framework "Foundation"
  link framework "Metal"
  link framework "MetalKit"
  export *
}
MAP

rm -rf "$OUT"
xcodebuild -create-xcframework -library "$STAGE/libllamacpp.a" -headers "$STAGE/include" -output "$OUT" > /dev/null
echo "$STAMP" > "$OUT/../BUILD"
echo "Built llama.cpp $TAG into $OUT"
