# 代码实例导览｜每阶段对应哪个文件、关键代码段讲解

> **用途**：配合 `mentor_guide.md` 使用。每学完一个阶段，来这里找对应代码文件，看关键代码段的逐行讲解。
> **方法**：先读 mentor_guide 建立概念 → 打开本文对应文件 → 对照代码段看"为什么这么写" → 跑项目看真实数据。

---

# 前置补充：CUDA Stream + cudaMemcpyAsync + Pipeline

这三个概念在阶段 3 代码里出现，但很多初学者没搞懂，单独讲清楚再进。

## 📖 故事：快递公司（CUDA Stream）

**场景**：你的公司要给客户发货。流水线分两段：①仓库装车（数据搬运）②客户卸货加工（kernel 执行）。

**方案 A：单 stream（默认 stream 0）**

```
卡车1 装→→→→→→→→→→→→→ 客户1 卸货加工
                              ↑加工完才能发车2
卡车2      等.....            装→→→→→→→→ 客户2 卸货
```

CPU 提交"卡车1装车→客户1加工→卡车2装车→客户2加工"。
GPU 看到单 stream，严格按序：必须等客户1加工完，才开始卡车2装车。
**装车工和加工工互相等**——任一时刻只有一个在干活。

**方案 B：双 stream（stream A 搬运，stream B 计算）**

```
stream A（卡车）：  卡车1 装→卡车2 装→卡车3 装→...
stream B（加工）：         →客户1 加工→客户2 加工→...
                                  ↑可以并行
```

CPU 把装车任务放 stream A，加工任务放 stream B。
GPU 看到 stream A 的装车任务，让 DMA 引擎干活；
同时 stream B 的加工任务，让 SM 计算单元干活。
**装车工和加工工同时工作**——吞吐翻倍。

## 🎯 CUDA Stream 到底是什么

**CUDA Stream** = GPU 上的**任务队列**。按提交顺序执行。

```
stream A: [kernel1]→[kernel2]→[memcpy3]→...
stream B: [memcpy1]→[kernel3]→[memcpy2]→...
```

**关键规则**：

1. **同一 stream 内任务按序串行**：stream A 的 kernel2 必须等 kernel1 完成
2. **不同 stream 间可以并行**：stream A 的 kernel 和 stream B 的 memcpy 可以同时跑
3. **GPU 有多个独立引擎**：Copy Engine（搬运）+ Compute Engine（计算）可以真正并行

## 📖 `cudaMemcpyAsync` 详解

```cpp
cudaMemcpyAsync(
    dst,                    // 目标地址（device 或 host）
    src,                    // 源地址
    size,                   // 字节数
    cudaMemcpyHostToDevice, // 方向
    stream                  // 提交到哪个 stream
);
```

**和同步版 `cudaMemcpy` 的区别**：

| 版本                | 返回时机         | CPU 是否阻塞           |
| ------------------- | ---------------- | ---------------------- |
| `cudaMemcpy`      | 等拷贝完成才返回 | 阻塞，CPU 干等         |
| `cudaMemcpyAsync` | 提交后立刻返回   | 不阻塞，CPU 可以干别的 |

**坑**：`cudaMemcpyAsync` 不阻塞，但 host 端的 src 缓冲不能立刻释放——DMA 可能还没读完。必须等 stream 内事件同步。

## 📖 什么是 Pipeline

**Pipeline** = 流水线，让"搬运"和"计算"重叠起来。

**不用 pipeline（同步搬运）**：

```
时间轴：  ----拷贝A----  ----kernel A----  ----拷贝B----  ----kernel B----
总时间 =  拷贝A + kernel A + 拷贝B + kernel B
```

CPU 提交后，DMA 搬 A，搬完 SM 算 A，算完 DMA 搬 B...任一时刻只有一件事在干。

**用 pipeline（双 stream + async）**：

```
stream A（拷贝）： ----拷贝A----  ----拷贝B----
stream B（kernel）：     ----kernel A----  ----kernel B----
                              ↑重叠了
总时间 ≈ max(拷贝A, kernel A) + max(拷贝B, kernel B)
```

**CPU 提交代码**：

```cpp
// 第 1 批数据搬运 + 第 2 批搬运并行起来
cudaMemcpyAsync(dBufA, hBufA, size, cudaMemcpyHostToDevice, copyStream);
kernelA<<<grid, block, 0, computeStream>>>(dBufA);

// 不等 kernel A，立刻提交第 2 批拷贝
// DMA 可以在 SM 算 A 时同时搬 B
cudaMemcpyAsync(dBufB, hBufB, size, cudaMemcpyHostToDevice, copyStream);
kernelB<<<grid, block, 0, computeStream>>>(dBufB);
```

**注意**：本项目 `pointcloud.cpp` 里只用了单 stream，所以搬运和计算是串行的。真正的 pipeline 需要双 stream + ping-pong buffer（双缓冲）：

