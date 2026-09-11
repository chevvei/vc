cmake_minimum_required(VERSION 3.18)
project(cuda_spatial_accel LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# CUDA 架构（75 = 20系, 86 = 30系, 89 = 40系）
# 本机 RTX 3090 Ti = 86
set(CMAKE_CUDA_ARCHITECTURES 75 86)

enable_testing()

add_executable(cuda_spatial_accel
    src/main.cpp
    src/pointcloud.cpp
    src/baseline_cpu.cpp
    src/benchmark.cpp
    src/gpu_baseline_aos.cu
    src/gpu_optimized_soa.cu
    src/uniform_grid.cu
    src/knn_search_kernel.cu
    src/esdf_jump_flood.cu
)

target_include_directories(cuda_spatial_accel PRIVATE
    src
    ${CMAKE_CUDA_TOOLKIT_INCLUDE_DIRECTORIES}
)
target_compile_options(cuda_spatial_accel PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-O2 -Wall>
    $<$<COMPILE_LANGUAGE:CUDA>:--use_fast_math>
)
