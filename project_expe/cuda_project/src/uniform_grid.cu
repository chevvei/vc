// src/uniform_grid.cu
// Uniform Grid（均匀网格）空间索引构建
//
// 整体流水线（三步范式，也是 GPU 空间哈希/BVH/粒子模拟的通用套路）：
//   ① 计数 count：每个点属于哪个格子？每个格子多少点？（atomicAdd）
//   ② 定位 scan ：算每个格子的点在排序后数组里的起始位置（cub 前缀和）
//   ③ 排队 sort ：按格子编号排序，同格点连续存放（cub 基数排序）
//
// 排完后查询格子 c 的所有点：
//   sortedIndices[ cellStarts[c] .. cellStarts[c] + cellCounts[c] )
// —— 连续区间 → 合并访存，和 SoA 布局优化闭环
//
// 配套文档：docs/teaching_mastery.md §4.0（三故事深挖 + 潜伏 bug 推演）

#include "uniform_grid.h"
#include <cub/cub.cuh>
#include <thrust/sequence.h>
#include <thrust/device_ptr.h>
#include <thrust/execution_policy.h>
#include <cuda_runtime.h>
#include <algorithm>
#include <iostream>

// ---------------------------------------------------------------------------
// 点坐标 → 格子编号（"门牌号"换算）
//
// 参数：
//   x, y, z    当前点的世界坐标
//   ox,oy,oz   grid 原点（包围盒左下角，本项目固定 -100）
//   cs         cell size，每个格子的边长
//   gx,gy,gz   每轴格子数（= 200 / cs）
// 返回：
//   线性 cellId（三维格坐标拍扁成一维）；越界返回 -1
//
// 公式拆解（以 x 轴为例）：cx = floorf((x - ox) / cs)
//   (x - ox)  绝对坐标 → 相对原点的距离（"从盒子角量起多远"）
//   / cs      距离 → 跨过了几个格子
//   floorf    向下取整 → 掉进哪个格子（区间左闭右开 [ox+k*cs, ox+(k+1)*cs)）
//
// ⚠️ 必须用 floorf，不能直接 (int) 强转：
//   (int) 向零截断：越界点 x=-100.5 算出 -0.25 → (int) = 0，静默混进 cell 0
//   floorf(-0.25) = -1，才能被下面的 cx < 0 检查抓住
//   floorf 是越界检测的守护者
// ---------------------------------------------------------------------------
__device__ inline int computeCellIdDevice(
    float x, float y, float z,
    float ox, float oy, float oz,
    float cs, int gx, int gy, int gz
) {
    int cx = (int)floorf((x - ox) / cs);   // 第几列
    int cy = (int)floorf((y - oy) / cs);   // 第几行
    int cz = (int)floorf((z - oz) / cs);   // 第几层
    // 越界检查：注意左闭右开——恰好压在包围盒右边缘的点 cx == gx，也算越界
    if (cx < 0 || cx >= gx || cy < 0 || cy >= gy || cz < 0 || cz >= gz) return -1;
    // 三维格坐标 → 一维门牌号（"3 栋 2 层 5 号" → 一个编号）
    return (cz * gy + cy) * gx + cx;
}

// ---------------------------------------------------------------------------
// 第 1 步：计数 —— 每个格子多少点
//
// 并行划分：100 万线程，每人只管自己那 1 个点（各算各的坐标，真并行）。
// 只有写计数器才需要排队：
//   不同格子的 atomicAdd 完全并行；同一格子的请求在 L2 原子单元排队串行。
//   点云均匀（本项目）→ 几乎不用排队，直接 atomic 就够；
//   点聚集 → 同地址串行热点，需 warp 聚合 / smem 白板优化（见 §4.0 故事1）
//
// 为什么必须 atomicAdd：cellCounts[c]++ 编译成 读/加/写 三条指令，
// 两个线程同时读到旧值 5、都写 6 → 丢更新，总数随机偏小。
// ---------------------------------------------------------------------------
__global__ void countCellsKernel(
    const float* xs, const float* ys, const float* zs, size_t n,
    float ox, float oy, float oz, float cs,
    int gx, int gy, int gz,
    int* cellCounts          // [totalCells] 出参：每格点数
) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;   // 全局线程号 = 点编号
    if (i >= (int)n) return;
    int cellId = computeCellIdDevice(xs[i], ys[i], zs[i], ox, oy, oz, cs, gx, gy, gz);
    if (cellId >= 0) atomicAdd(&cellCounts[cellId], 1);   // 越界点不计数
}