```cpp
// 完整 pipeline 示例
cudaStream_t copyStream, computeStream;
cudaStreamCreate(&copyStream);
cudaStreamCreate(&computeStream);

float *dBuf[2];  // ping-pong 双缓冲
cudaMalloc(&dBuf[0], size);
cudaMalloc(&dBuf[1], size);

for (int batch = 0; batch < N; ++batch) {
    int buf = batch % 2;  // 当前用哪个缓冲
    // 搬下一批数据（copyStream，DMA 干活）
    cudaMemcpyAsync(dBuf[buf], hBuf[buf], size, cudaMemcpyHostToDevice, copyStream);
    // 算上一批数据（computeStream，SM 干活）
    // 让 computeStream 等 copyStream 把当前 buf 搬完
    cudaStreamWaitEvent(computeStream, doneEvent[buf], 0);
    kernel<<<grid, block, 0, computeStream>>>(dBuf[buf]);
    cudaEventRecord(doneEvent[buf], computeStream);
}
```

## 🗣️ 面试讲法

> **CUDA Stream**：是 GPU 的任务队列，同 stream 内按序串行，不同 stream 可并行。GPU 有 Copy Engine 和 Compute Engine 两个独立硬件，双 stream 可以让搬运和计算真正并行——这就是 pipeline。
>
> **`cudaMemcpyAsync`**：异步拷贝，提交后立刻返回。和同步 `cudaMemcpy` 区别在于 CPU 不阻塞，可以继续提交后续任务。但 host 端 src 不能立刻释放，要等 stream 同步。
>
> **Pipeline**：让搬运和计算重叠。用双 stream + ping-pong 双缓冲，stream A 搬下一批数据时，stream B 在算上一批数据。理论吞吐翻倍，实际受 PCIe 带宽和 SM 算力限制。
>
> **迁移场景**：LLM 推理引擎的 KV Cache 加载用 pipeline——DMA 搬下一层的 KV Cache，同时 SM 算当前层的 attention。vLLM、TensorRT-LLM 都用这个思路。

## ❓ 自检

- 同一 stream 内的两个 kernel 能并行吗？→ 不能，必须按序
- 不同 stream 间的 kernel 能并行吗？→ 可以，但要硬件有对应空闲引擎
- `cudaMemcpyAsync` 后 CPU 立刻释放 src 安全吗？→ 不安全，DMA 可能没读完
- pipeline 实际加速多少？→ 理论 2 倍，实际受限于"搬运慢还是计算慢"中的短板

---

## 代码文件 → 学习阶段映射表

| 文件                                                                                                                  | 阶段 | 知识点                           | 关键代码段                        |
| --------------------------------------------------------------------------------------------------------------------- | ---- | -------------------------------- | --------------------------------- |
| [pointcloud.h](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/pointcloud.h)                 | 3    | AoS/SoA 双布局定义               | `PointAoS` vs `PointCloudSoA` |
| [pointcloud.cpp](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/pointcloud.cpp)             | 3    | pinned memory + async copy       | `copyToDeviceAsync()`           |
| [baseline_cpu.cpp](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/baseline_cpu.cpp)         | 2    | CPU 基线（对照起点）             | `cpuBruteKnn()`                 |
| [gpu_baseline_aos.cu](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/gpu_baseline_aos.cu)   | 1+4  | 第一个 kernel + AoS 痛点         | `knnAosBaselineKernel`          |
| [gpu_optimized_soa.cu](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/gpu_optimized_soa.cu) | 4    | SoA + 合并访存 +`__restrict__` | `knnSoaKernel`                  |
| [knn_search_kernel.cu](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/knn_search_kernel.cu) | 5    | smem tiling + warp shuffle       | `knnSmemTilingKernel`           |
| [uniform_grid.cu](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/uniform_grid.cu)           | 6    | atomic + cub scan/sort           | `buildUniformGrid()`            |
| [esdf_jump_flood.cu](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/esdf_jump_flood.cu)     | 7    | jump flooding + fusion + graph   | `runJumpFloodEsdf()`            |
| [benchmark.cpp](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/benchmark.cpp)               | 8    | CUDA Event 精确计时              | `Benchmark::timeKernel()`       |
| [main.cpp](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/main.cpp)                         | 9    | 集成 + 验证 + 输出对比           | `main()`                        |

---

# 阶段 1 对应：gpu_baseline_aos.cu ——你的第一个 kernel

## 📌 文件定位

这个文件是"GPU hello world"——把 CPU 暴力循环原封不动搬到 GPU，证明并行能加速，但布局不对所以慢。

## 🔍 关键代码段 1：`__global__` 标记 + 线程索引

```cpp
__global__ void knnAosBaselineKernel(
    const PointAoS* __restrict__ cloud,
    size_t cloudN,
    ...
) {
    int q = blockIdx.x * blockDim.x + threadIdx.x;  // 我是第几个线程
    if (q >= (int)queryN) return;                    // 越界保护
```

**逐字讲解**：

- `__global__`：告诉编译器"这函数在 GPU 上跑、从 CPU 调用"。这是 CUDA 的"hello world 关键字"。
- `blockIdx.x * blockDim.x + threadIdx.x`：CUDA 编程的万能公式。
  - `blockIdx.x`：我是第几个 block
  - `blockDim.x`：每 block 多少线程
  - `threadIdx.x`：我在 block 内是第几个
  - 全局索引 = block 编号 × 每 block 线程数 + block 内编号
- `if (q >= queryN) return`：最后一个 block 可能没填满，越界必须保护。

**为什么必须这么写**：GPU 线程不知道自己处理哪个查询点，必须自己算索引。CPU `for(i=0..N)` 是顺序的，GPU 是"每个线程一个 i"。

