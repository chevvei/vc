// src/esdf_jump_flood.cu
// ESDF（Euclidean Signed Distance Field，欧氏符号距离场）跳跃洪泛算法
// + Kernel Fusion + CUDA Graph
//
// 教学点：
// 1. jump flooding：log(N) pass 并行距离场构建——每个体素存"离我最近的
//    障碍在哪"（seed），而不是直接存距离。信息跟着 seed 走，跳着传
// 2. kernel fusion：取邻居 seed + 算距离 + 比较取最小 + 写回，一个 kernel 全做完
//    （反面教材是每步一个 kernel + 中间结果落 global 内存）
// 3. CUDA Graph：固定多 pass 流程一次捕获、一次提交，省每帧 launch 开销
//
// 【ESDF 是什么】机器人的每个体素格子离最近障碍物多远：
//   dist=0 的面 = 障碍表面，dist 大 = 安全。路径规划用它绕开障碍。
//   32³ = 32768 个体素，每个都要知道"最近障碍"——暴力是 O(体素×障碍点)。
//
// 【Jump Flooding 核心直觉】传染式传播：
//   pass 1：每个体素看 26 个方向上"跳 gridSize/2 步"远的邻居——
//           如果邻居知道最近的障碍，我就抄它的答案（信息一步传半张图）
//   pass 2：跳距减半，再抄一轮（信息传 1/4 + 1/2 步范围）
//   ...    ：跳距 = gridSize/2 → /4 → /8 → ... → 1，共 log2(gridSize) 个 pass
//   结果    ：每个体素都抄到了"真正离我最近的障碍"
//   类比    ：谣言传播——第一轮每人只告诉远方朋友，最后一轮告诉隔壁邻居，
//            几轮后全世界都知道最 accurate 的版本
//
// 💼 工程套路 ⑪：JFA 是近似算法（面试必问的坑）
//   严格说标准 JFA 不保证精确——最坏情况少数体素会拿到"差 1~2 体素"的
//   seed（信息跳着传，可能错过真正的最近障碍）。要精确解，教科书方案：
//     1+JFA：jump=1 的 pass 再多跑一遍（多一个 pass，实践上消除误差）
//     或 JFA+1：最后一个 pass 后再跑一遍 3×3 邻域精修
//   本实现只跑到 jump=1，教学场景够用；机器人避障 ESDF 通常容忍毫米级误差。
//   生产界的另一条路：nvblox/Voxblox 不做全量 JFA，而是增量式只更新
//   障碍表面附近的窄带（band）——真实机器人 SLAM 里地图大多静止，
//   全场重算就是浪费，"只更新变化的区域"是 ESDF 工程化的核心套路
#include <cuda_runtime.h>
#include <vector>

// 障碍 seed 坐标编码（cellId -> 障碍点三维坐标的"压缩"表示）
// 简化版：seed 存为 64 位 int（x、y、z 各 21 位），值为 -1 表示无 seed
//
// 为什么压缩成 1 个 int64 而不是 3 个 int：jump flood 的核心操作是
// "把邻居的 seed 抄过来"——单个原子数据天然免锁、免三字段一致性维护
//
// 位布局（63 位用到 63..0，最高位空着给 -1 判断用）：
//   63       62..42    41..21    20..0
//   [空]      [x 21位]  [y 21位]  [z 21位]
//   21 位能存 0..2097151（2^21-1），本项目 gridSize=32 绰绰有余
typedef long long SeedCode;

// 坐标 → seed 码：三个 21 位字段拼进一个 int64
// 0x1FFFFF = 0b0...011111111111111111111（21 个 1），& 操作只留低 21 位
// 例：x=5, y=2, z=9 → (5LL<<42) | (2LL<<21) | 9LL
__device__ inline SeedCode encodeSeed(int x, int y, int z) {
    return ((SeedCode)(x & 0x1FFFFF) << 42) | ((SeedCode)(y & 0x1FFFFF) << 21) | (SeedCode)(z & 0x1FFFFF);
}

// seed 码 → 坐标：按位段抠出来
// 符号扩展处理：21 位字段里最高位（bit20）是符号位，若是 1 说明是负数，
//   要把高位全填 1 才能还原正确的负值（否则 -1 会被解成 2097151）
//   例：字段值 0x1FFFFF（全 1）→ x |= ~0x1FFFFF → 高位全 1 → 还原为 -1
__device__ inline void decodeSeed(SeedCode s, int& x, int& y, int& z) {
    z = (int)(s & 0x1FFFFF);
    y = (int)((s >> 21) & 0x1FFFFF);
    x = (int)((s >> 42) & 0x1FFFFF);
    // 处理符号扩展
    if (x & 0x100000) x |= ~0x1FFFFF;
    if (y & 0x100000) y |= ~0x1FFFFF;
    if (z & 0x100000) z |= ~0x1FFFFF;
}

