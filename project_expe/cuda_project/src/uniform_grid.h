// src/uniform_grid.h
// Uniform Grid 空间索引（atomic + cub sort/scan 构建）
#pragma once
#include "pointcloud.h"
#include <cstddef>

struct UniformGrid {
    // grid 元信息
    float originX = 0, originY = 0, originZ = 0;
    float cellSize = 1.0f;
    int gridSizeX = 0, gridSizeY = 0, gridSizeZ = 0;

    // device 指针
    int* cellCounts = nullptr;     // 每个 cell 点数
    int* cellStarts = nullptr;     // 每个 cell 在 sortedIndices 里的起始位置
    int* sortedIndices = nullptr;  // 排序后的点索引（按 cellId）
    size_t n = 0;

    void free();
};

// GPU 构建 uniform grid
// 教学点：atomic + cub sort + cub scan
void buildUniformGrid(
    const PointCloudSoA& cloud,
    float cellSize,
    UniformGrid& grid,
    cudaStream_t stream
);
