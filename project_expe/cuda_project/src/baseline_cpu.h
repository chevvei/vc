// src/baseline_cpu.h
// CPU 暴力基线：作为正确性参考 + 性能对照
#pragma once
#include "pointcloud.h"
#include <vector>
#include <cstdint>

// CPU 暴力 KNN：对每个查询点，扫描全部点云找最近邻（K=1 简化版）
// 输出：result[i] = 第 i 个查询点的最近邻点索引
std::vector<int> cpuBruteKnn(
    const std::vector<PointAoS>& cloud,
    const std::vector<PointAoS>& queries
);
