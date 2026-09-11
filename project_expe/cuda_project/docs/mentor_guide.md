# 导师带教手册｜从零到能面试的 CUDA 性能优化之路

> **角色设定**：我是你的导师，你是一个有 C++ 工程经验、但没系统学过 CUDA 的工程师。
> **目标**：通过这份手册，你将真懂 CUDA 优化的"为什么"，在面试中展现性能优化能力。
> **方法**：苏格拉底式提问 + 故事导入 + 渐进式实验 + 面试模拟。
> **配套**：搭配 `teaching_mastery.md`（知识点精讲）+ `interview_talk.md`（面试讲稿）+ `code_walkthrough.md`（代码实例讲解）使用。
>
> **学习节奏建议**：分 9 阶段，每阶段 1-2 小时。不要跳读，每阶段都有自检，过了再进。

---

## 代码文件 → 学习阶段映射表

每阶段学完概念后，去对应文件看真实代码 + 逐行讲解：

| 阶段 | 文件 | 知识点 | 代码讲解位置 |
|------|------|--------|--------------|
| 1 | [gpu_baseline_aos.cu](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/gpu_baseline_aos.cu) | 第一个 kernel + AoS 痛点 | [code_walkthrough §阶段1](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/docs/code_walkthrough.md) |
| 2 | [baseline_cpu.cpp](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/baseline_cpu.cpp) | CPU 基线对照 | 同上 §阶段2 |
| 3 | [pointcloud.h](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/pointcloud.h) + [.cpp](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/pointcloud.cpp) | pinned + async copy | 同上 §阶段3 |
| 4 | [gpu_optimized_soa.cu](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/gpu_optimized_soa.cu) | SoA + 合并访存 | 同上 §阶段4 |
| 5 | [knn_search_kernel.cu](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/knn_search_kernel.cu) | smem tiling + warp shuffle | 同上 §阶段5 |
| 6 | [uniform_grid.cu](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/uniform_grid.cu) | atomic + cub scan/sort | 同上 §阶段6 |
| 7 | [esdf_jump_flood.cu](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/esdf_jump_flood.cu) | jump flooding + fusion + graph | 同上 §阶段7 |
| 8 | [benchmark.cpp](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/benchmark.cpp) | CUDA Event 计时 | 同上 §阶段8 |
| 9 | [main.cpp](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/main.cpp) | 集成验证 | 同上 §阶段9 |

---

## 学习路径全景图

```
你在这里                                              面试官坐这里
   ↓                                                       ↑
[阶段0]为什么学CUDA → [阶段1]编程模型 → [阶段2]第一个瓶颈
   → [阶段3]数据搬运 → [阶段4]内存布局 → [阶段5]并行调度
   → [阶段6]空间索引 → [阶段7]算法协作 → [阶段8]工程化
   → [阶段9]面试模拟：能讲、能答、能画
```

**每阶段学完能讲什么**（这是检验掌握的标准）：

| 阶段 | 学完后能讲什么                                           |
| ---- | -------------------------------------------------------- |
| 0    | "GPU 为什么适合并行计算，CPU 不适合"                     |
| 1    | "CUDA 的线程层次，kernel 怎么 launch"                    |
| 2    | "我的 kernel 为什么慢，怎么 profile 定位"                |
| 3    | "数据搬运怎么 pipeline 起来"                             |
| 4    | "为什么 SoA 比 AoS 快 3 倍"                              |
| 5    | "smem tiling + warp shuffle 怎么把 KNN 从 50ms 干到 5ms" |
| 6    | "atomic + cub 怎么构建空间索引"                          |
| 7    | "jump flooding + kernel fusion + CUDA Graph 的协作优化"  |
| 8    | "occupancy 调优、数值稳定性、benchmark 自动化"           |
| 9    | "我做了一个 CUDA 项目，从 2000ms 优化到 5ms，400 倍加速" |

---

# 阶段 0：为什么学 CUDA ——建立学习动机

## 🎯 本阶段目标

让你明白"为什么"要学 CUDA，建立学习动机。没有动机，后面学不动。

## 📖 故事：一个性能问题的诞生

**场景**：你入职一家自动驾驶公司，老板给你一个任务：

> "我们的激光雷达每秒产生 100 万个 3D 点。对每个点，要从历史点云里找最近邻。现在 CPU 跑 2000ms 一帧，我们要做到 30FPS（33ms 一帧）。你来想办法。"

你试了各种 CPU 优化：循环展开、SIMD、多线程，最好也就 500ms。**到顶了**。

为什么？因为 CPU 只有 16 个核，再怎么优化也是 16 个核在算。100 万个点，每个核要算 62500 个点，每个点查 100 万个历史点——单核要做 625 亿次距离计算。CPU 单核 4GHz，算一次距离大约 10ns，需要 625 秒——爆了。