## 🔍 关键代码段 2：朴素暴力循环

```cpp
    PointAoS qp = queries[q];     // 把查询点装进寄存器
    float bestDist = 1e30f;
    for (size_t i = 0; i < cloudN; ++i) {
        float dx = cloud[i].x - qp.x;   // ← 痛点：cloud[i].x 地址间隔 12B
        float dy = cloud[i].y - qp.y;
        float dz = cloud[i].z - qp.z;
```

**痛点根因**：`PointAoS` 是 `{x, y, z}` 三个 float = 12 字节。warp 内 32 线程同时访问 `cloud[0..31].x`：

- 线程 0 访问地址 0
- 线程 1 访问地址 12
- 线程 2 访问地址 24
- ...

GPU 一次处理 128B 事务，但 32×4B=128B 跨度是 32×12=384B，**3 次事务**。带宽利用率 33%。这就是 89ms 的来源。

## 🔍 关键代码段 3：launch 语法

```cpp
void runKnnAosBaseline(...) {
    int threads = 256;
    int blocks = ((int)queryN + threads - 1) / threads;
    knnAosBaselineKernel<<<blocks, threads, 0, stream>>>(...);
}
```

**逐字讲解**：

- `<<<blocks, threads, 0, stream>>>`：CUDA launch 语法
  - `blocks`：开多少 block
  - `threads`：每 block 多少线程（必须是 32 倍数，256 是经典选择）
  - `0`：shared memory 大小（这个 kernel 不用）
  - `stream`：提交到哪个 stream（用于 async）
- `(N + 255) / 256`：向上取整，保证所有查询点都被覆盖

---

# 阶段 2 对应：baseline_cpu.cpp ——CPU 基线，对照起点

## 📌 文件定位

这个文件**不是 CUDA**，是 CPU 单线程暴力 KNN。它存在的意义：提供 1043ms 这个基线，证明"为什么必须用 GPU"。

## 🔍 关键代码段

```cpp
std::vector<int> cpuBruteKnn(
    const std::vector<PointAoS>& cloud,
    const std::vector<PointAoS>& queries
) {
    std::vector<int> result(queries.size(), -1);
    for (size_t q = 0; q < queries.size(); ++q) {     // 1K 查询
        float bestDist = 1e30f;
        for (size_t i = 0; i < cloud.size(); ++i) {   // 1M 点云
            float dx = cloud[i].x - queries[q].x;
            ...
        }
    }
}
```

**为什么 1043ms**：1K × 1M = 10 亿次距离计算，CPU 单核 4GHz + 10ns/次 = 10 秒理论值，实际 CPU 有 SIMD + cache 优化到 1043ms。

**对照价值**：跑完后看 `Speed 1.0x`，作为基准。所有 GPU 优化都和这个数比。

---

# 阶段 3 对应：pointcloud.h + pointcloud.cpp ——数据搬运优化

## 📌 文件定位

定义点云数据结构 + 实现 pinned memory + async copy。

## 🔍 关键代码段 1：AoS vs SoA 双布局（pointcloud.h）

```cpp
// AoS：每个点一个结构体（cache 不友好，作为对照基线）
struct PointAoS {
    float x, y, z;
};

// SoA：x/y/z 分别连续存储（cache 友好，生产用）
struct PointCloudSoA {
    float *xs = nullptr;   // device 指针
    float *ys = nullptr;
    float *zs = nullptr;
    size_t n = 0;
};
```

**讲解**：这两个结构体定义就是阶段 4 的核心概念——内存布局。AoS 把 xyz 捆在一起，SoA 把 xyz 分三数组。

**关键细节**：`PointCloudSoA` 里的指针是 **device 指针**（指向 GPU 显存），不能在 CPU 端 deref。这是 CUDA 编程常见坑。

## 🔍 关键代码段 2：pinned memory + async copy（pointcloud.cpp）

```cpp
void PointCloudGenerator::copyToDeviceAsync(...) {
    // 临时分配 pinned host 缓冲
    float *hx = nullptr;
    cudaMallocHost(&hx, n * sizeof(float));  // ← pinned 关键
    ...
    // 异步拷贝
    cudaMemcpyAsync(deviceCloud.xs, hx, n * sizeof(float),
                     cudaMemcpyHostToDevice, stream);  // ← async 关键
    cudaStreamSynchronize(stream);  // 等拷贝完成才释放 pinned
    cudaFreeHost(hx);
}
```

**逐行讲解**：

- `cudaMallocHost`：分配 pinned 内存。普通 malloc 是 pageable 的，GPU DMA 搬运要中转拷贝一次；pinned 让物理页固定，DMA 直连，省一次拷贝。
- `cudaMemcpyAsync`：异步拷贝。CPU 立刻返回，GPU 在指定 stream 内排队执行。
- `cudaStreamSynchronize`：必须等拷贝完才能释放 pinned 缓冲，否则 DMA 会读到已释放内存。
- `cudaFreeHost`：配对的释放，不能用普通 free。

**工程心法**：实际工程中 pinned 缓冲会池化复用，避免反复 alloc/free。这里简化教学用。

---

# 阶段 4 对应：gpu_optimized_soa.cu ——合并访存优化

