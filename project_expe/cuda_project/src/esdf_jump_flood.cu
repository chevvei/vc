// src/esdf_jump_flood.cu
// ESDF 跳跃洪泛算法 + Kernel Fusion + CUDA Graph
// 教学点：
// 1. jump flooding：log(N) pass 并行距离场构建
// 2. kernel fusion：算距离 + 取最小 + 写回 融合成一个 kernel
// 3. CUDA Graph：固定多 pass 流程一次提交
#include <cuda_runtime.h>
#include <vector>

// 障碍 seed 坐标编码（cellId -> 障碍点三维坐标的"压缩"表示）
// 简化版：seed 存为 64 位 int（x、y、z 各 21 位），值为 -1 表示无 seed
typedef long long SeedCode;

__device__ inline SeedCode encodeSeed(int x, int y, int z) {
    return ((SeedCode)(x & 0x1FFFFF) << 42) | ((SeedCode)(y & 0x1FFFFF) << 21) | (SeedCode)(z & 0x1FFFFF);
}
__device__ inline void decodeSeed(SeedCode s, int& x, int& y, int& z) {
    z = (int)(s & 0x1FFFFF);
    y = (int)((s >> 21) & 0x1FFFFF);
    x = (int)((s >> 42) & 0x1FFFFF);
    // 处理符号扩展
    if (x & 0x100000) x |= ~0x1FFFFF;
    if (y & 0x100000) y |= ~0x1FFFFF;
    if (z & 0x100000) z |= ~0x1FFFFF;
}

__device__ inline float seedDistance(int x, int y, int z, SeedCode s, float voxelSize) {
    int sx, sy, sz;
    decodeSeed(s, sx, sy, sz);
    float dx = (x - sx) * voxelSize;
    float dy = (y - sy) * voxelSize;
    float dz = (z - sz) * voxelSize;
    return sqrtf(dx*dx + dy*dy + dz*dz);
}

// Jump Flooding 一个 pass
// 教学点：kernel fusion 把"取邻居 seed + 算距离 + 比较取最小 + 写回"全融合
__global__ void jumpFloodPassKernel(
    SeedCode* seeds,            // 当前每个体素的最近障碍 seed
    float* dists,                // 当前距离
    int gridSize,                // 三维都是 gridSize
    float voxelSize,
    int jump                     // 当前跳距
) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= gridSize || y >= gridSize || z >= gridSize) return;

    int cell = (z * gridSize + y) * gridSize + x;
    SeedCode bestSeed = seeds[cell];
    float bestDist = (bestSeed >= 0) ? seedDistance(x, y, z, bestSeed, voxelSize) : 1e30f;

    // 查 26 邻居（带 jump 距离）
    for (int dz = -1; dz <= 1; ++dz)
    for (int dy = -1; dy <= 1; ++dy)
    for (int dx = -1; dx <= 1; ++dx) {
        if (dx == 0 && dy == 0 && dz == 0) continue;
        int nx = x + dx * jump;
        int ny = y + dy * jump;
        int nz = z + dz * jump;
        if (nx < 0 || nx >= gridSize || ny < 0 || ny >= gridSize || nz < 0 || nz >= gridSize) continue;
        int ncell = (nz * gridSize + ny) * gridSize + nx;
        SeedCode nSeed = seeds[ncell];
        if (nSeed < 0) continue;
        float d = seedDistance(x, y, z, nSeed, voxelSize);
        // 融合：取距离最小的 seed
        if (d < bestDist) {
            bestDist = d;
            bestSeed = nSeed;
        }
    }

    seeds[cell] = bestSeed;
    dists[cell] = bestDist;
}

// 初始化 seeds：障碍点（来自点云）所在 cell 标记为自身
__global__ void initSeedsKernel(
    const float* xs, const float* ys, const float* zs, size_t n,
    float ox, float oy, float oz, float voxelSize, int gridSize,
    SeedCode* seeds
) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= (int)n) return;
    int cx = (int)floorf((xs[i] - ox) / voxelSize);
    int cy = (int)floorf((ys[i] - oy) / voxelSize);
    int cz = (int)floorf((zs[i] - oz) / voxelSize);
    if (cx < 0 || cx >= gridSize || cy < 0 || cy >= gridSize || cz < 0 || cz >= gridSize) return;
    int cell = (cz * gridSize + cy) * gridSize + cx;
    seeds[cell] = encodeSeed(cx, cy, cz);   // 自己是障碍，seed 是自己
}

// 包装函数：跑多 pass 跳跃洪泛
void runJumpFloodEsdf(
    const float* dxs, const float* dys, const float* dzs, size_t cloudN,
    SeedCode* dSeeds, float* dDists,
    float originX, float originY, float originZ,
    float voxelSize, int gridSize,
    cudaStream_t stream
) {
    // 初始化 seeds 为 -1（无 seed）
    size_t totalCells = (size_t)gridSize * gridSize * gridSize;
    cudaMemsetAsync(dSeeds, 0xFF, totalCells * sizeof(SeedCode), stream);   // -1 全 1

    // 障碍点所在 cell 设 seed 为自己
    int threads = 256;
    int blocks = ((int)cloudN + threads - 1) / threads;
    initSeedsKernel<<<blocks, threads, 0, stream>>>(
        dxs, dys, dzs, cloudN,
        originX, originY, originZ, voxelSize, gridSize, dSeeds
    );

    // 多 pass 跳跃洪泛：jump = gridSize/2, gridSize/4, ..., 1
    // 教学点：固定流程适合用 CUDA Graph 捕获
    cudaGraph_t graph;
    cudaGraphExec_t graphExec;
    cudaStreamBeginCapture(stream, cudaStreamCaptureModeGlobal);

    dim3 block(8, 8, 8);
    dim3 grid((gridSize + 7) / 8, (gridSize + 7) / 8, (gridSize + 7) / 8);

    for (int jump = gridSize / 2; jump >= 1; jump >>= 1) {
        jumpFloodPassKernel<<<grid, block, 0, stream>>>(
            dSeeds, dDists, gridSize, voxelSize, jump);
    }

    cudaStreamEndCapture(stream, &graph);
    cudaGraphInstantiate(&graphExec, graph, 0);

    // 每次执行只需一次 launch
    cudaGraphLaunch(graphExec, stream);

    cudaStreamSynchronize(stream);
    cudaGraphDestroy(graph);
    cudaGraphExecDestroy(graphExec);
}