**这时候有人告诉你**：GPU 有几千个核，可以同时算。

你算了一下：100 万点，GPU 也有 1 万个核在并行，每个核只要算 100 个点，每个点查 100 万历史点...等等，1 万核 × 100 万点 × 100 万历史 = 天文数字？不，你理解错了——**GPU 的并行是"一个查询点一个核"，每个核扫所有历史点**。

100 万查询点 ÷ 1 万核 = 100 点/核
每核扫 100 万历史点 × 10ns = 1ms/点 × 100 点 = 100ms

**从 2000ms 到 100ms，20 倍加速**——这就是 GPU 并行的威力。

这就是我们项目要解决的问题。整个学习路径，就是"从 2000ms 一步步优化到 5ms"的故事。

## 🗣️ 面试讲法

> 面试官问：你为什么学 CUDA？
> 你答：我在做激光雷达点云处理时，KNN 最近邻查询 CPU 跑 2000ms 一帧，无法满足 30FPS 实时性。CPU 16 核已经到顶。我学了 CUDA 后，用 GPU 1 万核并行，把单点查询降到 us 级，最终做到 5ms 一帧。**性能问题逼着我学 CUDA，不是为学而学**。

## ❓ 自检

- 100 万点 KNN 在 CPU 上为什么慢到无解？→ 单核串行，625 亿次距离计算，物理上跑不动
- GPU 1 万核并行能解决吗？→ 能，每核分摊 100 点，每点扫 100 万历史，约 100ms。还能继续优化到 5ms（后面学）

---

# 阶段 1：CUDA 编程模型 ——会写第一个 kernel

## 🎯 本阶段目标

学会 CUDA 编程基本概念，能写出第一个能跑的 kernel。

## 📖 故事：从 C++ 到 CUDA 的最小迁移

你写 C++ 的点云距离计算：

```cpp
// C++ 版本：CPU 单线程
for (int i = 0; i < N; ++i) {
    float dx = cloud[i].x - query.x;
    float dy = cloud[i].y - query.y;
    float dz = cloud[i].z - query.z;
    dist[i] = dx*dx + dy*dy + dz*dz;
}
```

CUDA 版本几乎一模一样：

```cpp
// CUDA 版本：GPU 1 万核同时跑
__global__ void computeDist(Point* cloud, Point query, float* dist, int N) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;  // 我是第几个线程
    if (i >= N) return;                              // 越界保护
    float dx = cloud[i].x - query.x;
    float dy = cloud[i].y - query.y;
    float dz = cloud[i].z - query.z;
    dist[i] = dx*dx + dy*dy + dz*dz;
}

// 启动：1 万个线程
int threads = 256;
int blocks = (N + threads - 1) / threads;
computeDist<<<blocks, threads>>>(dCloud, dQuery, dDist, N);
```

**核心改动**：

- `__global__` 关键字：标记这个函数是"在 GPU 上跑、从 CPU 调用"
- `blockIdx.x * blockDim.x + threadIdx.x`：算"我是第几个线程"——这是 CUDA 编程的"hello world"
- `<<<blocks, threads>>>`：启动时告诉 GPU 开多少 block、每 block 多少 thread

## 📖 线程层次（这是 CUDA 的核心概念）

GPU 线程有严格的编制：

```
Grid（军队）              ← 一次 kernel launch 的全部线程
  └─ Block（团）           ← 独立驻扎，可共享 shared memory，可 __syncthreads 同步
       └─ Warp（班）       ← 32 人锁步执行，必须走同一条指令路
            └─ Thread（兵） ← 单个执行单元
```

**关键规则**（背下来，面试会问）：

1. **Warp 是执行单位**：32 线程必须执行**完全相同的指令**。if/else 让 32 人走不同路 = 一半人闲着（warp divergence）。
2. **Block 内可通信**：同 block 的线程共享 shared memory，可以 `__syncthreads()` 同步。
3. **Block 之间不能通信**：不同 block 没有同步机制，只能通过 global memory 间接通信。

**为什么 warp 是 32？** 这是硬件设计：GPU 的 SIMT 调度器一次发射 32 条相同指令给 32 个线程。这是硬件事实，不是软件约定。

## 🧪 动手实验：写 vector add

最小可跑的 CUDA 程序：