## 📌 文件定位

这个文件是 AoS baseline 的"对症下药"——把布局改 SoA，带宽从 33% 拉到 60%+，89ms → 59ms。

## 🔍 关键代码段

```cpp
__global__ void knnSoaKernel(
    const float* __restrict__ cxs,   // x 连续
    const float* __restrict__ cys,   // y 连续
    const float* __restrict__ czs,   // z 连续
    ...
) {
    int q = blockIdx.x * blockDim.x + threadIdx.x;
    ...
    for (size_t i = 0; i < cloudN; ++i) {
        float dx = cxs[i] - qx;   // ← warp 内线程访问同一 cxs，地址连续
        float dy = cys[i] - qy;
        ...
    }
}
```

**对比 AoS baseline 的关键改动**：

1. 函数参数从 `PointAoS* cloud` 改成 `float* cxs, cys, czs` ——三个独立连续数组
2. 访问从 `cloud[i].x` 改成 `cxs[i]` ——warp 内 32 线程访问连续 128B

**为什么 59ms（vs AoS 89ms）**：

- warp 32 线程同时访问 `cxs[0..31]`，地址 `0, 4, 8, ..., 124` → 连续 128B → **1 次事务**
- AoS 同样访问 → 跨度 384B → 3 次事务
- 带宽利用率从 33% 拉到 60%+，时间降 33%

### 深入：Cache Line（缓存行）——批发市场的最小装箱单位

**📖 故事**：你去批发市场买苹果。老板说："**最少拿一整箱（24 个）**，不拆卖。"你只想买 3 个苹果，但必须拿 1 箱 24 个。剩下 21 个你拿走或扔掉，反正老板只按箱卖。

**GPU 也是这样**：global memory（显存）到 cache 的最小搬运单位是 **128 字节一箱**（一个 cache line），不拆卖。

当 GPU 要读 1 个 float（4 字节）时，**实际上会把它周围 128 字节一起搬进 cache**。这 128 字节 = 32 个 float = 一个 cache line。

**为什么有 cache line**：硬件原因——DRAM 访问有固定开销（寻址、激活行、突发传输）。一次读 4B 和一次读 128B 耗时几乎一样。**搬运"一箱"比搬运"一个"效率高 32 倍**。

#### AoS 在 cache line 下的表现

```
内存：[x0 y0 z0 x1 y1 z1 x2 y2 z2 ...]  每点 12B
                ↑
              cache line 边界（128B ≈ 10.67 个点）

线程 0 要读 cloud[0].x：
  → GPU 搬一整 cache line（128B）到 L2
  → 这 128B 里包含 cloud[0..10] 的部分 xyz
  → cloud[0].x 拿到了，但 y0 z0 x1 y1 z1... 也被白搬进来了

线程 1 要读 cloud[1].x：   ← 已经在 cache 里，命中！
线程 10 要读 cloud[10].x：  ← 还在 cache 里，命中！
线程 11 要读 cloud[11].x：  ← 不在 cache，又要搬一个新 cache line
```

**AoS 的局部性其实不差**——同一 cache line 内的 10 个点都受益。但问题是：warp 32 线程要读 cloud[0..31].x，跨度 384B，要 3 个 cache line。

#### SoA 在 cache line 下的表现

```
xs 数组：[x0 x1 x2 ... x31 | x32 ...]
                          ↑
                      cache line 边界（128B = 32 个 float）

线程 0 读 xs[0]：
  → GPU 搬一 cache line（128B）到 L2
  → 这 128B 包含 xs[0..31] 全部 32 个 x

线程 1 读 xs[1]：     ← 命中
线程 31 读 xs[31]：   ← 命中
```

**SoA 一个 cache line 就喂饱 32 线程**。因为 32 个 float 刚好 128B，正好一个 cache line。

#### 关键洞察

**cache line 是 GPU 优化的物理基础**。所有"合并访存"概念本质都是：
- **让 warp 32 线程访问的数据落在同一 cache line** → 1 次事务
- **让访问跨多个 cache line** → 多次事务，带宽浪费

SoA 天然让"32 个 x"连续在 128B 内 = 1 个 cache line = 1 次事务。这是物理上的最优解。

### 深入：Prefetch（预取）——猜你要买啥，提前装箱

**📖 故事**：聪明的批发商老板发现你每周都买苹果。他学会**在你下周来之前，提前把下一箱苹果从冷库搬到前台**。你到的时候苹果已经在柜台，不用等冷库取货。

这就是 prefetch——**在你显式请求之前，硬件预测你要访问的内存，提前搬进 cache**。

#### GPU 的 prefetch 机制

**1. 顺序访问预取（streaming prefetch）**

```
线程 0 读 xs[0]    →  GPU 搬 cache line 0（含 xs[0..31]）
                     同时预测"你接下来会读 xs[32..63]"
                     → 提前搬 cache line 1
线程 32 读 xs[32]  →  已经在 cache，命中！
```

GPU 的内存控制器观察到"warp 顺序读 xs[i]"，**自动预取后续 cache line**。SoA 的连续访问让 prefetch **预测准**——下一个 cache line 一定有用。

**2. AoS 的 prefetch 失效**

