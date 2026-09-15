// src/gpu_optimized_soa.cu
// GPU SoA 优化版：合并访存 + __restrict__
//
// 教学点：SoA（Structure of Arrays）布局 + __restrict__ 指针别名承诺
//
// 【SoA 内存实况】三个独立数组，各自连续：
//
//   cxs: [x0][x1][x2][x3]...   ← 只有 x，连续 4 字节 × N
//   cys: [y0][y1][y2][y3]...   ← 只有 y
//   czs: [z0][z1][z2][z3]...   ← 只有 z
//
// 【这个 kernel 的访存模式：broadcast，不是 coalescing】
//   本 kernel 每线程独立跑 for 循环，同一 warp 的 32 线程在 lockstep 下
//   执行同一条 load 指令、读同一个地址 cxs[i] → 硬件广播，1 次事务。
//   （AoS 版同样 broadcast 读 cloud[i]，读回 12B 也全用上——所以这个
//   特定 kernel 里 SoA 布局本身的收益不大。）
//   SoA 的真正大戏在"线程 t 读第 t 个点"的 kernel（tile 拷贝、fillCellIds）：
//   32 线程读 cxs[t..t+31] 连续 128B = 1 条事务；AoS 同场景要 3 条。
//
// 本版相对 baseline 的实际收益来源：
//   ① __restrict__：承诺无指针别名 → 编译器敢缓存/重排，指令更优
//   ② 三数组独立连续 → L2 缓存局部性好（不夹杂用不到的字段）
//
// __restrict__ 的作用：告诉编译器"这块内存没有别的指针别名指着"
//   没有它，编译器必须假设 cxs 和 outDists 可能重叠，每次都得重新读写
//
// 💼 工程套路 ⑭：const T* __restrict__ 是 CUDA kernel 签名的行业标配
//   零成本、纯收益：不改语义（程序员自己担保没有别名，违反是未定义行为）
//   只帮编译器放开手脚。CPU C++ 也有同款关键字（C99 restrict / 编译器
//   扩展 __restrict），但 GPU 上收益更大——GPU 内存延迟 ~400 周期，编译器敢把 global 读提升（hoist）出循环
//   和敢不敢重排，实测能差 10%~30%。规矩：输入指针一律
//   `const float* __restrict__`，输出指针裸 `float*`（有别名风险的地方
//   绝不加——in/out 同 buffer 的算法加了就是埋雷）
//
// 💼 工程套路 ⑮：profile 驱动，不猜——本文件本身是反面教材的正面用法
//   注意文件头的"教学点"说 SoA 翻倍带宽，但深挖注释又指出本 kernel 是
//   broadcast 模式、收益其实有限——这个"自相矛盾"是刻意的：
//   教科书结论（SoA 快）≠ 本场景事实（broadcast 下差别小）。
//   工程准则：任何布局/优化结论，用 ncu（sectors/req、dram throughput）
//   实测说话，"我以为"在 GPU 上九成是错的。能讲清"教科书说什么、
//   这里为什么不适用、拿什么指标验证"——这就是初级和资深的分界
#include "pointcloud.h"
#include <cuda_runtime.h>

// K=1 暴力 KNN kernel（SoA 版）
// 算法和 gpu_baseline_aos.cu 完全一样：一线程一查询，for 扫全点云
// 唯一区别：内存布局 AoS → SoA，让 warp 内访存连续
//
// 参数（6 个指针是 3 组数组：点云 x/y/z + 查询 x/y/z）：
//   cxs/cys/czs [cloudN]   点云三轴坐标（SoA）
//   qxs/qys/qzs [queryN]   查询点三轴坐标（SoA）
//   outIndices  [queryN]   出参：最近邻下标
//   outDists    [queryN]   出参：平方距离
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
    // 全局线程号 = 查询点编号
    int q = blockIdx.x * blockDim.x + threadIdx.x;
    if (q >= (int)queryN) return;

    // 查询点坐标一次性读进寄存器（3 次 global 读，之后循环不再碰）
    float qx = qxs[q], qy = qys[q], qz = qzs[q];

    // 1e30f 当正无穷初值
    float bestDist = 1e30f;
    int bestIdx = -1;

    // warp 内线程 i 访问 cxs[i]，地址连续 128B -> 合并访存
    // 注意：warp 32 线程同一时刻读同一个 i（各算各的查询点，但都扫同一片点云）
    //   线程 0 读 cxs[i+0]，线程 1 读 cxs[i+1]... 不对——这里是标量循环：
    //   32 个线程各自都读同一个 cxs[i]（i 是循环变量，每线程自己迭代）
    //   妙处：同一时刻 32 线程读同一地址 → 硬件广播（broadcast），1 次事务
    //   而 tile 版（knn_search_kernel.cu）才是"线程 t 读第 t 个点"的真合并模式
    for (size_t i = 0; i < cloudN; ++i) {
        float dx = cxs[i] - qx;
        float dy = cys[i] - qy;
        float dz = czs[i] - qz;
        float d = dx*dx + dy*dy + dz*dz;   // 平方距离（省 sqrt）
        if (d < bestDist) {
            bestDist = d;
            bestIdx = (int)i;
        }
    }
    outIndices[q] = bestIdx;
    outDists[q] = bestDist;
}

// host 侧包装
void runKnnSoa(
    const PointCloudSoA& cloud,
    const PointCloudSoA& queries,
    int* dOutIndices, float* dOutDists,
    cudaStream_t stream
) {
    int threads = 256;
    // 向上取整切 block
    int blocks = ((int)queries.n + threads - 1) / threads;
    knnSoaKernel<<<blocks, threads, 0, stream>>>(
        cloud.xs, cloud.ys, cloud.zs, cloud.n,
        queries.xs, queries.ys, queries.zs, queries.n,
        dOutIndices, dOutDists
    );
}