```cpp
// vector_add.cu
#include <cstdio>

__global__ void vecAdd(float* a, float* b, float* c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

int main() {
    int N = 1 << 20;  // 1M 元素
    float *hA = new float[N], *hB = new float[N], *hC = new float[N];
    for (int i = 0; i < N; ++i) { hA[i] = i; hB[i] = i * 2; }

    float *dA, *dB, *dC;
    cudaMalloc(&dA, N * sizeof(float));
    cudaMalloc(&dB, N * sizeof(float));
    cudaMalloc(&dC, N * sizeof(float));
    cudaMemcpy(dA, hA, N * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(dB, hB, N * sizeof(float), cudaMemcpyHostToDevice);

    vecAdd<<<(N+255)/256, 256>>>(dA, dB, dC, N);
    cudaDeviceSynchronize();

    cudaMemcpy(hC, dC, N * sizeof(float), cudaMemcpyDeviceToHost);
    printf("c[0]=%f c[N-1]=%f\n", hC[0], hC[N-1]);
}
```

编译运行：

```bash
nvcc vector_add.cu -o vecadd && ./vecadd
# 输出：c[0]=0.000000 c[N-1]=3145726.000000
```

**走通这个，你就掌握了 CUDA 的"hello world"**。

## 🗣️ 面试讲法

> 面试官问：CUDA 编程模型是什么？
> 你答：CUDA 是 SIMT（Single Instruction Multiple Thread）模型。一次 launch 启动一个 grid，grid 分多个 block，block 内分多个 warp（每 warp 32 线程锁步），warp 内分多个 thread。**关键约束是 warp 32 线程必须执行相同指令**，所以分支要小心，否则 warp divergence 让一半算力浪费。

## ❓ 自检

- 为什么 block 之间不能通信？→ 硬件调度上 block 是独立调度的，可能跑在不同 SM 上，无法保证同步
- `<<<blocks, threads>>>` 写错了（比如 threads 不是 32 倍数）会怎样？→ 程序能跑但效率低，warp 内部分线程闲着
- 同一 warp 内 if/else 两条路怎么执行？→ 串行：先跑 if 分支（else 的线程 idle），再跑 else（if 的线程 idle），吞吐减半

---

# 阶段 2：第一个性能瓶颈 ——学会 profile

## 🎯 本阶段目标

学会用 profiler 定位瓶颈，建立"性能问题不能猜"的工程意识。

## 📖 故事：为什么我的 kernel 慢

你写了第一个 CUDA KNN kernel，一跑——50ms。比 CPU 快，但远没达到理论加速。

**朴素做法**：猜。"是不是循环不够优化？是不是数据没对齐？"——你试了一圈，没用。

**正确做法**：用 profiler 看真相。

```bash
# Nsight Compute：NVIDIA 官方 GPU kernel profiler
ncu --set full ./cuda_spatial_accel

# 关键指标
ncu --metrics dram_throughput,sm_efficiency,gpu_time ./cuda_spatial_accel
```

profiler 告诉你：

- **DRAM throughput: 10%** ← 带宽只用了 10%，99% 时间在等内存
- **Achieved occupancy: 30%** ← 只激活了 30% warp
- **Warp stall reason: "Long scoreboard"** ← 等内存返回

**结论**：不是计算慢，是**访存慢**。GPU 几千核在排队等内存。

## 📖 GPU 内存层次（这是所有优化的根因）

```
寄存器 Register       ~1 cycle    每线程私有，几十个
共享内存 Shared       ~20 cycle   同 block 共享，48-164KB
L1/L2 缓存            ~30-100    硬件自动
全局内存 Global       ~400-800    所有线程，几 GB
```

**记住这个延迟表**——所有 CUDA 优化都在解决：**怎么减少访问 global memory**。

## 🧪 动手实验：profile 你的 kernel

```bash
# 编译要带 -lineinfo 才能看到源码行
nvcc -O2 -lineinfo -o knn knn.cu

# profile
ncu --metrics dram_throughput,gpu_time ./knn

# 看哪个函数慢
ncu --print-summary per-kernel ./knn
```

**	第一个发现**：KNN baseline 的 DRAM 利用率只有 10%，瓶颈在访存。

## 🗣️ 面试讲法

> 面试官问：你怎么定位 CUDA 性能问题？
> 你答：不猜，用 Nsight Compute profile。我看 DRAM throughput、achieved occupancy、warp stall reason。如果 DRAM throughput 10%，说明带宽瓶颈；如果 occupancy 30%，说明寄存器或 smem 占太多。**性能问题不能拍脑袋，必须用 profiler 看数据**。

##                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               ❓ 自检

- 为什么不能"猜"性能问题？→ GPU 几千核，瓶颈可能在计算、访存、调度任一处，肉眼无法判断
- global memory 延迟是多少？→ ~400-800 cycles，是 register 的 400 倍

---

# 阶段 3：数据搬运优化 ——pinned memory + async copy

## 🎯 本阶段目标

学会让"数据搬运"和"计算"并行起来，把数据传输的等待时间省掉。

## 📖 故事：CPU 到 GPU 的快递集散

**情景**：点云数据在 CPU 内存（北京），要搬到 GPU（上海）才能算。

**普通搬运（pageable memory）**：