```
线程 0 读 cloud[0].x   → GPU 预取 cloud[0..10] 这一 cache line
线程 32 读 cloud[32].x → 跨了 cache line 边界，预取没命中
                         → GPU 要重新发请求，预取失效
```

AoS 的访问跨多个 cache line，**prefetch 预测不准**。预取的下一 cache line 可能是"另一组 xyz"，但你要的是"另一个 x"。

#### 为什么预取对 SoA 更有效

**SoA 顺序访问**：xs[0], xs[1], xs[2], ... → 完美顺序，prefetch 命中率高
**AoS 跨步访问**：cloud[0].x, cloud[1].x（间隔 12B）→ 跨步访问，prefetch 命中率低

GPU 的 L2 cache 和内存控制器**对顺序访问做激进 prefetch**。SoA 布局正好让数据"顺序可预取"。

### 深入：L2 Cache 全局复用

**📖 故事**：仓库共享货架。L2 cache 是 GPU 上所有 SM 共享的"中间层货架"。global memory 是远在天边的大仓。

```
Global Memory（大仓，几 GB）   ← 延迟 400 cycles
    ↓
L2 Cache（共享货架，几 MB）   ← 延迟 200 cycles
    ↓
L1/Shared（SM 私有货架，KB 级）  ← 延迟 20-30 cycles
```

如果多个 SM 都在读同一份点云数据：
- 第 1 个 SM 读 xs[0..31] → 从 global 搬到 L2
- 第 2 个 SM 读 xs[0..31] → **L2 已经有了**，直接命中，省 400 cycles

**SoA 让 L2 命中率更高**：因为数据连续 128B，多个 SM 读相邻区域时 cache line 可共享。AoS 散落访问导致 cache line 利用率低，L2 也跟着浪费。

### 完整延迟表（背下来）

```
寄存器 Register        ~1 cycle      每线程私有
Shared Memory         ~20 cycles    SM 内共享
L1 Cache              ~30 cycles    SM 内自动
L2 Cache              ~200 cycles   全 GPU 共享
Global Memory         ~400-800      显存，最远
```

**所有 CUDA 优化的本质**：让数据尽量留在靠左边的层。

### 面试讲法

> GPU 内存访问有 cache line 粒度，128B 一行。当 warp 32 线程同时读 1 个 float 时，GPU 实际上搬一整 cache line（32 float）到 L2。SoA 让 32 个 x 连续 128B，刚好 1 个 cache line，32 线程全命中。AoS 跨度 384B，要 3 个 cache line。
>
> 此外 GPU 内存控制器对顺序访问做 prefetch 预取。SoA 的连续访问让预取命中率高，下一 cache line 一定有用。AoS 跨步访问让 prefetch 失效，命中率低。
>
> **本质都是让数据布局匹配硬件访问粒度**——cache line 128B + 顺序访问预取，这两个硬件事实决定了 SoA 比 AoS 快。

> **迁移**：LLM 推理时 KV Cache 用 SoA 布局，让 attention 访问 K 时连续，prefetch 命中率高。FlashAttention 的 tile 也是按 cache line 对齐设计的。

### ❓ 自检

- cache line 多大？→ 128 字节（32 个 float）
- 为什么 GPU 不"拆卖"4 字节？→ DRAM 寻址开销固定，搬 4B 和搬 128B 耗时几乎一样
- SoA 为什么 prefetch 更准？→ 顺序访问，下一 cache line 必有用
- AoS 同一 cache line 内的 10 个点命中，为什么还慢？→ warp 要 32 个，跨 3 个 cache line

## 🔍 `__restrict__` 的作用

```cpp
const float* __restrict__ cxs
```

**讲解**：告诉编译器"这个指针指向的内存没有别名"——即没有其他指针也指向同一块。编译器可以激进优化，比如把 load 提前到 store 前。

不加 `__restrict__`：编译器保守，担心 `cxs[i]` 和 `cys[i]` 是同一地址，必须严格按顺序。
加了：编译器知道三个指针无重叠，可以重排指令、向量化。

---

# 阶段 5 对应：knn_search_kernel.cu ——smem tiling + warp shuffle

## 📌 文件定位

这是整个项目的**性能高潮**——把 59ms 优化到 4.72ms 的关键文件。两个技术叠加：shared memory tiling 复用数据 + warp shuffle 寄存器级归约。

## 🔍 关键代码段 1：动态 shared memory 声明

```cpp
extern __shared__ float smem[];
float* tileX = smem;
float* tileY = smem + blockDim.x;
float* tileZ = smem + 2 * blockDim.x;
float* warpBestDist = smem + 3 * blockDim.x;
int* warpBestIdx = (int*)(smem + 3 * blockDim.x + blockDim.x / 32);
```

**逐行讲解**：

- `extern __shared__ float smem[]`：动态分配 shared memory，大小在 launch 时指定
- 把一段连续 smem 切成多个区：3 个 tile（x/y/z）+ 2 个归约区（dist/idx）
- `blockDim.x = 256`，所以 tileX/y/z 各 256 floats = 1KB，归约 8 个 warp 各一个值

**为什么用动态 smem 不用静态**：静态 smem 大小固定在编译期，动态可以在 launch 时灵活指定。本项目 tile + 归约区大小不一样，动态更灵活。

## 🔍 关键代码段 2：协作拷贝 tile