// 体素 (x,y,z) 到 seed 所指障碍坐标的欧氏距离
// 每次比较都要现算：seed 是"最近障碍的坐标"，距离随查询体素变化
__device__ inline float seedDistance(int x, int y, int z, SeedCode s, float voxelSize) {
    int sx, sy, sz;
    decodeSeed(s, sx, sy, sz);
    // 体素坐标差 × 体素边长 = 物理距离（米）
    float dx = (x - sx) * voxelSize;
    float dy = (y - sy) * voxelSize;
    float dz = (z - sz) * voxelSize;
    return sqrtf(dx*dx + dy*dy + dz*dz);   // 这里必须开根号：ESDF 要真实欧氏距离
}

// Jump Flooding 一个 pass
// 教学点：kernel fusion 把"取邻居 seed + 算距离 + 比较取最小 + 写回"全融合
// （分拆版会是什么样：pass1 kernel 写邻居候选到 global，pass2 kernel 再
//   比较取最小——多一轮 global 读写 + 多一次 launch。融合版全在寄存器/smem 流量内完成）
//
// 线程映射：三维 grid × 三维 block，一个线程管一个体素
//   block = 8×8×8 = 512 线程，grid = (gridSize/8)³
__global__ void jumpFloodPassKernel(
    SeedCode* seeds,            // 当前每个体素的最近障碍 seed（既是输入也是输出）
    float* dists,               // 当前距离（同样 in-place 更新）
    int gridSize,               // 三维都是 gridSize（本项目 32）
    float voxelSize,
    int jump                    // 当前跳距：32/2=16 → 8 → 4 → 2 → 1，共 5 个 pass
) {
    // 三维线程号 → 体素坐标（对照一维 kernel 的 blockIdx.x * blockDim.x + threadIdx.x）
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= gridSize || y >= gridSize || z >= gridSize) return;

    // 三维坐标拍扁成一维下标（和 uniform_grid 的 cellId 同款公式）
    int cell = (z * gridSize + y) * gridSize + x;

    // 我当前的 seed 和距离（先按"已有答案"初始化；seed=-1 表示我还不知道
    // 任何障碍，距离设正无穷等着被邻居的好消息覆盖）
    SeedCode bestSeed = seeds[cell];
    float bestDist = (bestSeed >= 0) ? seedDistance(x, y, z, bestSeed, voxelSize) : 1e30f;

    // 查 26 邻居（带 jump 距离）
    // 26 = 3×3×3 立方邻域去掉自己（dz,dy,dx 各取 -1/0/+1，全组合 27 减 1）
    // 邻居位置 = 我的坐标 + 方向 × jump。jump=16 时看的是 16 格外的
    // "远方邻居"——第一轮就能把半张图外的信息抄回来
    // 注意循环顺序 dx 最内层：内存访问按 x 快速变化，x 是连续维度，
    //   ncell 的地址 stride=1，对合并访存友好
    for (int dz = -1; dz <= 1; ++dz)
    for (int dy = -1; dy <= 1; ++dy)
    for (int dx = -1; dx <= 1; ++dx) {
        if (dx == 0 && dy == 0 && dz == 0) continue;   // 跳过自己
        int nx = x + dx * jump;
        int ny = y + dy * jump;
        int nz = z + dz * jump;
        // 跳出边界的邻居不存在（jump 大时很常见，边界体素的大半邻居会跳过）
        if (nx < 0 || nx >= gridSize || ny < 0 || ny >= gridSize || nz < 0 || nz >= gridSize) continue;
        int ncell = (nz * gridSize + ny) * gridSize + nx;
        SeedCode nSeed = seeds[ncell];
        if (nSeed < 0) continue;    // 邻居也不知道障碍在哪，跳过
        // 邻居的 seed 对"我"来说有多近？（注意：算的是邻居的 seed 到我
        // 的距离，不是到邻居的距离——这一步是 JFA 精度关键）
        float d = seedDistance(x, y, z, nSeed, voxelSize);
        // 融合：取距离最小的 seed
        if (d < bestDist) {
            bestDist = d;
            bestSeed = nSeed;    // 抄邻居的答案
        }
    }

    // 写回（in-place：seeds/dists 同时是本 pass 输入和输出）
    // ⚠️ 教学重点——这里存在数据竞争，但是"良性竞争"（benign race）：
    //   线程 A 读 seeds[B] 的同时，线程 B 可能正在写 seeds[B]。为什么安全：
    //   ① 8 字节对齐的 int64 读写硬件上不会撕裂，读到的必是完整的旧值或新值
    //   ② 读到旧值 = 本轮没抄到这个邻居，下个 pass（jump 减半）还有机会
    //   ③ 读到新值 = 提前拿到好消息，无害
    //   JFA 论文原版就这么写。对照反例：countCellsKernel 的 cellCounts[c]++
    //   是"读-改-写"三步，竞争会丢更新，必须 atomic——读最新值即可的场景
    //   和必须累加所有更新的场景，是"要不要同步"的分界线
    seeds[cell] = bestSeed;
    dists[cell] = bestDist;
}