- 货物散在老百姓家（pageable 内存）
- 操作系统随时可能换页到硬盘
- GPU DMA 搬运时发现"这家的货被搬走了"，要先找到、集中到临时中转站
- 多一道手续，慢

**Pinned memory（锁页）**：

- 货物锁在中转站，操作系统保证不动它
- GPU DMA 直接来拿，省一道手续

**同步搬运**：

- 你发货后，站在收费站等卡车到上海卸完货才回来
- 等待期间你和加工线都闲着

**异步搬运**：

- 卡车自己跑，你立刻去启动加工
- 搬运和计算重叠，省时间

## 📖 是什么

```cpp
// 普通 malloc（慢）
float* hData = (float*)malloc(N * sizeof(float));

// Pinned（快，物理页固定，DMA 直连）
float* hData;
cudaMallocHost(&hData, N * sizeof(float));

// 同步拷贝（CPU 等）
cudaMemcpy(dData, hData, size, cudaMemcpyHostToDevice);

// 异步拷贝（CPU 立刻返回，GPU stream 内排队执行）
cudaMemcpyAsync(dData, hData, size, cudaMemcpyHostToDevice, stream);
```

## 🎯 为什么有效

- **pinned**：DMA 直接搬运，省一次中转拷贝
- **async + stream**：搬运放 stream A，kernel 放 stream B（或同 stream 排队后），GPU 的 DMA engine 和 SM 可以同时工作——这就是 pipeline

## 🧪 动手实验：测两种搬运的时间差

```cpp
// 对比 pinned + async vs pageable + sync
cudaEvent_t start, stop;
cudaEventCreate(&start); cudaEventCreate(&stop);

cudaEventRecord(start, stream);
cudaMemcpyAsync(dData, hPinned, size, cudaMemcpyHostToDevice, stream);
kernel<<<grid, block, 0, stream>>>(dData);
cudaEventRecord(stop, stream);
cudaEventSynchronize(stop);

float ms;
cudaEventElapsedTime(&ms, start, stop);
```

**预期**：1MB 数据，pageable sync ~5ms，pinned + async ~2ms（且能 pipeline）。

## 🗣️ 面试讲法

> 我数据搬运第一步用 pinned memory + cudaMemcpyAsync + stream。普通 malloc 是 pageable 的，CUDA DMA 搬运要中转拷贝一次。pinned 让物理页固定，DMA 直连。async + stream 让搬运和 kernel pipeline 起来。**这是 LLM 推理权重加载的标准做法，我在每个数据入口都用了**。

## ❓ 自检

- pinned 的代价？→ 占用物理内存不能换出，长期占用影响系统
- 同 stream 内的 async 搬运和 kernel 能并行吗？→ 不能，同 stream 按序。要并行必须不同 stream。

---

# 阶段 4：内存布局 ——AoS vs SoA + 合并访存

## 🎯 本阶段目标

理解 GPU 内存访问的硬件粒度，学会让数据布局匹配硬件。

## 📖 故事：仓库货架摆放

你有 100 万个点，每个点有 x、y、z。

**AoS（结构体数组）**：

- 货架摆 `[x0,y0,z0, x1,y1,z1, ...]`
- 想取所有 x？要隔 3 个拿一个，跑来跑去

**SoA（数组结构体）**：

- 三个货架：`[x0,x1,...]`、`[y0,y1,...]`、`[z0,z1,...]`
- 取所有 x？一货架顺序拿，一趟搞定

## 🎯 为什么 GPU 上 SoA 快（硬件根因）

这是 CUDA 优化的核心概念——**合并访存（Coalesced Access）**。

GPU 的 global memory 控制器**一次处理 128 字节事务**。warp 内 32 线程同时访问：

- 每线程读 4 字节 float
- 32 线程 × 4B = 128B

**关键**：如果 32 线程访问**连续**的 128B → 1 次事务完成（合并）；如果**散乱**地址 → 多次事务，带宽利用率 3%。

```
AoS：warp 内 32 线程访问 cloud[0..31].x
     cloud[0].x 在地址 0，cloud[1].x 在地址 12（每个 Point 12B）
     32 线程访问地址间隔 12B → 散乱 → ~10 次事务 → 带宽 10%

SoA：warp 内 32 线程访问 xs[0..31]
     地址连续 0,4,8,12... → 128B → 1 次事务 → 带宽 100%
```

**这就是 50ms → 15ms 的根因**。算法没变，数据摆放匹配了硬件访问粒度。

## 🧪 动手实验：profile 看带宽差异

```bash
ncu --metrics dram_throughput,l2_hit_rate ./knn_aos
# DRAM throughput: 10%

ncu --metrics dram_throughput,l2_hit_rate ./knn_soa
# DRAM throughput: 60%+
```

