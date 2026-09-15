// src/knn_search_kernel.cu
// KNN with Shared Memory Tiling + Warp Shuffle Reduction
//
// 教学点（三个优化叠加，对照 gpu_baseline_aos/gpu_optimized_soa 的暴力版）：
// 1. smem tiling：block 内 256 线程协作拷贝点云 tile 到 shared memory，
//    消除"warp 间重复读 global"——baseline 里每个 warp 都独立扫全云，
//    同一片点云被 8 个 warp 重复读 8 遍；tile 版一个 block 只读 1 遍
// 2. warp shuffle：归约走寄存器（__shfl_xor_sync），不再过 shared memory
// 3. 跨 warp 归约：8 个 warp 的局部最优用 smem 汇总，warp 0 终裁
//
// 并行划分变化（关键！）：
//   baseline：1 线程 = 1 查询点（线程内串行扫全云）
//   tile 版 ：1 block = 1 查询点（256 线程协作扫全云，最后归约出 1 个答案）
//   q 直接取 blockIdx.x，block 数 = 查询点数
#include "pointcloud.h"
#include <cuda_runtime.h>

// K=1 KNN with smem tiling
// 每个 block 处理一个查询点（q = blockIdx.x），blockDim=256 个线程协作
__global__ void knnSmemTilingKernel(
    const float* __restrict__ cxs,
    const float* __restrict__ cys,
    const float* __restrict__ czs,
    size_t cloudN,
    const float* __restrict__ qxs,
    const float* __restrict__ qys,
    const float* __restrict__ qzs,
    size_t queryN,
    int* outIndices,        // [queryN] 出参：最近邻下标
    float* outDists         // [queryN] 出参：平方距离
) {
    // 动态 shared memory 一维数组，手工划分成 5 段：
    //   [tileX: 256 float][tileY: 256 float][tileZ: 256 float][warpBestDist: 8 float][warpBestIdx: 8 int]
    // 为什么用动态（extern）而不是静态 __shared__：大小在 launch 时才指定
    // （见 host 侧 smemBytes 计算），同一 kernel 可按 blockDim 灵活配
    // 注意 warpBestIdx 是 float* 强转 int*，起点要按 float 对齐：
    //   3*256 float + 8 float = 776 float = 3104 B，天然 4 字节对齐，安全
    extern __shared__ float smem[];
    float* tileX = smem;
    float* tileY = smem + blockDim.x;
    float* tileZ = smem + 2 * blockDim.x;
    float* warpBestDist = smem + 3 * blockDim.x;
    int* warpBestIdx = (int*)(smem + 3 * blockDim.x + blockDim.x / 32);

    // 本 block 负责的查询点编号 = block 编号（gridDim.x = queryN）
    int q = blockIdx.x;
    if (q >= (int)queryN) return;

    // 查询点坐标：256 个线程读同一个地址 qxs[q] → broadcast，1 次事务
    float qx = qxs[q], qy = qys[q], qz = qzs[q];

    // 每个线程持有一个候选（它见过的最近点），最后归约出全局最近
    // 这是"归约"而非"扫描"：256 个局部最优 → 1 个全局最优
    float bestDist = 1e30f;
    int bestIdx = -1;

    int tid = threadIdx.x;
    int warpId = tid / 32;      // 本线程属于 block 内第几个 warp（0..7）
    int lane = tid % 32;        // 本线程在 warp 内的座位号（0..31）
    int numWarps = blockDim.x / 32;   // 256/32 = 8

    // 遍历 cloud 的所有 tile（每 tile = blockDim.x = 256 个点）
    // 100 万点 → 3907 个 tile，每 tile 内"1 次协作搬运 + 1 次协作计算"
    for (size_t tileStart = 0; tileStart < cloudN; tileStart += blockDim.x) {
        // 协作拷贝：thread t 加载 tile 中第 t 个点
        // 具体走位：tile 覆盖点 [tileStart, tileStart+256)
        //   tid=0 搬 tileStart+0 的 x → tileX[0]
        //   tid=1 搬 tileStart+1 的 x → tileX[1] ... tid=255 搬 tileStart+255
        // 合并访存大戏在这：warp 0 的 32 线程读 cxs[tileStart+0..31]，
        //   地址连续 128B = 1 条事务（这就是 SoA 布局兑现的地方）
        // 搬进 smem 后，256 个线程算距离时读 smem（~20 周期延迟），
        //   不再碰 global（~400 周期延迟）
        size_t gi = tileStart + tid;    // gi = 该线程负责搬的点的全局下标
        if (gi < cloudN) {              // 最后一 tile 可能不满，越界线程不搬
            tileX[tid] = cxs[gi];
            tileY[tid] = cys[gi];
            tileZ[tid] = czs[gi];
        }
        // 搬完必须同步：等 256 个点全部就位，下面才能开始算
        // （不同线程的 gi 对应不同数据，不等齐会读到旧 tile 的残留）
        __syncthreads();

        // 每个线程只算 tile 中对应位置的一个点（不重复工作）
        // 256 个线程并行处理 256 个点——数据并行，各算各的
        // 和 baseline 的本质区别：baseline 是"1 线程串行算 100 万个点"，
        // 这里是"256 线程并行算 256 个点，循环 3907 轮"
        if (gi < cloudN) {
            // 读自己搬进来的那份（smem 命中，且无 bank conflict：
            // 线程 tid 访问 tileX[tid]，相邻线程访问相邻 bank）
            float dx = tileX[tid] - qx;
            float dy = tileY[tid] - qy;
            float dz = tileZ[tid] - qz;
            float d = dx*dx + dy*dy + dz*dz;
            if (d < bestDist) {          // 更新自己的局部最优
                bestDist = d;
                bestIdx = (int)gi;
            }
        }
        // 算完也要同步：防止跑得快的线程进入下一轮、覆盖 tileX[tid]
        // 时，还有慢线程没读完本轮数据（写后读冲突）
        __syncthreads();
    }

    // ===== 归约阶段：256 个局部最优 → 1 个全局最优，两级归约 =====

    // 第 1 级：warp shuffle 在 warp 内找最小（5 步 log2(32)）
    // __shfl_xor_sync(mask, var, offset)：和"自己 lane 号 XOR offset"的
    // 线程交换 var 值——蝶形配对，32 个数 5 步两两对折：
    //   offset=16: lane0↔16, lane1↔17 ... 两两比出 16 个胜者
    //   offset=8 : lane0↔8,  lane1↔9  ... 比出 8 个
    //   offset=4 : → 4 个；offset=2 → 2 个；offset=1 → 1 个
    // 全程寄存器交换，零 smem、零 global，每步 1 条指令
    // dist 和 idx 必须绑在一起搬（比 dist 换 idx），否则答案张冠李戴
    for (int offset = 16; offset > 0; offset >>= 1) {
        float otherDist = __shfl_xor_sync(0xffffffff, bestDist, offset);
        int otherIdx = __shfl_xor_sync(0xffffffff, bestIdx, offset);
        if (otherDist < bestDist) {
            bestDist = otherDist;
            bestIdx = otherIdx;
        }
    }
    // 循环结束后：每个 warp 的 lane 0 持有本 warp 32 个线程的最优

    // 第 2 级归约：跨 warp，用 smem 做中转站
    // 每个 warp 的 lane 0 把自己的 dist/idx 写到 smem（8 个 warp 写 8 对）
    if (lane == 0) {
        warpBestDist[warpId] = bestDist;
        warpBestIdx[warpId] = bestIdx;
    }
    __syncthreads();   // 等 8 对全部写完

    // warp 0 把 8 个 warp 的结果做最后一次 shuffle 归约
    if (warpId == 0) {
        // lane<8 的线程领一个 warp 的结果；lane 8..31 领"正无穷"陪跑
        // （shuffle 要求全 warp 参与，凑数用 1e30f/-1，永远不会赢）
        float myDist = (lane < numWarps) ? warpBestDist[lane] : 1e30f;
        int myIdx = (lane < numWarps) ? warpBestIdx[lane] : -1;
        // 同款蝶形 5 步（实际只需 log2(8)=3 步，多出的步数在比
        // 1e30f 之间互比，无害）
        for (int offset = 16; offset > 0; offset >>= 1) {
            float otherDist = __shfl_xor_sync(0xffffffff, myDist, offset);
            int otherIdx = __shfl_xor_sync(0xffffffff, myIdx, offset);
            if (otherDist < myDist) {
                myDist = otherDist;
                myIdx = otherIdx;
            }
        }
        // 最终赢家在 lane 0：写回本查询点的答案
        if (lane == 0) {
            outDists[q] = myDist;
            outIndices[q] = myIdx;
        }
    }
}

