// src/pointcloud.h
// 点云生成 + AoS/SoA 双布局 + pinned memory 异步拷贝
#pragma once
#include <vector>
#include <cstddef>
#include <cuda_runtime.h>

// AoS 布局：每个点一个结构体（cache 不友好，作为对照基线）
struct PointAoS {
    float x, y, z;
};

// SoA 布局：x/y/z 分别连续存储（cache 友好，生产用）
struct PointCloudSoA {
    float *xs = nullptr;   // device 指针
    float *ys = nullptr;
    float *zs = nullptr;
    size_t n = 0;
};

// 生成合成点云（高斯团：模拟激光雷达多个物体回波）
struct PointCloudGenerator {
    // 生成 n 个点，分布在若干高斯团内（模拟障碍物）
    static std::vector<PointAoS> generateGaussianClusters(
        size_t n,            // 总点数
        int numClusters,     // 高斯团数
        float spread,        // 团半径
        unsigned seed = 42
    );

    // host pinned -> device SoA（异步拷贝到指定 stream）
    // 教学点：pinned memory 让 CUDA DMA 直接搬运，async copy 让搬运和计算并行
    static void copyToDeviceAsync(
        const std::vector<PointAoS>& hostCloud,
        PointCloudSoA& deviceCloud,
        cudaStream_t stream
    );

    // 释放 device 内存
    static void freeDevice(PointCloudSoA& cloud);
};