## 🗣️ 面试讲法

> AoS baseline 50ms 已经 40 倍加速了，但 ncu profile 发现带宽只用了 30%。原因是 warp 内 32 线程访问 `cloud[i].x`，每个 Point 12B，地址间隔 12B 不连续。GPU 一次处理 128B 事务，32×4B=128B 刚好一次，但 AoS 散乱地址让它变成多次事务。改 SoA 后 `xs[i]` 连续 128B，1 次事务，带宽到 60%+，时间降到 15ms。**这不是算法优化，是让数据布局匹配硬件访问粒度**。

> **迁移**：LLM 的 KV Cache 用 SoA，让 warp 内 token 访问 K、V 连续；图像 RGB 分离存储，处理单通道时合并访存。

## ❓ 自检

- GPU 一次内存事务处理多少字节？→ 128 字节
- AoS 和 SoA 哪个对 GPU 更友好？→ SoA，让 warp 内访问地址连续
- `__restrict__` 是什么？→ 告诉编译器指针无别名，可以激进优化（load 提前到 store 前）

---

# 阶段 5：并行调度优化 ——smem tiling + bank conflict + warp shuffle

## 🎯 本阶段目标

学会用片上 SRAM（shared memory）复用数据，用寄存器级归约（warp shuffle）省掉 smem 写回。

## 📖 故事 1：工地协作（smem tiling）

1000 工人（线程）要查 10000 块砖（点云）中哪块最近。

**不用 tiling**：每个工人各自跑仓库（global）取 10000 块 → 1000×10000=1000 万次仓库访问，仓库门堵死。

**用 tiling**：1000 人分若干组，每组 256 人。每次一组协作从仓库搬 1024 块到工位（shared memory），全组共享这 1024 块查。下一批再搬 1024。
复用率 = 1024 / 256 = 4 倍（每块砖被 4 个工人复用）。

## 📖 故事 2：超市收银（bank conflict）

shared memory 内部分 32 个收银台（bank）。warp 内 32 线程每人去一个收银台。

- **无冲突**：32 人各去不同收银台 → 32 路并行
- **Bank conflict**：多人去了**同一收银台** → 那台排队，串行 32 倍

经典坑：`__shared__ float buf[1024]`，如果线程 i 访问 `buf[i*32]`，全撞 bank 0。

**规避**：padding，数组 1024 改 1025，错开 bank 映射。

## 📖 故事 3：传话游戏（warp shuffle reduction）

32 人站一圈，每人手里一个数，要找 32 个数的最小值。

**朴素（smem + atomic）**：每人写白板，一个一个比较取最小（串行），慢。

**Warp shuffle**：

- 第 1 轮：每人转头看对面（距离 16）的人，取小留下（32→16 不同值）
- 第 2 轮：看距离 8 的，16→8
- 第 3 轮：8→4
- 第 4 轮：4→2
- 第 5 轮：2→1

5 步树形归约完成。不经过 smem，纯寄存器交换，无 bank conflict。

```cpp
for (int offset = 16; offset > 0; offset >>= 1) {
    float other = __shfl_xor_sync(0xffffffff, myVal, offset);
    if (other < myVal) myVal = other;
}
// 5 步后 warp 内所有人 myVal 都是最小值
```

## 🎯 为什么快

| 方式          | 步骤     | 访问                       |
| ------------- | -------- | -------------------------- |
| smem + atomic | 串行     | smem 读写 ~20 cycles × 32 |
| warp shuffle  | 5 步并行 | 寄存器交换 ~1 cycle × 5   |

## 🧪 动手实验：跑 KNN smem 版本

```bash
./build/cuda_spatial_accel
# 看 KNN Benchmark：
# CPU:              1043 ms   1.0x
# GPU AoS:            89 ms  11.7x
# GPU SoA:            59 ms  17.7x
# GPU smem+shuffle: 4.72 ms 221x
```

## 🗣️ 面试讲法

> SoA 已经合并访存了，但每查询点要从 global 反复读 100 万点。我用 shared memory tiling + warp shuffle：block 内 256 线程协作拷 tile 到 smem 复用；warp shuffle 寄存器级 5 步归约省 smem 写回+atomic。时间从 59ms 降到 4.72ms，**221 倍加速**。这套思路和 FlashAttention 同源——都是 tile 复用 + 寄存器归约。

> **迁移**：FlashAttention 就是 smem tiling + warp shuffle，把 Q/K/V tile 复用、softmax 归一化用 shuffle。我的 KNN 优化和 FlashAttention 是同源技术。

## ❓ 自检

- shared memory 延迟 vs global？→ 20 vs 400 cycles，差 20 倍
- bank conflict 怎么定位？→ ncu --metrics shared_mem_utilization
- warp shuffle 几步归约 32 数？→ 5 步（log2(32)）

