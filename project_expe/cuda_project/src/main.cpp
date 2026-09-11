// src/main.cpp
// 主入口：生成点云 -> CPU baseline -> GPU AoS -> GPU SoA -> GPU smem+shuffle -> ESDF -> 对比
#include "pointcloud.h"
#include "baseline_cpu.h"
#include "benchmark.h"
#include <cuda_runtime.h>
#include <chrono>
#include <iostream>
#include <vector>
#include <cmath>

// 来自 gpu_baseline_aos.cu
void runKnnAosBaseline(
    const PointAoS* dCloud, size_t cloudN,
    const PointAoS* dQueries, size_t queryN,
    int* dOutIndices, float* dOutDists,
    cudaStream_t stream
);

// 来自 gpu_optimized_soa.cu
void runKnnSoa(
    const PointCloudSoA& cloud,
    const PointCloudSoA& queries,
    int* dOutIndices, float* dOutDists,
    cudaStream_t stream
);

// 来自 knn_search_kernel.cu
void runKnnSmemTiling(
    const PointCloudSoA& cloud,
    const PointCloudSoA& queries,
    int* dOutIndices, float* dOutDists,
    cudaStream_t stream
);

// 来自 esdf_jump_flood.cu
void runJumpFloodEsdf(
    const float* dxs, const float* dys, const float* dzs, size_t cloudN,
    long long* dSeeds, float* dDists,
    float originX, float originY, float originZ,
    float voxelSize, int gridSize,
    cudaStream_t stream
);

