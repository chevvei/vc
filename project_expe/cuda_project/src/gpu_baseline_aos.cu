// src/gpu_baseline_aos.cu
// GPU AoS baseline：最朴素暴力，作为对照基线
// 教学点：AoS 布局导致 warp 内非合并访存，带宽利用率低
#include "pointcloud.h"
#include <cuda_runtime.h>

__global__ void knnAosBaselineKernel(
    const PointAoS* __restrict__ cloud,
    size_t cloudN,
    const PointAoS* __restrict__ queries,
    size_t queryN,
    int* outIndices,
    float* outDists
) {
    int q = blockIdx.x * blockDim.x + threadIdx.x;
    if (q >= (int)queryN) return;

    PointAoS qp = queries[q];
    float bestDist = 1e30f;
    int bestIdx = -1;
    for (size_t i = 0; i < cloudN; ++i) {
        float dx = cloud[i].x - qp.x;
        float dy = cloud[i].y - qp.y;
        float dz = cloud[i].z - qp.z;
        float d = dx*dx + dy*dy + dz*dz;
        if (d < bestDist) {
            bestDist = d;
            bestIdx = (int)i;
        }
    }
    outIndices[q] = bestIdx;
    outDists[q] = bestDist;
}

void runKnnAosBaseline(
    const PointAoS* dCloud, size_t cloudN,
    const PointAoS* dQueries, size_t queryN,
    int* dOutIndices, float* dOutDists,
    cudaStream_t stream
) {
    int threads = 256;
    int blocks = ((int)queryN + threads - 1) / threads;
    knnAosBaselineKernel<<<blocks, threads, 0, stream>>>(
        dCloud, cloudN, dQueries, queryN,
        dOutIndices, dOutDists
    );
}
