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
//
// 💼 工程套路 ①：错误检查
//   本文件所有 cudaMalloc/kernel/cub 调用都没检查返回值——这是教学简化。
//   生产代码每个 CUDA API 调用后必须跟 CUDA_CHECK(err) 宏（打文件名+行号），
//   否则一个 launch 失败要等几万行之后才在别的错误里爆出来，定位成本天差地别。
//   标准写法：
//     #define CUDA_CHECK(x) do { cudaError_t e=(x); \
//         if(e!=cudaSuccess){fprintf(stderr,"%s:%d %s\n",__FILE__,__LINE__, \
//         cudaGetErrorString(e)); exit(1);} } while(0)
//   调试期再加一步：kernel 后跟 CUDA_CHECK(cudaGetLastError()) 抓 launch 配置错。
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
    //
    // 💼 工程套路 ②：stream 的隐式顺序保证
    //   注意全程没有插入任何 cudaStreamSynchronize——因为 memset 和
    //   后续 kernel 都提交到同一条 stream，硬件保证按提交顺序执行。
    //   "一条 stream = 一条先进先出的流水线"，这是免同步的关键。
    //   反面写法：这里若用同步版 cudaMemset（走默认 stream），会阻塞
    //   CPU 且可能引入不必要的全局同步点，流水线优势全丢。
    //   唯一要 sync 的地方是函数最末尾取结果（见后）。
    cudaMalloc(&grid.cellCounts, totalCells * sizeof(int));
    cudaMemsetAsync(grid.cellCounts, 0, totalCells * sizeof(int), stream);

    // ---- 第 2 步：atomic 计数每个格子的点数 ----
    // 💼 工程套路 ③：block size = 256 为什么是行业默认甜点
    //   ① 256 是 32（warp）的整数倍 → 不产生残缺 warp（残废 warp 白占调度槽）
    //   ② 寄存器压力温和：256 线程 × 每线程用 R 个寄存器，SM 64K 寄存器
    //      文件够跑多个 block，occupancy 有保障
    //   ③ smem 好切：256×4B = 1KB，tile 化时粒度合适
    //   常见变体：128（寄存器重的 kernel）、512（smem 重、末级归约少一层）。
    //   真正的答案是"用 launch bounds + profile 调"，但 256 是最稳的起点
    int threads = 256;
    // 向上取整套路：(N + T - 1) / T —— 记住这个式子，CUDA 代码里出现频率极高
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
    //
    // 💼 工程套路 ④：cub temp buffer 池化（生产写法骨架）
    //   把 tempBuf 提为类成员/全局资源，一次分配终身复用：
    //     void* tempBuf = nullptr;  size_t tempCap = 0;   // 成员
    //     // 每次 build 时：
    //     size_t need = 0;
    //     cub::DeviceScan::ExclusiveSum(nullptr, need, ...);
    //     if (need > tempCap) { cudaFree(tempBuf);        // 只在不够时重配
    //                            cudaMalloc(&tempBuf, need); tempCap = need; }
    //   两条经验：
    //   ① temp 需求随 N 增长很慢（对数级），"按历史最大值缓存"几乎不重配
    //   ② 也可以顺带查 sort 的 temp 需求，取 max 共用一块——cub 各算法
    //      的 temp buffer 语义相同（不透明暂存区），可共享不可并发共用
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
    //
    // 💼 工程套路 ⑤：radix sort 的位域截断是免费午餐
    //   radix 排序每 4~8 位一个 pass，pass 数 = 有效位数 / 位数每趟。
    //   cellId 值域 = [0, totalCells)，本项目 100 万 < 2^20 → 只需 20 位，
    //   写 end_bit=20 省掉 12 位 = 约 1/3 的 pass。
    //   前提是值域有硬保证（越界点已用哨兵 totalCells 压住上限）。
    //   这个套路泛化：任何"值域已知"的整数排序（点云 Morton 码、像素
    //   颜色、哈希桶号）都值得先问一句"我到底有几位？"
    //
    // 💼 工程套路 ⑥：double buffer——cub sort 的 keys_in/keys_out 不能同址
    //   下面用了 4 块 buffer（cellIds/sortedCellIds/idxIn/sortedIndices）。
    //   生产写法常把 in/out 合并成一块 2N 的缓冲区取两半，省一半分配次数；
    //   连续帧之间还可以 in/out 角色互换（ping-pong），零拷贝复用。
    //   真实 GPU 引擎（粒子系统、光子映射）的排序阶段全是 ping-pong 双缓冲。
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
    //
    // 💼 工程套路 ⑦：结尾 sync 的三种生产替代
    //   ① cudaEventRecord + cudaEventSynchronize：比 stream sync 粒度准
    //      （只等 build，不等 stream 里更早的活），还能测耗时（elapsedTime）
    //   ② cudaLaunchHostFunc / cudaStreamAddCallback：GPU 跑完回调 CPU，
    //      CPU 线程完全解放（雷：回调里禁止调任何 CUDA API）
    //   ③ 干脆不 sync：把 grid 交给"下一帧同 stream 的消费 kernel"，
    //      依赖 stream 保序自动衔接——实时渲染管线（构建→查询→绘制）
    //      的标准做法，CPU 全程不等待（异步回帧）
    cudaStreamSynchronize(stream);
}
