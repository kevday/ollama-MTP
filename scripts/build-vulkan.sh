#!/bin/sh
#
# Build Ollama with Vulkan GPU acceleration on Alpine Linux
#
# Builds:
#   1. The ollama Go binary (CGO_ENABLED)
#   2. The ggml-vulkan shared library with GPU shaders
#   3. Patches known issues in generated Vulkan shaders
#
# Usage:
#   ./scripts/build-vulkan.sh           # build everything
#   ./scripts/build-vulkan.sh go        # build Go binary only
#   ./scripts/build-vulkan.sh shaders   # build + fix Vulkan shaders only
#   ./scripts/build-vulkan.sh clean     # remove build artifacts

set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"

JOBS=$(nproc)
CMAKE_BACKEND_DIR="ml/backend/ggml/ggml"
CMAKE_BUILD_DIR="ml/backend/ggml/ggml/build"
INSTALL_LIBDIR="$HOME/.local/lib/ollama"
INSTALL_BINDIR="$HOME/.local/bin"

build_go() {
    echo "=== Building ollama Go binary ==="
    CGO_ENABLED=1 go build -o ollama .
    echo "Binary: $ROOT/ollama"
    ls -lh ollama
}

build_vulkan() {
    echo "=== Building ggml-vulkan backend ==="

    cd "$ROOT/$CMAKE_BACKEND_DIR"

    # Configure cmake with Vulkan
    cmake -B build -DGGML_VULKAN=ON \
        -DGGML_VULKAN_CHECK_RESULTS=OFF \
        -DGGML_CUDA=OFF \
        -DGGML_METAL=OFF \
        -DCMAKE_BUILD_TYPE=Release

    # First pass: generates SPIR-V shaders + .comp.cpp files
    echo "--- First pass: generate Vulkan shaders ---"
    cmake --build build -j"$JOBS" --target ggml-vulkan 2>&1 | tee build-vulkan-pass1.log

    # Patch get_rows_q2_k shader if needed
    # Known bug: vulkan-shaders-gen generates incorrect array size (5012 vs 5000)
    echo "--- Checking shader patches ---"
    SPV_FILE=$(find build -path "*/vulkan-shaders.spv/get_rows_q2_k.spv" -type f 2>/dev/null | head -1)
    COMP_CPP=$(find build -name "get_rows_q2_k.comp.cpp" -type f 2>/dev/null | head -1)

    if [ -n "$SPV_FILE" ] && [ -n "$COMP_CPP" ] && [ "$(wc -c < "$SPV_FILE")" -eq 5000 ]; then
        echo "Patching $COMP_CPP with correct SPIR-V ($(wc -c < "$SPV_FILE") bytes)..."
        # Generate correct C array from the real SPIR-V and replace in the .comp.cpp
        xxd -i < "$SPV_FILE" > /tmp/get_rows_q2_k.xxd
        perl -i -0pe 's/unsigned char get_rows_q2_k.*?\n\};\n/'$(cat /tmp/get_rows_q2_k.xxd | tr '\n' ' ' | sed 's/unsigned int/unsigned char/' )'/' "$COMP_CPP" 2>/dev/null || \
        sed -ni '/unsigned char get_rows_q2_k/{
            r /tmp/get_rows_q2_k.xxd
            a\;
            d
        }; p' "$COMP_CPP"
        echo "Patched OK"
    else
        echo "No shader patch needed for this version"
    fi

    # Second pass: rebuild with fixed shader
    echo "--- Second pass: rebuild ggml-vulkan ---"
    cmake --build build -j"$JOBS" --target ggml-vulkan 2>&1 | tee build-vulkan-pass2.log

    # Collect shared libraries
    echo "--- Collecting shared libraries ---"
    mkdir -p "$INSTALL_LIBDIR"
    find build -name "libggml-vulkan.so*" -type f -exec cp -v {} "$INSTALL_LIBDIR/" \;
    find build -name "libggml-base.so*" -type f -exec cp -v {} "$INSTALL_LIBDIR/" \;
    find build -name "libggml-cpu*.so*" -type f -exec cp -v {} "$INSTALL_LIBDIR/" \;

    ls -lh "$INSTALL_LIBDIR/"
    echo "Vulkan shared libraries installed to $INSTALL_LIBDIR"
    cd "$ROOT"
}

case "$1" in
    clean)
        echo "=== Cleaning ==="
        rm -rf "$CMAKE_BUILD_DIR"
        echo "Done"
        ;;
    go)
        build_go
        ;;
    shaders)
        build_vulkan
        ;;
    "")
        build_go
        build_vulkan
        echo ""
        echo "=== Build complete ==="
        echo "Binary:        $ROOT/ollama"
        echo "Vulkan libs:   $INSTALL_LIBDIR/"
        echo ""
        echo "Run:"
        echo "  OLLAMA_LIBRARY_PATH=\"$INSTALL_LIBDIR\" ./ollama serve"
        ;;
    *)
        echo "Usage: $0 [go|shaders|clean]"
        exit 1
        ;;
esac