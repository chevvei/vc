// src/uniform_grid.cu
// Uniform Grid 构建：原子计数 + cub sort/scan
#include "uniform_grid.h"
#include <cub/cub.cuh>
#include <thrust/sequence.h>
#include <thrust/device_ptr.h>
#include <thrust/execution_policy.h>
#include <cuda_runtime.h>
#include <algorithm>
#include <iostream>

// 计算 cell 三维坐标 + 线性 id
__device__ inline int computeCellIdDevice(
    float x, float y, float z,
    float ox, float oy, float oz,
    float cs, int gx, int gy, int gz
) {
    int cx = (int)floorf((x - ox) / cs);
    int cy = (int)floorf((y - oy) / cs);
    int cz = (int)floorf((z - oz) / cs);
    if (cx < 0 || cx >= gx || cy < 0 || cy >= gy || cz < 0 || cz >= gz) return -1;
    return (cz * gy + cy) * gx + cx;
}

// 第 1 步：每个点原子计数所属 cell
// 教学点：atomicAdd 是 GPU 上唯一安全的并发写方式
__global__ void countCellsKernel(
    const float* xs, const float* ys, const float* zs, size_t n,
    float ox, float oy, float oz, float cs,
    int gx, int gy, int gz,
    int* cellCounts
) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= (int)n) return;
    int cellId = computeCellIdDevice(xs[i], ys[i], zs[i], ox, oy, oz, cs, gx, gy, gz);
    if (cellId >= 0) atomicAdd(&cellCounts[cellId], 1);
}

// 第 2 步：每个点记录所属 cellId（供后续排序）
__global__ void fillCellIdsKernel(
    const float* xs, const float* ys, const float* zs, size_t n,
    float ox, float oy, float oz, float cs,
    int gx, int gy, int gz,
    int* cellIds
) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= (int)n) return;
    int cellId = computeCellIdDevice(xs[i], ys[i], zs[i], ox, oy, oz, cs, gx, gy, gz);
    cellIds[i] = (cellId >= 0) ? cellId : 0;
}

void UniformGrid::free() {
    if (cellCounts) cudaFree(cellCounts);
    if (cellStarts) cudaFree(cellStarts);
    if (sortedIndices) cudaFree(sortedIndices);
    *this = {};
}

void buildUniformGrid(
    const PointCloudSoA& cloud,
    float cellSize,
    UniformGrid& grid,
    cudaStream_t stream
) {
    grid.cellSize = cellSize;
    grid.n = cloud.n;

    // 1. host 算包围盒 + gridSize
    // 简化：从原点开始，包围 [-100,100]^3
    grid.originX = -100.0f;
    grid.originY = -100.0f;
    grid.originZ = -100.0f;
    grid.gridSizeX = (int)(200.0f / cellSize);
    grid.gridSizeY = grid.gridSizeX;
    grid.gridSizeZ = grid.gridSizeX;
    size_t totalCells = (size_t)grid.gridSizeX * grid.gridSizeY * grid.gridSizeZ;

    // 2. 分配 + 清零 cellCounts
    cudaMalloc(&grid.cellCounts, totalCells * sizeof(int));
    cudaMemsetAsync(grid.cellCounts, 0, totalCells * sizeof(int), stream);

    // 3. 原子计数每个 cell
    int threads = 256;
    int blocks = ((int)cloud.n + threads - 1) / threads;
    countCellsKernel<<<blocks, threads, 0, stream>>>(
        cloud.xs, cloud.ys, cloud.zs, cloud.n,
        grid.originX, grid.originY, grid.originZ, grid.cellSize,
        grid.gridSizeX, grid.gridSizeY, grid.gridSizeZ,
        grid.cellCounts
    );

    // 4. cub exclusive sum 算 cellStarts
    // 教学点：cub 是 NVIDIA 官方优化原语，比手写快且正确
    cudaMalloc(&grid.cellStarts, totalCells * sizeof(int));
    size_t tempBytes = 0;
    cub::DeviceScan::ExclusiveSum(nullptr, tempBytes, grid.cellCounts, grid.cellStarts,
                                  (int)totalCells, stream);
    void* tempBuf = nullptr;
    cudaMalloc(&tempBuf, tempBytes);
    cub::DeviceScan::ExclusiveSum(tempBuf, tempBytes, grid.cellCounts, grid.cellStarts,
                                  (int)totalCells, stream);
    cudaFree(tempBuf);

    // 5. 填每个点的 cellId
    int* cellIds = nullptr;
    cudaMalloc(&cellIds, cloud.n * sizeof(int));
    fillCellIdsKernel<<<blocks, threads, 0, stream>>>(
        cloud.xs, cloud.ys, cloud.zs, cloud.n,
        grid.originX, grid.originY, grid.originZ, grid.cellSize,
        grid.gridSizeX, grid.gridSizeY, grid.gridSizeZ,
        cellIds
    );

    // 6. cub radix sort 把点按 cellId 排序
    cudaMalloc(&grid.sortedIndices, cloud.n * sizeof(int));
    int* sortedCellIds = nullptr;
    cudaMalloc(&sortedCellIds, cloud.n * sizeof(int));
    // 初始化索引为 0..n-1（注意：SortPairs 不支持 input==output 别名）
    int* idxIn = nullptr;
    cudaMalloc(&idxIn, cloud.n * sizeof(int));
    thrust::sequence(thrust::cuda::par.on(stream),
                     idxIn, idxIn + cloud.n);

    size_t sortTempBytes = 0;
    cub::DeviceRadixSort::SortPairs(nullptr, sortTempBytes,
        cellIds, sortedCellIds,
        idxIn, grid.sortedIndices,
        (int)cloud.n, 0, sizeof(int)*8, stream);
    void* sortTempBuf = nullptr;
    cudaMalloc(&sortTempBuf, sortTempBytes);
    cub::DeviceRadixSort::SortPairs(sortTempBuf, sortTempBytes,
        cellIds, sortedCellIds,
        idxIn, grid.sortedIndices,
        (int)cloud.n, 0, sizeof(int)*8, stream);
    cudaFree(sortTempBuf);
    cudaFree(idxIn);
    cudaFree(cellIds);
    cudaFree(sortedCellIds);

    cudaStreamSynchronize(stream);
}