```cpp
for (size_t tileStart = 0; tileStart < cloudN; tileStart += blockDim.x) {
    size_t gi = tileStart + tid;
    if (gi < cloudN) {
        tileX[tid] = cxs[gi];   // 线程 t 拷 tile 第 t 个点
        tileY[tid] = cys[gi];
        tileZ[tid] = czs[gi];
    }
    __syncthreads();
    ...
```

**逐行讲解**：

- `for (tileStart = 0; tileStart < cloudN; tileStart += 256)`：每轮处理 256 个点
- 256 个线程**协作**，每线程从 global 拷 1 个点到 smem。1 次 global 读，256 个线程复用，复用率 = 256。
- `__syncthreads()`：block 内同步，确保所有线程拷完才能进下一轮。少了这行会读到未初始化的 smem。

**为什么快**：global 400 cycles，smem 20 cycles，差 20 倍。复用率 256 倍 × 20 倍延迟差 = 理论加速 5120 倍（实际不到，因为不是每点都被复用）。

## 🔍 关键代码段 3：每个线程只算自己负责的那一个点

```cpp
    if (gi < cloudN) {
        float dx = tileX[tid] - qx;   // 每线程算 tile 第 tid 个点
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
```

**关键点**：不是每个线程都扫整个 tile（那是 256 倍重复工作）。每线程只算 tile 中第 `tid` 个点，256 线程并行处理 256 点。

## 🔍 关键代码段 4：第 1 级 warp shuffle 归约

```cpp
// 第 1 级归约：warp shuffle 在 warp 内找最小（5 步 log2(32)）
for (int offset = 16; offset > 0; offset >>= 1) {
    float otherDist = __shfl_xor_sync(0xffffffff, bestDist, offset);
    int otherIdx = __shfl_xor_sync(0xffffffff, bestIdx, offset);
    if (otherDist < bestDist) {
        bestDist = otherDist;
        bestIdx = otherIdx;
    }
}
```

**逐行讲解**：

- `__shfl_xor_sync(mask, val, offset)`：warp 内线程"和距离 offset 的线程交换 val"
- `mask = 0xffffffff`：所有 32 线程参与
- `offset = 16`：第 1 轮和距离 16 的线程比 → 32→16 不同值
- `offset = 8`：第 2 轮 → 16→8
- `offset = 4/2/1`：继续减半
- 5 步后 warp 内所有人 `bestDist` 都是最小值

**为什么不经过 smem**：寄存器交换 ~1 cycle，smem 读写 ~20 cycles + atomic 串行。shuffle 是最快路径。

**关键细节**：归约时要同时带 `bestIdx`，否则最后只知距离不知索引。

## 🔍 关键代码段 5：第 2 级跨 warp 归约

```cpp
if (lane == 0) {
    warpBestDist[warpId] = bestDist;   // 每 warp 写自己的结果到 smem
    warpBestIdx[warpId] = bestIdx;
}
__syncthreads();

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
```

**讲解**：256 线程 = 8 个 warp。第 1 级 shuffle 只在 warp 内归约，得到 8 个候选。第 2 级把这 8 个候选再归约一次：

- 8 个 warp 的 lane 0 写结果到 smem
- warp 0 从 smem 读 8 个值
- warp 0 再 shuffle 归约

**为什么不能直接 256 线程一起 shuffle**：`__shfl_xor_sync` 只在 warp 内（32 线程）有效。256 线程跨 warp 必须用 smem 中转。

## 🔍 关键代码段 6：launch 时指定 smem 大小

```cpp
void runKnnSmemTiling(...) {
    int threads = 256;
    int blocks = (int)queries.n;
    size_t smemBytes = 3 * threads * sizeof(float)
                     + (threads / 32) * sizeof(float)
                     + (threads / 32) * sizeof(int);
    cudaFuncSetAttribute(knnSmemTilingKernel,
        cudaFuncAttributeMaxDynamicSharedMemorySize, smemBytes);
    knnSmemTilingKernel<<<blocks, threads, smemBytes, stream>>>(...);
}
```

**讲解**：

- 第 3 个 launch 参数 `smemBytes`：指定动态 smem 大小
- `cudaFuncSetAttribute`：默认 smem 上限 48KB，超过要显式申请
- `blocks = queries.n`：一个 block 处理一个查询点（1K block × 256 线程 = 256K 线程）

---

# 阶段 6 对应：uniform_grid.cu ——atomic + cub 原语

## 📌 文件定位

构建空间索引：1M 点 → 每 cell 多少点 → cell 起始位置 → 排序后连续存储。用 atomic + cub scan + cub sort 三步。

## 🔍 关键代码段 1：atomic 计数

```cpp
__global__ void countCellsKernel(...) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= (int)n) return;
    int cellId = computeCellIdDevice(xs[i], ys[i], zs[i], ...);
    if (cellId >= 0) atomicAdd(&cellCounts[cellId], 1);   // ← 并发安全写
}
```

**讲解**：

- 1M 点并行，每点算自己属于哪个 cell，然后 `atomicAdd` 给该 cell 计数 +1
- `atomicAdd` 是 GPU 唯一安全的并发写方式——硬件保证"读-改-写"不可打断
- **代价**：同地址的 atomic 是串行的。100 点撞同一 cell → 串行 100 次

