// src/gpu_baseline_aos.cu
// GPU AoS baseline：最朴素暴力 KNN（K=1 最近邻），作为所有优化版本的对照基线
//
// 教学点：AoS（Array of Structures）布局导致 warp 内非合并访存
//
// 【AoS 内存实况】PointAoS = {x,y,z} 三个 float 连排 12 字节：
//
//   地址:    0    4    8   | 12   16   20  | 24  ...
//   内容:  [x0][y0][z0]    [x1][y1][z1]   [x2]...
//           └── 点 0 ──┘   └── 点 1 ──┘
//
//   kernel 里 warp 32 个线程同一时刻各读 cloud[i].x（i 连续）：
//   读的地址 = i*12 + 0 → 0, 12, 24, 36, ... 间隔 12 字节
//   32 个地址散布在 384 字节里，且 x/y/z 三个数组交错
//   → 一条 warp load 指令被硬件拆成多条 128B 事务，带宽利用率 ~33%
//
// 对照 gpu_optimized_soa.cu：SoA 布局下同样 32 线程读 cxs[i] 地址连续 128B，
// 1 条事务搞定，带宽利用率 ~100%。
//
// 💼 工程套路 ⑬：baseline 的价值——没有对照就没有优化
//   这个"明知慢"的版本存在的意义：
//   ① 正确性基准：所有优化版必须和它 diff 输出（逐位比较），答案不同
//      就是优化版有 bug——"先对再快"，没有参照物快无从谈起
//   ② 性能归因：优化版快了 2 倍，是哪一步贡献的？只有逐版本对照
//      （aos → soa → tiling → 空间索引），每步换一个变量，才知道
//      收益来自布局还是来自复用——一次改两处的 benchmark 是玄学
//   ③ 回归检测：新架构/新驱动上先跑 baseline，确定"慢得正常"
//   行业惯例：CUDA 项目里 baseline 永远留在代码库里、参与 CI 比对，
//   不是写完就删的草稿
#include "pointcloud.h"
#include <cuda_runtime.h>

// K=1 暴力 KNN kernel
// 并行划分：一个线程处理一个查询点，线程内 for 循环扫全点云找最近邻
// 复杂度：O(queryN × cloudN)。100 万查询 × 100 万点 = 10^12 次距离计算，
// 纯算力打法——没有任何复用（每个查询点都独立扫一遍点云）
//
// 参数：
//   cloud     [cloudN]  点云（AoS：每个 PointAoS 是 12 字节的 x/y/z 三元组）
//   queries   [queryN]  查询点（同样 AoS）
//   outIndices[queryN]  出参：每个查询点的最近邻在点云中的下标
//   outDists  [queryN]  出参：对应的距离（注意是平方距离，没开根号——省 sqrt）
__global__ void knnAosBaselineKernel(
    const PointAoS* __restrict__ cloud,
    size_t cloudN,
    const PointAoS* __restrict__ queries,
    size_t queryN,
    int* outIndices,
    float* outDists
) {
    // 全局线程号 = 查询点编号：线程 0 管查询 0，线程 1 管查询 1 ...
    int q = blockIdx.x * blockDim.x + threadIdx.x;
    if (q >= (int)queryN) return;   // 尾部 block 多余线程直接退出

    // 把查询点坐标读到寄存器（只读一次，之后 for 循环里不再碰 global 内存）
    PointAoS qp = queries[q];

    // bestDist 用 1e30f 当"正无穷"初值（float 最大 ~3.4e38，比它小就能比下去）
    float bestDist = 1e30f;
    int bestIdx = -1;

    // 串行扫全点云。i 从 0 到 cloudN-1，每个点算一次平方距离
    // 注意：所有 32 个 warp 线程读同一个 i → 读 cloud[i] 的 x/y/z
    //   AoS 下这三个字段和别的点的字段挤在同一 cache line 里，互相"污染"
    for (size_t i = 0; i < cloudN; ++i) {
        // 三轴差值（不开根号：比较 d² 和比较 d 等价，sqrt 是 20+ 周期指令）
        float dx = cloud[i].x - qp.x;
        float dy = cloud[i].y - qp.y;
        float dz = cloud[i].z - qp.z;
        float d = dx*dx + dy*dy + dz*dz;   // 平方距离
        if (d < bestDist) {
            bestDist = d;
            bestIdx = (int)i;              // 记住是点云里第几个点
        }
    }
    // 写回结果：一个查询点两个输出（下标 + 距离）
    outIndices[q] = bestIdx;
    outDists[q] = bestDist;
}

// host 侧包装：按 256 线程/block 切 block 数，launch 进指定 stream
void runKnnAosBaseline(
    const PointAoS* dCloud, size_t cloudN,
    const PointAoS* dQueries, size_t queryN,
    int* dOutIndices, float* dOutDists,
    cudaStream_t stream
) {
    int threads = 256;
    // 向上取整：queryN=1000 → (1000+255)/256 = 4 个 block（1024 线程，尾部 24 个退出）
    int blocks = ((int)queryN + threads - 1) / threads;
    knnAosBaselineKernel<<<blocks, threads, 0, stream>>>(
        dCloud, cloudN, dQueries, queryN,
        dOutIndices, dOutDists
    );
}