int main() {
    // 1. 检查 GPU
    int devCount;
    cudaGetDeviceCount(&devCount);
    if (devCount == 0) {
        std::cerr << "No CUDA device found\n";
        return 1;
    }
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    std::cout << "GPU: " << prop.name
              << " | SM " << prop.major << "." << prop.minor
              << " | " << prop.totalGlobalMem / (1024*1024) << " MB\n";

    // 2. 生成 1M 点云 + 1K 查询点
    const size_t CLOUD_N = 1'000'000;
    const size_t QUERY_N = 1'000;
    std::cout << "Generating " << CLOUD_N << " cloud points + "
              << QUERY_N << " queries...\n";

    auto hostCloud = PointCloudGenerator::generateGaussianClusters(CLOUD_N, 50, 2.0f);
    auto hostQueries = PointCloudGenerator::generateGaussianClusters(QUERY_N, 10, 2.0f, 123);

    // 3. CPU baseline
    auto t0 = std::chrono::high_resolution_clock::now();
    auto cpuResult = cpuBruteKnn(hostCloud, hostQueries);
    auto t1 = std::chrono::high_resolution_clock::now();
    float cpuMs = std::chrono::duration<float, std::milli>(t1 - t0).count();
    std::cout << "CPU baseline: " << cpuMs << " ms\n";

    // 4. 拷贝到 GPU
    cudaStream_t stream;
    cudaStreamCreate(&stream);

    PointAoS* dCloudAos = nullptr;
    PointAoS* dQueriesAos = nullptr;
    cudaMalloc(&dCloudAos, CLOUD_N * sizeof(PointAoS));
    cudaMalloc(&dQueriesAos, QUERY_N * sizeof(PointAoS));
    cudaMemcpyAsync(dCloudAos, hostCloud.data(), CLOUD_N * sizeof(PointAoS),
                    cudaMemcpyHostToDevice, stream);
    cudaMemcpyAsync(dQueriesAos, hostQueries.data(), QUERY_N * sizeof(PointAoS),
                    cudaMemcpyHostToDevice, stream);

    PointCloudSoA devCloud, devQueries;
    PointCloudGenerator::copyToDeviceAsync(hostCloud, devCloud, stream);
    PointCloudGenerator::copyToDeviceAsync(hostQueries, devQueries, stream);

    int* dOutIdxAos; float* dOutDistAos;
    int* dOutIdxSoa; float* dOutDistSoa;
    int* dOutIdxSmem; float* dOutDistSmem;
    cudaMalloc(&dOutIdxAos, QUERY_N * sizeof(int));
    cudaMalloc(&dOutDistAos, QUERY_N * sizeof(float));
    cudaMalloc(&dOutIdxSoa, QUERY_N * sizeof(int));
    cudaMalloc(&dOutDistSoa, QUERY_N * sizeof(float));
    cudaMalloc(&dOutIdxSmem, QUERY_N * sizeof(int));
    cudaMalloc(&dOutDistSmem, QUERY_N * sizeof(float));

    cudaStreamSynchronize(stream);

    // 5. GPU AoS baseline
    float aosMs = Benchmark::timeKernel(stream, [&]() {
        runKnnAosBaseline(dCloudAos, CLOUD_N, dQueriesAos, QUERY_N,
                          dOutIdxAos, dOutDistAos, stream);
    });

    // 6. GPU SoA 优化
    float soaMs = Benchmark::timeKernel(stream, [&]() {
        runKnnSoa(devCloud, devQueries, dOutIdxSoa, dOutDistSoa, stream);
    });

    // 7. GPU SoA + smem tiling + warp shuffle
    float smemMs = Benchmark::timeKernel(stream, [&]() {
        runKnnSmemTiling(devCloud, devQueries, dOutIdxSmem, dOutDistSmem, stream);
    });
    cudaStreamSynchronize(stream);

    // 8. 正确性验证
    std::vector<int> gpuAosIdx(QUERY_N), gpuSoaIdx(QUERY_N), gpuSmemIdx(QUERY_N);
    cudaMemcpy(gpuAosIdx.data(), dOutIdxAos, QUERY_N * sizeof(int),
               cudaMemcpyDeviceToHost);
    cudaMemcpy(gpuSoaIdx.data(), dOutIdxSoa, QUERY_N * sizeof(int),
               cudaMemcpyDeviceToHost);
    cudaMemcpy(gpuSmemIdx.data(), dOutIdxSmem, QUERY_N * sizeof(int),
               cudaMemcpyDeviceToHost);
    int mismatches = 0;
    for (size_t i = 0; i < QUERY_N; ++i) {
        if (gpuAosIdx[i] != cpuResult[i]) ++mismatches;
        if (gpuSoaIdx[i] != cpuResult[i]) ++mismatches;
        if (gpuSmemIdx[i] != cpuResult[i]) ++mismatches;
    }
    std::cout << "Validation mismatches: " << mismatches << " (expect 0)\n";

    // 9. KNN benchmark 对比表
    std::cout << "\n=== KNN Benchmark (K=1, queryN=" << QUERY_N
              << ", cloudN=" << CLOUD_N << ") ===\n";
    Benchmark::printComparison({
        {"CPU brute O(N*M)",       cpuMs,   "单线程基线"},
        {"GPU AoS baseline",       aosMs,   "warp 非合并访存，带宽 30%"},
        {"GPU SoA + coalesced",    soaMs,   "合并访存，带宽 60%+"},
        {"GPU SoA + smem+shuffle", smemMs,  "smem tiling + warp shuffle"}
    });

    // 10. ESDF 构建（64³ 体素）
    const int GRID_SIZE = 64;
    const float VOXEL_SIZE = 200.0f / GRID_SIZE;   // 包围 200m，64 格
    const float ORIGIN = -100.0f;
    size_t totalCells = (size_t)GRID_SIZE * GRID_SIZE * GRID_SIZE;
    long long* dSeeds; float* dDists;
    cudaMalloc(&dSeeds, totalCells * sizeof(long long));
    cudaMalloc(&dDists, totalCells * sizeof(float));

    float esdfMs = Benchmark::timeKernel(stream, [&]() {
        runJumpFloodEsdf(
            devCloud.xs, devCloud.ys, devCloud.zs, CLOUD_N,
            dSeeds, dDists,
            ORIGIN, ORIGIN, ORIGIN,
            VOXEL_SIZE, GRID_SIZE,
            stream
        );
    });

    std::cout << "\n=== ESDF Benchmark (gridSize=" << GRID_SIZE
              << ", cloudN=" << CLOUD_N << ") ===\n";
    Benchmark::printComparison({
        {"GPU jump flooding + graph", esdfMs, "log(N) pass + kernel fusion + CUDA graph"}
    });

    // 11. 清理
    cudaFree(dCloudAos); cudaFree(dQueriesAos);
    cudaFree(dOutIdxAos); cudaFree(dOutDistAos);
    cudaFree(dOutIdxSoa); cudaFree(dOutDistSoa);
    cudaFree(dOutIdxSmem); cudaFree(dOutDistSmem);
    cudaFree(dSeeds); cudaFree(dDists);
    PointCloudGenerator::freeDevice(devCloud);
    PointCloudGenerator::freeDevice(devQueries);
    cudaStreamDestroy(stream);
    return 0;
}