**工程优化**（本项目没做但要知道）：先 smem 局部 reduce，再 atomic 写 global，减少 global atomic 次数。

## 🔍 关键代码段 2：cub exclusive sum

```cpp
// cub exclusive sum 算 cellStarts
size_t tempBytes = 0;
cub::DeviceScan::ExclusiveSum(nullptr, tempBytes, grid.cellCounts, grid.cellStarts,
                              (int)totalCells, stream);
void* tempBuf = nullptr;
    cudaMalloc(&tempBuf, tempBytes);
cub::DeviceScan::ExclusiveSum(tempBuf, tempBytes, grid.cellCounts, grid.cellStarts,
                              (int)totalCells, stream);
```

**讲解**：

- exclusive sum = 前缀和但不包含自己。例如 `[1,2,3,0]` → `[0,1,3,6]`
- 用途：算每个 cell 在排序后数组中的起始位置
- **两步调用模式**：第一次传 `nullptr` 让 cub 算需要多少临时空间，第二次真正执行
- **为什么用 cub**：work-efficient parallel scan，O(N) work + O(log N) depth，比手写快且正确。**别造轮子**。

## 🔍 关键代码段 3：cub radix sort

```cpp
// cub radix sort 把点按 cellId 排序
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
```

**讲解**：

- `SortPairs(keys_in, keys_out, values_in, values_out)`：按 keys 排序，values 跟着 keys 走
- 这里 keys = cellIds，values = 原始点索引（0..N-1）
- 排序后 `sortedIndices[i]` 表示：排序后第 i 个位置对应原点云第几个点
- **重要坑**：input 和 output 不能是同一缓冲（别名），否则结果未定义。所以分别 `cellIds` 和 `sortedCellIds` 分配。

---

# 阶段 7 对应：esdf_jump_flood.cu ——jump flooding + fusion + graph

## 📌 文件定位

构建 64³ 体素 ESDF 距离场。三大技术叠加：jump flooding 算法 + kernel fusion 省访存 + CUDA Graph 省 launch。

## 🔍 关键代码段 1：seed 编码

```cpp
typedef long long SeedCode;

__device__ inline SeedCode encodeSeed(int x, int y, int z) {
    return ((SeedCode)(x & 0x1FFFFF) << 42) | ((SeedCode)(y & 0x1FFFFF) << 21) | (SeedCode)(z & 0x1FFFFF);
}
```

**讲解**：

- 每 cell 存"最近障碍点坐标"（seed），用 64 位 int 压缩 x/y/z（各 21 位）
- 值 -1（全 1）表示该 cell 还没有 seed
- 编码节省内存 + 访问局部性好

## 🔍 关键代码段 2：jump flooding 一个 pass

```cpp
__global__ void jumpFloodPassKernel(
    SeedCode* seeds, float* dists, int gridSize, float voxelSize, int jump
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
        int nx = x + dx * jump;   // ← 跳跃距离
        ...
    }
}
```

**讲解**：

- 3D grid launch：`blockIdx.x/y/z` + `threadIdx.x/y/z`（这是 3D kernel）
- 每 cell 查 26 邻居（3×3×3 立方体减自己），但邻居在距离 `jump` 处
- 第一 pass `jump = gridSize/2 = 32`，每轮减半到 `jump = 1`
- log2(64) = 6 pass 收敛——所有 cell 都找到最近障碍

**为什么 log(N) pass 够**：第 1 pass 半径 32 的邻居，第 2 pass 半径 16... 最后一 pass 半径 1。所有距离都通过中间邻居"接力"传播。

## 🔍 关键代码段 3：kernel fusion

```cpp
__global__ void jumpFloodPassKernel(...) {
    ...
    // 融合：取距离最小的 seed
    if (d < bestDist) {
        bestDist = d;
        bestSeed = nSeed;
    }
    ...
    seeds[cell] = bestSeed;
    dists[cell] = bestDist;   // ← 算距离 + 取最小 + 写回 融合在一个 kernel
}
```

**讲解**：

- 不融合：要 3 个 kernel——一个算距离，一个取最小，一个写回。每 kernel 读写 global ~400 cycles × 6 pass = 几千 cycles
- 融合：中间结果在寄存器，只读写 global 一次。约 3 倍加速。

## 🔍 关键代码段 4：CUDA Graph 捕获

```cpp
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

cudaGraphLaunch(graphExec, stream);  // 一次提交所有 pass
```

**逐行讲解**：

- `cudaStreamBeginCapture`：开始录制，stream 内的 kernel launch 不立即执行，录到 graph
- `for (jump = 32 → 1)`：6 pass 全部录进去
- `cudaStreamEndCapture`：结束录制，得到 graph
- `cudaGraphInstantiate`：把 graph 编译成可执行实例
- `cudaGraphLaunch`：一次提交执行所有 6 个 pass

**为什么快**：

- 每次 kernel launch 有 ~5us CPU 开销
- 6 pass × 5us = 30us，kernel 本身 0.3ms，launch 开销占 10%
- Graph 一次提交，省 5 次 launch 开销

**关键约束**：Graph 捕获的必须是**固定流程**——参数和拓扑不能变。ESDF 6 pass 跳跃距离固定，完美适合。

---

# 阶段 8 对应：benchmark.cpp ——精确计时

## 📌 文件定位