// ---------------------------------------------------------------------------
// 第 2 步前置：每个点记录自己的 cellId（作为第 5 步排序的 key）
//
// ⚠️⚠️⚠️ 已知潜伏 bug（教学保留，完整推演见 docs/teaching_mastery.md §4.0 破坏-修复）：
//   越界点这里 key 写 0，但上面 countCellsKernel 没把它计入 counts[0]。
//   设越界点数 = K：排序后 key-0 块实际长度 = counts[0] + K，
//   而 cellStarts 基于不含 K 的 counts → 所有格子查询区间整体左移 K 位，
//   每个格子混入前一块尾巴、丢失自己的尾巴。
//   当前合成数据全在盒内（K=0）所以测试不炸；接入含离群点的真实点云必爆。
//
// 正确写法（哨兵）：cellIds[i] = (cellId >= 0) ? cellId : totalCells;
//   哨兵值比一切合法 cellId 大 → 排序后天然聚在数组末尾，无人查询、无人受害。
//   注意哨兵必须落在合法查询域之外，写 totalCells-1 是错的（受害者换成最后一格）。
// ---------------------------------------------------------------------------
__global__ void fillCellIdsKernel(
    const float* xs, const float* ys, const float* zs, size_t n,
    float ox, float oy, float oz, float cs,
    int gx, int gy, int gz,
    int* cellIds              // [n] 出参：每个点的格子编号（排序 key）
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

// ---------------------------------------------------------------------------
// 构建 Uniform Grid 主流程（六步）
// 数据流：cellCounts --scan--> cellStarts --sort--> sortedIndices
// ---------------------------------------------------------------------------
void buildUniformGrid(
    const PointCloudSoA& cloud,   // SoA 布局点云（xs/ys/zs 三个独立数组）
    float cellSize,               // 格子边长（越小格子越多、点越散）
    UniformGrid& grid,            // 出参：索引结构
    cudaStream_t stream
) {
    grid.cellSize = cellSize;
    grid.n = cloud.n;

    // ---- 第 0 步：host 端定 grid 尺寸 ----
    // 简化：固定包围盒 [-100,100]^3，从 (-100,-100,-100) 开始切格子。
    // 生产代码应先用 reduce 求点云实际包围盒（工程化改造点）
    grid.originX = -100.0f;
    grid.originY = -100.0f;
    grid.originZ = -100.0f;
    grid.gridSizeX = (int)(200.0f / cellSize);   // 每轴格数 = 边长 / cellSize
    grid.gridSizeY = grid.gridSizeX;
    grid.gridSizeZ = grid.gridSizeX;
    size_t totalCells = (size_t)grid.gridSizeX * grid.gridSizeY * grid.gridSizeZ;

    // ---- 第 1 步：分配计数器并清零 ----
    // memsetAsync 走 stream，和后续 kernel 排队执行，不阻塞 CPU
    cudaMalloc(&grid.cellCounts, totalCells * sizeof(int));
    cudaMemsetAsync(grid.cellCounts, 0, totalCells * sizeof(int), stream);

    // ---- 第 2 步：atomic 计数每个格子的点数 ----
    int threads = 256;
    int blocks = ((int)cloud.n + threads - 1) / threads;
    countCellsKernel<<<blocks, threads, 0, stream>>>(
        cloud.xs, cloud.ys, cloud.zs, cloud.n,
        grid.originX, grid.originY, grid.originZ, grid.cellSize,
        grid.gridSizeX, grid.gridSizeY, grid.gridSizeZ,
        grid.cellCounts
    );

    // ---- 第 3 步：cub 前缀和，算每个格子的起始位置 ----
    // exclusive scan：cellStarts[c] = 前 c 个格子的点数总和（不含自己）
    //   例：counts=[3,1,1,2] → starts=[0,3,4,5]
    // 为什么不能用 for 循环：starts[i] 依赖 starts[i-1]，O(N) 依赖链是 GPU 天敌；
    // cub 内部用 Blelloch scan 做到 O(log N) 深度 + O(N) 工作量——别手写，边界全是坑
    //
    // cub 两段式调用 pattern（所有 cub::Device* API 通用）：
    //   第一次传 nullptr：只问"需要多少临时空间"
    //   分配 temp 后第二次调用：真跑
    //
    // ⚠️ 工程化改造点：cudaMalloc/cudaFree 放在热路径（每帧 build）开销大
    // （隐式同步 + 分配器开销），生产代码应缓存 temp buffer 复用（诊断卡 14）
    cudaMalloc(&grid.cellStarts, totalCells * sizeof(int));
    size_t tempBytes = 0;
    cub::DeviceScan::ExclusiveSum(nullptr, tempBytes, grid.cellCounts, grid.cellStarts,
                                  (int)totalCells, stream);
    void* tempBuf = nullptr;
    cudaMalloc(&tempBuf, tempBytes);
    cub::DeviceScan::ExclusiveSum(tempBuf, tempBytes, grid.cellCounts, grid.cellStarts,
                                  (int)totalCells, stream);
    cudaFree(tempBuf);

    // ---- 第 4 步：每个点记录自己的 cellId（排序 key）----
    int* cellIds = nullptr;
    cudaMalloc(&cellIds, cloud.n * sizeof(int));
    fillCellIdsKernel<<<blocks, threads, 0, stream>>>(
        cloud.xs, cloud.ys, cloud.zs, cloud.n,
        grid.originX, grid.originY, grid.originZ, grid.cellSize,
        grid.gridSizeX, grid.gridSizeY, grid.gridSizeZ,
        cellIds
    );

    // ---- 第 5 步：cub 基数排序，按 cellId 排，点索引跟着搬家 ----
    // key-value pair：keys = cellIds，values = 点索引（0..n-1）
    // 排完后 sortedIndices 里同格点连续存放 → 查询端切连续区间 → 合并访存闭环
    //
    // GPU 为什么用 radix 不用快排：比较排序三宗罪（O(N log N) 比较 + 分支发散
    // + 不规则访存）；radix 每 pass = 计数+scan+scatter，规则访存零分支
    cudaMalloc(&grid.sortedIndices, cloud.n * sizeof(int));
    int* sortedCellIds = nullptr;
    cudaMalloc(&sortedCellIds, cloud.n * sizeof(int));
    // values 初始化为 0..n-1（点的原始索引）
    // 注意：SortPairs 不支持 input==output 别名，idxIn 与 sortedIndices 必须是两块 buffer
    int* idxIn = nullptr;
    cudaMalloc(&idxIn, cloud.n * sizeof(int));
    thrust::sequence(thrust::cuda::par.on(stream),
                     idxIn, idxIn + cloud.n);

    // 两段式：先查 temp 大小，再真跑
    // begin_bit=0, end_bit=32：按 32 位全位排序。
    // 工程优化：若 cellId < 65536，end_bit=16 只排 16 位，白拿一倍加速
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

    // 等整条流水线排完（教学简化；生产可用 event/callback 做异步回调）
    cudaStreamSynchronize(stream);
}