// host 侧包装
void runKnnSmemTiling(
    const PointCloudSoA& cloud,
    const PointCloudSoA& queries,
    int* dOutIndices, float* dOutDists,
    cudaStream_t stream
) {
    int threads = 256;   // 8 个 warp
    // 关键区别：block 数 = 查询点数（不是 queryN/256）
    // 每个 block 内部 256 线程协作处理 1 个查询点
    int blocks = (int)queries.n;
    // 动态 smem 总量 = 3 个 tile 数组 + 8 个 warp dist + 8 个 warp idx
    //   = 3*256*4B + 8*4B + 8*4B = 3072 + 32 + 32 = 3136 字节
    size_t smemBytes = 3 * threads * sizeof(float)
                     + (threads / 32) * sizeof(float)
                     + (threads / 32) * sizeof(int);
    // 放宽动态 smem 上限（默认 48KB 内不用申请，此处为教学示范：
    // 若 smemBytes 超过架构默认限制，必须显式申请才能 launch 成功）
    cudaFuncSetAttribute(knnSmemTilingKernel,
        cudaFuncAttributeMaxDynamicSharedMemorySize, smemBytes);
    knnSmemTilingKernel<<<blocks, threads, smemBytes, stream>>>(
        cloud.xs, cloud.ys, cloud.zs, cloud.n,
        queries.xs, queries.ys, queries.zs, queries.n,
        dOutIndices, dOutDists
    );
}