// 初始化 seeds：障碍点（来自点云）所在 cell 标记为自身
// "我脚下就是障碍，我的 seed 是我自己，距离 0"
__global__ void initSeedsKernel(
    const float* xs, const float* ys, const float* zs, size_t n,
    float ox, float oy, float oz, float voxelSize, int gridSize,
    SeedCode* seeds
) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= (int)n) return;
    // 点坐标 → 体素坐标（和 uniform_grid 的 computeCellIdDevice 同款换算）
    int cx = (int)floorf((xs[i] - ox) / voxelSize);
    int cy = (int)floorf((ys[i] - oy) / voxelSize);
    int cz = (int)floorf((zs[i] - oz) / voxelSize);
    // 落在 grid 外的点不参与（floorf 守护负数，同 uniform_grid 的教训）
    if (cx < 0 || cx >= gridSize || cy < 0 || cy >= gridSize || cz < 0 || cz >= gridSize) return;
    int cell = (cz * gridSize + cy) * gridSize + cx;
    seeds[cell] = encodeSeed(cx, cy, cz);   // 自己是障碍，seed 是自己
    // 多个障碍点落同一 cell：后写的覆盖先写的，无损（都是"这个 cell 有障碍"
    // 的等价信息，最终距离由 pass 阶段逐体素精确比较决定）
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
    // 技巧：0xFF 是按字节填充——每字节全 1，int64 的 8 个字节全变 0xFF
    //   = 0xFFFFFFFFFFFFFFFF = -1。一行 memset 搞定"全部置 -1"
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
    // gridSize=32 → jump 序列 16,8,4,2,1 → 5 个 pass = log2(32)
    // 教学点：固定流程适合用 CUDA Graph 捕获
    //
    // 【CUDA Graph 三步走】
    //   ① BeginCapture：stream 进入"录制模式"——之后 launch 的 kernel
    //      不执行，只记进图（拓扑 + 参数快照）
    //   ② EndCapture：结束录制，拿到 graph 对象
    //   ③ Instantiate + Launch：把图编译成可重复执行体，一次 launch 全跑
    //   收益：5 个 kernel 的 launch 只花 1 次 CPU 开销；每帧重建 ESDF 时
    //   图已编译好，直接 replay（生产代码会把 graphExec 缓存成成员变量）
    //
    // 💼 工程套路 ⑫：Graph 的生产形态——捕获一次，永久 replay
    //   本函数每帧"捕获→实例化→销毁"是教学写法，实际等于没省 launch
    //   开销还倒贴捕获成本。生产套路：
    //     ① 首帧：捕获 + instantiate，graphExec 存为成员变量
    //     ② 之后每帧：只调 cudaGraphLaunch(graphExec, stream)  ← 一行
    //     ③ 参数变了（换点云/换 grid）：优先 cudaGraphExecUpdate
    //        （改指针参数原位更新，比重新实例化便宜一个量级），
    //        拓扑变了才重新捕获
    //   适用判据：图的价值 = launch 数 × 提交频率。固定 5~10 个 kernel
    //   的小图每帧跑，CPU 开销从 ~50μs 降到 ~5μs；单 kernel 的图没意义。
    //   雷区：捕获中的 stream 不能做隐式同步（cudaMalloc 会炸捕获），
    //   所以本函数所有分配都放在 BeginCapture 之前——这个顺序是刻意的
    cudaGraph_t graph;
    cudaGraphExec_t graphExec;
    cudaStreamBeginCapture(stream, cudaStreamCaptureModeGlobal);

    // 8×8×8 = 512 线程/block，三维切 grid
    dim3 block(8, 8, 8);
    dim3 grid((gridSize + 7) / 8, (gridSize + 7) / 8, (gridSize + 7) / 8);

    // 5 次 launch 全部录进图（此时不执行）
    for (int jump = gridSize / 2; jump >= 1; jump >>= 1) {
        jumpFloodPassKernel<<<grid, block, 0, stream>>>(
            dSeeds, dDists, gridSize, voxelSize, jump);
    }

    cudaStreamEndCapture(stream, &graph);          // 结束录制
    cudaGraphInstantiate(&graphExec, graph, 0);    // 编译成可执行体

    // 每次执行只需一次 launch（图内 5 个 kernel 按录制的拓扑依序执行）
    cudaGraphLaunch(graphExec, stream);

    cudaStreamSynchronize(stream);
    cudaGraphDestroy(graph);
    cudaGraphExecDestroy(graphExec);
}
