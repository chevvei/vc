// src/knn_search_kernel.cu
// KNN with Shared Memory Tiling + Warp Shuffle Reduction
// 教学点：
// 1. smem tiling：block 内协作拷贝 tile，减少 global 访问次数
// 2. warp shuffle：寄存器级归约，5 步归约 32 数
// 3. 跨 warp 归约：用 smem 做二级归约
#include "pointcloud.h"
#include <cuda_runtime.h>

// K=1 KNN with smem tiling
// 每个 block 处理一个查询点，blockDim=256 个线程协作
__global__ void knnSmemTilingKernel(
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
    // 动态 smem 布局：
    //   tileX[256], tileY[256], tileZ[256]  → 协作缓存
    //   warpBestDist[8]                     → 跨 warp 归约 dist
    //   warpBestIdx[8]                       → 跨 warp 归约 idx
    extern __shared__ float smem[];
    float* tileX = smem;
    float* tileY = smem + blockDim.x;
    float* tileZ = smem + 2 * blockDim.x;
    float* warpBestDist = smem + 3 * blockDim.x;
    int* warpBestIdx = (int*)(smem + 3 * blockDim.x + blockDim.x / 32);

    int q = blockIdx.x;
    if (q >= (int)queryN) return;
    float qx = qxs[q], qy = qys[q], qz = qzs[q];

    // 每个线程持有一个候选（最近邻），最后归约
    float bestDist = 1e30f;
    int bestIdx = -1;

    int tid = threadIdx.x;
    int warpId = tid / 32;
    int lane = tid % 32;
    int numWarps = blockDim.x / 32;

    // 遍历 cloud 的所有 tile（每 tile = blockDim.x 个点）
    for (size_t tileStart = 0; tileStart < cloudN; tileStart += blockDim.x) {
        // 协作拷贝：thread t 加载 tile 中第 t 个点
        size_t gi = tileStart + tid;
        if (gi < cloudN) {
            tileX[tid] = cxs[gi];
            tileY[tid] = cys[gi];
            tileZ[tid] = czs[gi];
        }
        __syncthreads();

        // 每个线程只算 tile 中对应位置的一个点（不重复工作）
        // 这样 256 个线程并行处理 256 个点
        if (gi < cloudN) {
            float dx = tileX[tid] - qx;
            float dy = tileY[tid] - qy;
            float dz = tileZ[tid] - qz;
            float d = dx*dx + dy*dy + dz*dz;
            if (d < bestDist) {
                bestDist = d;
                bestIdx = (int)gi;
            }
        }
        __syncthreads();
    }

    // 第 1 级归约：warp shuffle 在 warp 内找最小（5 步 log2(32)）
    for (int offset = 16; offset > 0; offset >>= 1) {
        float otherDist = __shfl_xor_sync(0xffffffff, bestDist, offset);
        int otherIdx = __shfl_xor_sync(0xffffffff, bestIdx, offset);
        if (otherDist < bestDist) {
            bestDist = otherDist;
            bestIdx = otherIdx;
        }
    }

    // 第 2 级归约：warp 0 把 8 个 warp 的结果再归约一次
    // 每个 warp 的 lane 0 写自己的 dist 和 idx 到 smem
    if (lane == 0) {
        warpBestDist[warpId] = bestDist;
        warpBestIdx[warpId] = bestIdx;
    }
    __syncthreads();

    // warp 0 把 numWarps 个 warp 的最小值归约
    if (warpId == 0) {
        float myDist = (lane < numWarps) ? warpBestDist[lane] : 1e30f;
        int myIdx = (lane < numWarps) ? warpBestIdx[lane] : -1;
        for (int offset = 16; offset > 0; offset >>= 1) {
            float otherDist = __shfl_xor_sync(0xffffffff, myDist, offset);
            int otherIdx = __shfl_xor_sync(0xffffffff, myIdx, offset);
            if (otherDist < myDist) {
                myDist = otherDist;
                myIdx = otherIdx;
            }
        }
        if (lane == 0) {
            outDists[q] = myDist;
            outIndices[q] = myIdx;
        }
    }
}

void runKnnSmemTiling(
    const PointCloudSoA& cloud,
    const PointCloudSoA& queries,
    int* dOutIndices, float* dOutDists,
    cudaStream_t stream
) {
    int threads = 256;   // 8 个 warp
    int blocks = (int)queries.n;
    // 3 个 tile + warpBestDist[8] + warpBestIdx[8]
    size_t smemBytes = 3 * threads * sizeof(float)
                     + (threads / 32) * sizeof(float)
                     + (threads / 32) * sizeof(int);
    cudaFuncSetAttribute(knnSmemTilingKernel,
        cudaFuncAttributeMaxDynamicSharedMemorySize, smemBytes);
    knnSmemTilingKernel<<<blocks, threads, smemBytes, stream>>>(
        cloud.xs, cloud.ys, cloud.zs, cloud.n,
        queries.xs, queries.ys, queries.zs, queries.n,
        dOutIndices, dOutDists
    );
}
