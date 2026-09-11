// src/pointcloud.cpp
#include "pointcloud.h"
#include <random>
#include <stdexcept>
#include <iostream>

std::vector<PointAoS> PointCloudGenerator::generateGaussianClusters(
    size_t n, int numClusters, float spread, unsigned seed
) {
    std::mt19937 rng(seed);
    std::normal_distribution<float> dist(0.0f, spread);

    // 先随机生成 numClusters 个团心（分布在 [-100, 100] 立方体内）
    std::vector<PointAoS> centers(numClusters);
    for (auto& c : centers) {
        c.x = (rng() % 2000) / 10.0f - 100.0f;
        c.y = (rng() % 2000) / 10.0f - 100.0f;
        c.z = (rng() % 2000) / 10.0f - 100.0f;
    }

    // 每个点随机归属一个团心，加高斯偏移
    std::vector<PointAoS> cloud(n);
    for (auto& p : cloud) {
        const auto& c = centers[rng() % numClusters];
        p.x = c.x + dist(rng);
        p.y = c.y + dist(rng);
        p.z = c.z + dist(rng);
    }
    return cloud;
}

void PointCloudGenerator::copyToDeviceAsync(
    const std::vector<PointAoS>& hostCloud,
    PointCloudSoA& deviceCloud,
    cudaStream_t stream
) {
    size_t n = hostCloud.size();
    deviceCloud.n = n;
    if (n == 0) return;

    // 分配 device 内存
    cudaMalloc(&deviceCloud.xs, n * sizeof(float));
    cudaMalloc(&deviceCloud.ys, n * sizeof(float));
    cudaMalloc(&deviceCloud.zs, n * sizeof(float));

    // 临时分配 pinned host 缓冲，把 AoS 拆成 SoA 再 async 拷贝
    // 教学点：pinned memory（cudaMallocHost）让操作系统不能换页
    //          cudaMemcpyAsync 配合 stream，让拷贝和 kernel 计算可重叠
    float *hx = nullptr, *hy = nullptr, *hz = nullptr;
    cudaMallocHost(&hx, n * sizeof(float));
    cudaMallocHost(&hy, n * sizeof(float));
    cudaMallocHost(&hz, n * sizeof(float));

    for (size_t i = 0; i < n; ++i) {
        hx[i] = hostCloud[i].x;
        hy[i] = hostCloud[i].y;
        hz[i] = hostCloud[i].z;
    }

    // 异步拷贝到指定 stream
    cudaMemcpyAsync(deviceCloud.xs, hx, n * sizeof(float), cudaMemcpyHostToDevice, stream);
    cudaMemcpyAsync(deviceCloud.ys, hy, n * sizeof(float), cudaMemcpyHostToDevice, stream);
    cudaMemcpyAsync(deviceCloud.zs, hz, n * sizeof(float), cudaMemcpyHostToDevice, stream);

    // 等待拷贝完成才能释放 pinned 缓冲
    // 教学点：实际工程中可以把 pinned 缓冲池化复用，避免反复分配
    cudaStreamSynchronize(stream);
    cudaFreeHost(hx);
    cudaFreeHost(hy);
    cudaFreeHost(hz);
}

void PointCloudGenerator::freeDevice(PointCloudSoA& cloud) {
    if (cloud.xs) cudaFree(cloud.xs);
    if (cloud.ys) cudaFree(cloud.ys);
    if (cloud.zs) cudaFree(cloud.zs);
    cloud = {nullptr, nullptr, nullptr, 0};
}