---

# 阶段 6：空间索引 ——atomic + cub

## 🎯 本阶段目标

学会 GPU 上的并发安全写（atomic）和官方优化原语（cub scan/sort）。

## 📖 故事 1：多人计数（atomic）

1000 志愿者统计 100 万包裹分别进了哪个仓库（cell）。

**串行**：1 人挨个点，100 万次。

**并行 + atomic**：1000 人同时点，每人看到包裹就给对应仓库计数器 +1。但计数器共享，多人同时 +1 会冲突。

**atomicAdd**：硬件保证"读-改-写"原子不可打断，不丢更新。

代价：**同一地址的 atomic 是串行的**。100 万人撞同一 cell → 串行灾难。

**优化**：先 smem 局部 reduce，再 atomic 写 global，减少 global atomic 次数。

## 📖 故事 2：分组排队（cub scan + sort）

100 万人按"属于哪个仓库"排队，同仓库的人挨着站，每个仓库起始位置要知道。

**三步**：

1. 计数（atomic，每个 cell 多少点）
2. 前缀和（exclusive scan）：算每个 cell 排序后的起始位置
3. 排序（radix sort）：按 cellId 排序，同 cell 点挨着

```
cellId: [3, 1, 3, 0, 1, 3]  → 排序: [0,1,1,3,3,3]
                                cellStart(0)=0
                                cellStart(1)=1
                                cellStart(3)=3
```

## 🎯 为什么用 cub

不要手写 scan 和 sort——**cub 是 NVIDIA 官方优化原语**，用了 work-efficient parallel scan 算法（O(N) work + O(log N) depth），比手写快且正确。

```cpp
cub::DeviceScan::ExclusiveSum(temp, tempBytes, counts, starts, n, stream);
cub::DeviceRadixSort::SortPairs(temp, tempBytes, keys, keysOut, vals, valsOut, n, 0, 32, stream);
```

## 🗣️ 面试讲法

> Uniform grid 构建三步：atomic 计数 + cub exclusive sum 算 cell 起始 + cub radix sort 把点按 cellId 排序。atomic 是 GPU 唯一安全并发写，但同地址串行，所以先 smem 局部 reduce 减少 global atomic。scan 和 sort 不手写，用 cub——官方 work-efficient 实现，别造轮子。1M 点 grid 构建约 3ms。

## ❓ 自检

- atomicAdd 同地址会怎样？→ 串行，热点 cell 退化
- 为什么要 sort？→ 不 sort 同 cell 点散落各处 cache 不友好，sort 后连续内存高效

---

# 阶段 7：算法协作 ——jump flooding + kernel fusion + CUDA Graph

## 🎯 本阶段目标

学会用算法层（jump flooding）、算子层（kernel fusion）、调度层（CUDA Graph）的协作优化。

## 📖 故事 1：烽火台传信（jump flooding）

64×64×64 城市格子，每个格子要找最近医院。

**暴力**：每格扫所有医院 → O(V×N) 天文数字。

**Jump Flooding（烽火台）**：

- 初始：只有医院格子知道自己在哪
- 第 1 pass：每格问 26 邻居中**距离 32 格**的，谁有种子？抄来
- 第 2 pass：距离 16 格
- 第 3 pass：距离 8
- ...
- 第 6 pass：距离 1

log2(64)=6 pass 收敛，所有格子找到最近医院。

复杂度：O(V × 26 × log(N)) vs 暴力 O(V × N)。

## 📖 故事 2：流水线合并工序（kernel fusion）

ESDF 每 pass 有"算距离 + 取最小 + 写回"三 kernel。每次读写 global ~400 cycles。

**融合**：一个 kernel 一口气做完，中间结果留寄存器 ~1 cycle，只读写一次 global。

```
不融合：3 kernel × 2 次 global 读写 = 6 次访存
融合：1 kernel × 1 次读写 = 1 次访存
```

## 📖 故事 3：一键播放（CUDA Graph）

固定多 pass 流程，每次启动 kernel 有 ~5us launch 开销。

**Graph 捕获**：`cudaStreamBeginCapture` 把整个流程录成图，之后 `cudaGraphLaunch` 一次提交。省 launch 开销，driver 提前规划调度。

## 🧪 动手实验

```bash
./build/cuda_spatial_accel
# ESDF Benchmark:
# GPU jump flooding + graph: 0.31ms  (64³ 体素, 1M 障碍点)
```

## 🗣️ 面试讲法

> ESDF 用 Jump Flooding 并行构建。暴力 O(V×N) 太贵，Jump Flooding 从障碍点开始多 pass 跳跃传播，跳跃距离减半 log(N) pass 收敛，每 pass 每 cell 查 26 邻居更新最近障碍。融合 kernel fusion 把"算距离+取最小+写回"3 kernel 合一，中间结果寄存器化；最后 CUDA Graph 捕获固定多 pass 流程省 launch 开销。64³ 体素 1M 障碍点在 RTX 3090 Ti 上 0.31ms。