封装 CUDA Event 计时，避免用 CPU gettimeofday（kernel 异步，CPU 计时不准）。

## 🔍 关键代码段

```cpp
float Benchmark::timeKernel(cudaStream_t stream, const std::function<void()>& kernelLaunch) {
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    cudaEventRecord(start, stream);     // 在 stream 内打开始时间戳
    kernelLaunch();                     // 提交 kernel
    cudaEventRecord(stop, stream);      // 打结束时间戳
    cudaEventSynchronize(stop);         // 等 GPU 执行完

    float ms = 0.0f;
    cudaEventElapsedTime(&ms, start, stop);  // GPU 端精确到 us
    return ms;
}
```

**逐行讲解**：

- `cudaEventRecord(start, stream)`：在 stream 内插入一个"时间戳事件"。GPU 执行到这里时打戳。
- `kernelLaunch()`：提交 kernel（异步，CPU 立刻返回）
- `cudaEventRecord(stop, stream)`：再插一个时间戳
- `cudaEventSynchronize(stop)`：CPU 等 stop 这个事件被 GPU 执行到
- `cudaEventElapsedTime`：算两个事件之间的 GPU 时间，精度 us

**为什么不能用 CPU `gettimeofday`**：kernel 是异步的，CPU 提交完立刻返回，但 GPU 还在算。CPU 端测到的只是 launch 开销，不是 kernel 执行时间。

## 🔍 关键代码段 2：对比表打印

```cpp
void Benchmark::printComparison(const std::vector<BenchResult>& results) {
    float baseMs = results.front().ms;
    for (const auto& r : results) {
        float speedup = (r.ms > 0) ? baseMs / r.ms : 0;
        std::cout << "| " << r.name << " | " << r.ms << " | " << speedup << "x |\n";
    }
}
```

**讲解**：第一个结果是 baseline，后续所有结果都和它比加速比。这就是面试时展示的"1043ms → 4.72ms，221 倍加速"数据来源。

---

# 阶段 9 对应：main.cpp ——集成验证

## 📌 文件定位

集成所有模块，跑出真实性能数据。它是"项目门面"——面试讲完原理后展示的运行结果。

## 🔍 关键代码段（简化版流程）

```cpp
int main() {
    // 1. 生成 1M 点云
    auto cloud = PointCloudGenerator::generateGaussianClusters(CLOUD_N, 50, 2.0f);

    // 2. 生成 1K 查询点
    auto queries = PointCloudGenerator::generateGaussianClusters(QUERY_N, 10, 5.0f);

    // 3. 创建 stream
    cudaStream_t stream;
    cudaStreamCreate(&stream);

    // 4. CPU baseline
    auto cpuResult = cpuBruteKnn(cloud, queries);

    // 5. 拷贝到 GPU（pinned + async）
    PointCloudSoA devCloud, devQueries;
    PointCloudGenerator::copyToDeviceAsync(cloud, devCloud, stream);
    PointCloudGenerator::copyToDeviceAsync(queries, devQueries, stream);

    // 6. 跑各种 kernel 并计时
    float aosMs = Benchmark::timeKernel(stream, [&]() {
        runKnnAosBaseline(...);
    });
    float soaMs = Benchmark::timeKernel(stream, [&]() {
        runKnnSoa(...);
    });
    float smemMs = Benchmark::timeKernel(stream, [&]() {
        runKnnSmemTiling(...);
    });

    // 7. ESDF 构建
    float esdfMs = Benchmark::timeKernel(stream, [&]() {
        runJumpFloodEsdf(...);
    });

    // 8. 输出对比表 + 验证正确性
    Benchmark::printComparison(results);

    // 验证所有 GPU 结果和 CPU 一致
    int mismatches = verifyResults(...);
}
```

**讲解**：

- 用 lambda `&]()` 包装 kernel launch，方便统一计时
- 每个优化版本都跑一遍，对比加速比
- 最后用 CPU 结果作 ground truth 验证 GPU 正确性

---

# 如何使用本文档

## 学习顺序

1. **读 mentor_guide 阶段 N** 建立概念（故事 + 是什么 + 为什么）
2. **打开本文对应文件** 看关键代码段逐行讲解
3. **打开实际源码** 对照阅读，理解上下文
4. **编译运行** `./build/cuda_spatial_accel`，看真实数据
5. **查 interview_talk.md** 看这段代码的面试讲法

## 面试时怎么用

- 面试官问"你 SoA 怎么实现的"→ 你说"看 `gpu_optimized_soa.cu` 的 `knnSoaKernel`，关键改动是参数从 `PointAoS*` 改成三个 `float*`，warp 内访问连续 128B"
- 面试官问"warp shuffle 怎么归约 256 线程"→ 你说"看 `knn_search_kernel.cu`，两级归约：warp 内 5 步 shuffle，跨 warp 用 smem 中转再 shuffle"
- 面试官问"CUDA Graph 怎么用"→ 你说"看 `esdf_jump_flood.cu` 的 `runJumpFloodEsdf`，`cudaStreamBeginCapture` 录制 6 pass，`cudaGraphLaunch` 一次提交"

**核心心法**：每个优化点都对应**具体文件的具体代码段**，不是抽象理论。面试官追问细节，你能直接说出"看哪个文件的哪个函数"。
