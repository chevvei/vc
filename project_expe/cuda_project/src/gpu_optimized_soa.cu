// src/gpu_optimized_soa.cu
// GPU SoA 优化版：合并访存 + __restrict__
// 教学点：SoA 让 warp 内线程访问连续地址，合并访存带宽利用率翻倍
#include "pointcloud.h"
#include <cuda_runtime.h>

__global__ void knnSoaKernel(
    const float* __restrict__ cxs,
    const float* __restrict__ cys,
    const float* __restrict__ czs,
    size_t cloudN,
    const float* __restrict__ qxs,
    const float* __restrict__ qys,
    const float* __restrict__ qzs,
    size_t queryN,
    int* outIndices,
    float* outDists
) {
    int q = blockIdx.x * blockDim.x + threadIdx.x;
    if (q >= (int)queryN) return;

    float qx = qxs[q], qy = qys[q], qz = qzs[q];
    float bestDist = 1e30f;
    int bestIdx = -1;
    // warp 内线程 i 访问 cxs[i]，地址连续 128B -> 合并访存
    for (size_t i = 0; i < cloudN; ++i) {
        float dx = cxs[i] - qx;
        float dy = cys[i] - qy;
        float dz = czs[i] - qz;
        float d = dx*dx + dy*dy + dz*dz;
        if (d < bestDist) {
            bestDist = d;
            bestIdx = (int)i;
        }
    }
    outIndices[q] = bestIdx;
    outDists[q] = bestDist;
}

void runKnnSoa(
    const PointCloudSoA& cloud,
    const PointCloudSoA& queries,
    int* dOutIndices, float* dOutDists,
    cudaStream_t stream
) {
    int threads = 256;
    int blocks = ((int)queries.n + threads - 1) / threads;
    knnSoaKernel<<<blocks, threads, 0, stream>>>(
        cloud.xs, cloud.ys, cloud.zs, cloud.n,
        queries.xs, queries.ys, queries.zs, queries.n,
        dOutIndices, dOutDists
    );
}