> **迁移**：LLM 推理引擎（vLLM、TensorRT-LLM）都用 graph——固定 attention+MLP 流程一次提交。attention + softmax + MLP 融合也是 kernel fusion 思路。

## ❓ 自检

- jump flooding 比 brute force 复杂度差多少？→ O(V×26×logN) vs O(V×N)，N=障碍数
- kernel fusion 什么情况不该用？→ 寄存器压力过大导致 occupancy 骤降；kernel 间有复用关系

---

# 阶段 8：工程质量 ——occupancy + 数值稳定 + benchmark

## 🎯 本阶段目标

学会工程化的"软实力"：occupancy 调优、数值稳定性、自动化 benchmark。

## 📖 故事 1：工厂排班（occupancy）

一个车间（SM）可同时容纳多个班组（block）。组越多，一个组等数据时另一个组继续算，延迟被掩盖。

**Occupancy = 活跃 warp 数 / SM 最大 warp 数**

影响因子：

- 寄存器用量：每线程寄存器多 → 一个 SM 塞的线程少
- shared memory 用量：同理
- block size

```cpp
// 限制寄存器用量
__launch_bounds__(256, 4)  // 256 线程/block，至少 4 block/SM
__global__ void myKernel(...) { ... }

// 验证
int maxBlocks;
cudaOccupancyMaxActiveBlocksPerMultiprocessor(&maxBlocks, myKernel, 256, 0);
```

**关键认知**：occupancy 不是越高越好。低 occupancy + 更多寄存器 + 循环展开有时更快。要 profile 实测。

## 📖 故事 2：零钱罐（Kahan summation）

float 有效位 7 位。1e10 + 1e-5 = 1e10，小数被吞。100 万次累加丢 1000 块。

**Kahan 补偿**：用补偿变量 c 记住被吞的小数，攒够了补一次。

```cpp
float sum = 0, c = 0;
for (int i = 0; i < N; ++i) {
    float y = val[i] - c;
    float t = sum + y;
    c = (t - sum) - y;
    sum = t;
}
// 1M 累加：朴素误差 1e-3，Kahan 误差 1e-7
```

## 📖 故事 3：精确计时（CUDA Event）

CPU 端 gettimeofday 不能用——kernel 异步，CPU 计时只含 launch 开销不含 GPU 执行时间。

用 CUDA Event 在 GPU 端打时间戳：

```cpp
cudaEvent_t start, stop;
cudaEventCreate(&start); cudaEventCreate(&stop);
cudaEventRecord(start, stream);
myKernel<<<...>>>(...);
cudaEventRecord(stop, stream);
cudaEventSynchronize(stop);
float ms;
cudaEventElapsedTime(&ms, start, stop);  // 精确到 us
```

## 🗣️ 面试讲法

> occupancy = 活跃 warp / 最大 warp。寄存器用太多 occupancy 低，延迟无法掩盖。我用 `__launch_bounds__` 限制，用 `cudaOccupancyMaxActiveBlocksPerMultiprocessor` 验证。但 occupancy 不是越高越好——低 occupancy + 更多寄存器 + 循环展开有时更快，要 ncu 实测。数值稳定用 Kahan summation + isfinite 检查。计时用 CUDA Event，不是 CPU gettimeofday。

## ❓ 自检

- occupancy 100% 一定最快吗？→ 不一定，要 ncu 实测
- 为什么用 CUDA Event 不用 CPU 计时？→ kernel 异步，CPU 计时不准

---

# 阶段 9：面试模拟 ——能讲、能答、能画

## 🎯 本阶段目标

把前 8 阶段串成完整的项目故事，应对面试官追问。

## 🗣️ 项目一句话介绍

> "我做了个 GPU 加速 3D 点云 KNN + ESDF 工具，1M 点云 1K 查询，从 CPU 1043ms 一步步优化到 4.72ms，**221 倍加速**；64³ 体素 ESDF 构建 0.31ms。覆盖 CUDA 工程所有常见考点：内存布局、合并访存、shared memory tiling、warp shuffle、atomic、cub sort/scan、kernel fusion、CUDA Graph、数值稳定性。每个优化点都有 RTX 3090 Ti 实测数据。"

## 🗣️ 完整讲解流程（背下来，按顺序讲）

**1. 问题**：激光雷达 100 万点 KNN，CPU 1043ms，要 30FPS（33ms）

**2. 第一步 GPU baseline**：AoS baseline，89ms，11.7 倍加速

- 但 ncu 看 DRAM 带宽只有 30%，瓶颈在访存

