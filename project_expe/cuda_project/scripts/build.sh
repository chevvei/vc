#!/bin/bash
# scripts/build.sh
set -e
# 设置 CUDA toolkit 路径
export PATH=/usr/local/cuda-12.4/bin:$PATH
export CUDAToolkit_ROOT=/usr/local/cuda-12.4

cd "$(dirname "$0")/.."
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j
echo "=== Build complete ==="
echo
./cuda_spatial_accel
