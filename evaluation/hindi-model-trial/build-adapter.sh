#!/bin/sh
set -eu
# Arguments are the whisper.cpp checkout, a scratch build directory, and the output file.
src=${1:?whisper.cpp source tree}
build=${2:?scratch build directory}
out=${3:?output dylib}
cmake -S "$src" -B "$build" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_METAL_TARGET_OS=ios -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF
cmake --build "$build" --target whisper --parallel
xcrun --sdk iphoneos clang++ -std=c++17 -arch arm64 -miphoneos-version-min=26.0 -dynamiclib -O3 \
  -I"$src/include" -I"$src/ggml/include" "$(dirname "$0")/HindiModelTrial.cpp" \
  "$build/src/libwhisper.a" "$build/ggml/src/libggml.a" "$build/ggml/src/libggml-cpu.a" \
  "$build/ggml/src/libggml-base.a" "$build/ggml/src/ggml-metal/libggml-metal.a" \
  "$build/ggml/src/ggml-blas/libggml-blas.a" -framework Accelerate -framework Metal -framework Foundation \
  -framework MetalKit -Wl,-install_name,@rpath/libHindiModelTrial.dylib -o "$out"