**3. SoA + 合并访存**：59ms，17.7 倍加速

- 根因：warp 32 线程访问 AoS 地址间隔 12B 非合并，SoA 连续 128B 一次事务

**4. Shared memory tiling + Warp shuffle**：4.72ms，221 倍加速

- block 协作拷 tile 到 smem 复用，warp shuffle 寄存器级 5 步归约省 smem 写回+atomic

**5. Uniform grid**：1M 点构建 ~3ms

- atomic + cub scan + cub sort

**6. ESDF jump flooding + kernel fusion + CUDA Graph**：0.31ms

- log(N) pass 并行，kernel fusion 省访存，graph 省 launch

## 🗣️ 6 个高频追问应对

**Q1：为什么不用 nanoflann/PCL？**

> 我做这个是为了吃透每个优化点的"为什么"。现成库快但面试要的是"为什么这么实现"。自己实现一遍才知道 AoS→SoA 带宽差异、smem tiling 复用率、warp shuffle 省多少。这是工程能力训练。

**Q2：怎么迁移到 LLM 推理？**

> 全部可迁移：
>
> - pinned + async → LLM 权重加载
> - SoA + coalesced → KV Cache 访问
> - smem tiling → attention Q/K/V tile
> - warp shuffle → softmax 归一化
> - kernel fusion → attention + MLP 融合
> - CUDA Graph → 固定推理流程
>   我的 CUDA 工程能力可迁移到大模型部署。

**Q3：你最大的踩坑？**

> 早期版本有 bank conflict，性能比预期慢 5 倍。用 ncu profile 才发现 smem 访问模式撞 bank。padding 后快 5 倍。**性能问题不能猜，必须用 profiler 定位**。

**Q4：occupancy 怎么调优？**

> occupancy = 活跃 warp / 最大 warp。寄存器多 occupancy 低延迟无法掩盖。我用 `__launch_bounds__` 限制寄存器用量。但 occupancy 不是越高越好——低 occupancy + 更多寄存器 + 循环展开有时更快，要 profile 实测。

**Q5：什么时候 GPU 反而比 CPU 慢？**

> 数据量小（<10K）launch 开销大于收益。内存带宽受限的串行算法。分支密集 warp divergence 严重的算法。

**Q6：W4A8 量化和 CUDA 优化有什么关系？**

> W4A8 是权重量化 4bit、激活 8bit。CUDA 上 INT4/INT8 算子吞吐是 FP16 的 2-4 倍。我用 CUDA 写过 INT8 的 KNN 距离计算，访存减半 + 计算提速 2 倍。量化本质也是"用更少位宽省访存"，和 SoA 合并访存是同源思想——**让数据布局匹配硬件**。

## 🗣️ 万能答题框架

任何 CUDA 优化问题，按这个框架答：

```
1. 问题是什么 → "瓶颈是 [global 带宽 / launch 开销 / 精度 / ...]"
2. 硬件根因 → "因为 GPU [global 400 cycles / 128B 事务 / warp 32 锁步 / ...]"
3. 我的方案 → "用 [pinned / SoA / smem tiling / kernel fusion / ...]"
4. 量化数据 → "从 X ms 降到 Y ms，Z 倍提升"
5. 为什么有效 → "因为 [DMA 直连 / 合并访存 / 复用 N 倍 / 寄存器级操作]"
6. 迁移场景 → "可迁移到 [LLM 推理 / attention / 矩阵乘法]"
```

**面试官最看重第 2 步"硬件根因"和第 5 步"为什么有效"**——答出这两步，说明你真懂，不是背的。

---

# 最终交付物清单

学完这份手册，你拥有：

| 文档                        | 用途                               |
| --------------------------- | ---------------------------------- |
| `mentor_guide.md`（本文） | 导师带教：从零到面试的完整学习路径 |
| `teaching_mastery.md`     | 知识点精讲：16 个优化点的硬件根因  |
| `interview_talk.md`       | 面试讲稿：10 个优化点的五段式问答  |
| `design.md`               | 项目设计规格                       |
| `plan.md`                 | 实施计划：每任务的代码 + 讲法      |
| `README.md`               | 项目说明：结构 + 编译 + 知识点覆盖 |

**学习顺序建议**：

1. 读 `mentor_guide.md` 建立全局认知（本文）
2. 阶段 0-8 逐阶段读 + 自检 + 查 `teaching_mastery.md` 深挖
3. 阶段 9 模拟面试，用 `interview_talk.md` 反复练
4. 编译跑项目，看真实数据，对照讲稿
5. 找朋友模拟面试，按"完整讲解流程"讲一遍

**最后一句**：你不是在背书，你是在讲故事——一个"从 2000ms 到 5ms"的工程故事。这个故事讲清楚，面试官就知道你懂性能优化。
