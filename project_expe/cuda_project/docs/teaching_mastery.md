# CUDA 知识点科学教学精讲｜从硬件根因到面试讲法

> **这份文档的目标**：不是让你背台词，而是让你**真懂**。面试官追问"为什么"时，你能从 GPU 硬件原理出发，自然推导出每个优化方案的必然性。
>
> **教学方法**：费曼学习法 + 渐进式披露 + 生活类比建立直觉 + 自检问题确认掌握。
> 每个知识点按 `生活类比 → 是什么 → 为什么(硬件根因) → 怎么做 → 代码 → 面试讲法 → 自检` 七段式教学。

---

## 第 0 章：GPU 硬件架构——一切优化的根因

> **这是地基。不理解这一章，后面所有优化都是死记硬背。理解了这一章，后面每个优化都是"理所当然"。

### 0.1 CPU 和 GPU 的设计哲学

#### 🏠 生活类比：精锐小队 vs 万人军团

想象你要搬 10000 块砖：

- **CPU（精锐小队）**：5 个特种兵，每个力大无穷，能搬复杂地形、能做战术决策。但就 5 个人，搬 10000 块砖要跑 2000 趟。
- **GPU（万人军团）**：10000 个普通士兵，每人力量一般，只会执行简单指令。但一声令下 10000 人同时搬，1 趟搞定。

**核心区别**：

- CPU：少而精，强在**单线程性能**和**复杂逻辑**
- GPU：多而广，强在**数据并行吞吐**

这就是为什么 GPU 适合做点云 KNN（100 万个点同时算距离），不适合做操作系统调度（复杂分支逻辑）。

#### 📖 硬件事实

|          | CPU                      | GPU            |
| -------- | ------------------------ | -------------- |
| 核心数   | 4-16                     | 数千           |
| 单核性能 | 极强                     | 一般           |
| 缓存     | L1/L2/L3 多级，大        | L1/L2，小      |
| 控制单元 | 大（分支预测、乱序执行） | 小（锁步执行） |
| ALU 占比 | ~20%                     | ~80%           |

> **记住**：GPU 芯片面积 80% 是 ALU（算术逻辑单元），CPU 只有 20%。GPU 把控制电路的面积省下来全做成计算单元。这就是"万人军团"的物理来源。

### 0.2 线程层次：thread → warp → block → grid

#### 🏠 生活类比：军队编制

GPU 的线程有严格的编制，像军队一样：

```
一个 Grid = 一整支军队（全部任务）
  └─ 多个 Block = 多个团（每个团独立驻扎，不能互相通信）
       └─ 多个 Warp = 多个班（每个班 32 人，必须同步行动、走同一条路）
            └─ 32 个 Thread = 32 个士兵
```

**关键约束**（这是所有优化的根因）：

1. **Warp（班）是执行的基本单位**：32 个线程必须执行**完全相同的指令**。如果 if/else 让 32 人走不同路，就有一半人闲着（warp divergence）。
2. **Block（团）内可以通信**：同一个 block 的线程可以共享 shared memory，可以用 `__syncthreads()` 同步。
3. **Grid（军队）内 block 之间不能通信**：不同 block 之间没有同步机制，只能通过 global memory 间接通信。

#### 🎯 为什么 warp 是 32？

GPU 的 SIMT（Single Instruction Multiple Thread）调度器一次发射 32 条指令给 32 个线程。这 32 个线程必须执行同一条指令，否则就要分两次发射（warp divergence，浪费一半算力）。

> **自检**：为什么说 if/else 分支是 GPU 性能杀手？
> **答**：因为 warp 内 32 线程必须执行相同指令。if 分了两条路，warp 要先执行 if 分支（else 的线程闲着），再执行 else 分支（if 的线程闲着）。串行化了。

### 0.3 内存层次：registers → shared → L1/L2 → global

#### 🏠 生活类比：仓库体系

```
你的口袋（寄存器 Register）     → 秒取，但只能装几样东西
你的工位抽屉（共享内存 Shared） → 几步路，全组共享，不大
楼层储藏间（L1/L2 缓存）        → 几十步，自动管理
楼下大仓库（全局内存 Global）   → 几百步，巨大但慢
```

**延迟对比**（这是所有内存优化的根因）：

| 层级                   | 延迟（cycles） | 容量           | 谁能用        |
| ---------------------- | -------------- | -------------- | ------------- |
| 寄存器 Register        | ~1             | 每线程几十个   | 每线程私有    |
| 共享内存 Shared Memory | ~20            | 每 SM 48-164KB | 同 block 共享 |
| L1/L2 缓存             | ~30-100        | 几百 KB        | 硬件自动管理  |
| 全局内存 Global        | ~400-800       | 几 GB          | 所有线程      |

> **记住这张表**。后面所有优化都在解决同一个问题：**怎么让数据从 global 搬到 shared/register 再算，而不是反复跑 global**。

#### 🎯 带宽是 GPU 的生命线

GPU 有数千核心，如果都在等 global memory，就像万人军团都在排队去大仓库取货——仓库门只有那么大，全部堵死。

GPU 的 global memory 带宽约 1-2 TB/s（A100 约 2TB/s）。听起来很大，但 10000 个线程同时要数据，每个线程分到的带宽很有限。

**所以所有优化的核心逻辑**：

1. 减少访问 global 的次数（tiling 复用、kernel fusion）
2. 每次访问尽量高效（合并访存、bank conflict 规避）
3. 能用 shared/register 就不用 global

> **自检**：为什么 shared memory 能加速？
> **答**：延迟从 ~400 cycles 降到 ~20 cycles，差 20 倍。而且 shared memory 带宽远高于 global（片上 SRAM vs 片外 DRAM）。把数据从 global 拷到 shared，block 内线程复用，访问量降 N 倍。

---

## 第 0.4 章：片上 vs 片外、SM vs Block、Shared Memory 物理隔离

> **这一章纠正一个最大误区**：很多人把"Block"当成硬件单元，把"片上"理解为整个 GPU。读完本章彻底理顺。

### 0.4.1 "片上"是哪片？

先一句话：**"片上" = GPU 芯片本身那块硅晶片（die）上面**，也就是 GPU 那个大硅裸片，**不是 PCB 电路板，不是显存颗粒**。

#### 📖 硬件事实

GPU 显卡拆开看到两层：

1. **GPU Die（硅晶片/芯片裸片，就是"片"）**：黑色大芯片，光刻出来的硅。
   - 上面蚀刻出来一堆硬件：84 个 SM、寄存器阵列、L1 缓存、**Shared Memory（SRAM）、L2 Cache**。
   - → 这些都叫**片上（on-chip）**，就在硅片内部，离 CUDA 核心极近，延迟低。
2. **GDDR 显存颗粒**：焊在显卡 PCB 电路板上，**不在 GPU 硅片里面** → **片外（off-chip）**，也就是 Global Memory 全局显存。

✅ **Shared Memory 是片上 SRAM**：在 GPU 硅片内部，属于 SM 里面的一块高速内存。
❌ **Block ≠ 片上！**：Block 是软件逻辑概念，不是硬件。

### 0.4.2 Block（线程块）：软件概念，不是硬件！

CUDA 里：

- **Block（线程块）**：写代码时定义的逻辑分组，多个线程组成一个 block。
- **SM（流多处理器）**：**硬件单元**，硅片上真实存在的硬件。

#### 🔧 硬件调度规则

> - 一个**完整 Block 只能部署在同一个 SM 上**；**Block 不能跨 SM 拆分**。
> - 一个 SM 同一时刻可以承载若干个 block（资源够就放多个）。
> - ✅ 同一个 block 内所有线程 → 能访问这块 SM 上**同一份 shared memory**。
> - ❌ **A block 不能访问 B block 的 shared memory**，哪怕 A 和 B 同驻一个 SM。

#### ⚠️ 重点纠正

- Shared memory **隶属于 SM 硬件**，不是隶属于 block。
- 当 block 执行结束，这块 shared 内存就**释放回收**，给下一个 block 复用。
- Block 只是软件线程分组，不是硬件，**block 不是片上**。
- "不同 block 无法调度" → ❌ 表述不对。✅ 修正：**多个 block 可以被硬件调度到不同 SM 上并行跑**；但是 **A block 不能访问 B block 的 shared memory**。

### 0.4.3 Global Memory 是什么？

**Global Memory = 焊在显卡电路板上的 GDDR 显存颗粒（片外，不在 GPU 硅 die 里面）**。

- **所有 SM（所有处理器）全都可以访问全局显存**。
- 所有 block，不管跑在哪个 SM，读写的是**同一块全局内存空间**。
- 不是"多个处理器之间的内存"，是**整个 GPU 所有 SM 共享的大容量片外内存**。

### 0.4.4 极简关系汇总

| 概念                    | 位置                | 属性                               | 速度 | 容量 |
| ----------------------- | ------------------- | ---------------------------------- | ---- | ---- |
| **片上 on-chip**  | GPU 硅晶片 die 内部 | Register / Shared Memory / L1 / L2 | 快   | 小   |
| **片外 off-chip** | PCB 板上 GDDR 显存  | Global Memory                      | 慢   | 大   |
| **SM**            | 片上真实硬件        | 硅片上蚀刻的处理器单元             | —   | —   |
| **Block**         | 软件逻辑分组        | 代码里定义的线程组，不是硬件       | —   | —   |

调度规则：

1. 一个 Block **整体分配到某一个 SM 上运行**；Block 不能跨 SM 拆分。
2. Shared Memory 属于 SM 硬件资源；同一 block 内线程共享这块 SM 上的 shared memory。
3. 不同 block 之间**无法互相访问 shared memory**（即使同驻一个 SM）。
4. Global Memory（GDDR）是片外，**GPU 全部 SM 都能读写**，容量大、访问延迟几百 cycle。

### 0.4.5 🏠 比喻（好记）

**GPU 硅片（片）= 一栋大楼**，大楼里面有 84 个独立房间，每个房间就是一个 SM。

- **Shared Memory**：**房间里面自带的储物柜（片上 SRAM）**。
- **Block**：**一批工人（线程）**，整组工人全部安排在**同一个房间（SM）**干活。
  - 同一组工人（block）可以共用这个房间储物柜（shared）。
  - 另外一组工人放到另一个房间，**不能跑到别的房间拿储物柜东西**。
- **Global 显存**：**大楼外面很远的公共大仓库（片外 GDDR）**，大楼里所有房间（所有 SM）都可以去这个大仓库取货，但是跑过去取货很慢（几百 cycle 延迟）。

---

### 0.4.6 Shared Memory 的物理划分与隔离（深度理解）

> 继续储物柜比喻：SM = 一间房间，Shared Memory = **这个房间里固定大小的储物柜（整块物理 SRAM，片上硬件）**，Block = 一组工人。

#### 🎯 核心一句话

**SM 的 shared memory 是一整块物理 SRAM。当你把多个 block 放到同一个 SM 上，硬件会把这块物理 SRAM 进行静态划分：给每个 block 分配独立的一块区域，互相隔离，互不干扰。**

- ✅ 每个 block **拥有属于自己的那一份 shared 内存**。
- ✅ Block A 看不到、不能读写 block B 在同一个 SM 里的 shared memory。
- ✅ 当 block 执行结束退出，它占用的这块 shared 内存空间**回收**，可以分配给后续调度进来的新 block。

#### 💡 举例（Ampere SM：shared 总大小最多 164KB）

假设 kernel 里每个 block 声明要用 **32KB shared memory**：

```
单个 SM 总共有 164KB 储物柜
164 / 32 ≈ 5   →  这个 SM 最多可以同时驻留 5 个 block

硬件自动把 164KB 切成 5 份，每份 32KB：
┌─────────┬─────────┬─────────┬─────────┬─────────┬─────┐
│ Block0  │ Block1  │ Block2  │ Block3  │ Block4  │空闲 │
│ 0-32KB  │32-64KB  │64-96KB  │96-128KB │128-160KB│4KB  │
└─────────┴─────────┴─────────┴─────────┴─────────┴─────┘

每个 block 的线程只能访问分配给自己的那一段
硬件做内存保护，不能越界读写别的 block 的 shared
```

#### ⚠️ 关键规则

1. **分配粒度是 kernel 编译时确定**：代码里 `__shared__ float s_data[XXX]`，编译阶段就算出**单个 block 需要多少 shared**。
2. 硬件在往 SM 加载 block 之前，先检查：剩余 shared 内存够不够放下这个 block 需要的 shared。不够，就不会把这个 block 调度到这个 SM。

> 👉 **这就是为什么：单个 block 申请的 shared 越大，同一个 SM 能同时放的 block 数量越少 → achieved occupancy 下降**（和 ncu 指标串上了！）

#### 🔄 生命周期

1. Block 被调度进入 SM → 硬件从 SM 整块 shared 内存里划出一块专属区域给这个 block。
2. Block 内部线程读写属于自己这块 shared，和同 SM 上其他 block **完全隔离，互不干扰**。
3. Block 所有线程全部执行完成，block 退出 → 这块 shared 内存**释放，回收**，可以分配给新来的 block。

#### 🚫 容易踩坑的误区

| 误区                                              | 正解                                                                         |
| ------------------------------------------------- | ---------------------------------------------------------------------------- |
| ❌ 每个 block 自带一块独立物理 SRAM               | ✅ 物理硬件只有**一整块 SRAM 在 SM 里**，是划分空间，逻辑隔离          |
| ❌ 同一个 SM 上多个 block 可以互相读写对方 shared | ✅ 不行！硬件隔离，互相不可见。shared 内存**作用域只在本 block**       |
| ❌ shared 是动态 malloc，运行时随便申请大小       | ✅ 不是。`__shared__` 大小编译期固定，硬件提前算好一个 block 占多少 shared |

---

### 0.4.7 🗣️ 面试口述精简版

> "片上"指 GPU 的硅芯片 die 内部。Shared Memory 是片上 SRAM，集成在 SM 硬件里面。
>
> Block 是软件上的线程分组，**不是硬件**；一个 block 必须全部跑在同一个 SM 上，所以同一个 block 内线程共享这个 SM 的 shared memory。不同 block 可以调度到不同 SM 并行执行，但**无法互相访问对方的 shared memory**——哪怕同驻一个 SM，硬件也会把 SM 的整块 SRAM 静态划分给各个 block，互相隔离。
>
> 单个 block 申请的 shared 越大，同一个 SM 能同时容纳的 block 越少，会拉低 occupancy。block 执行完毕，它占的 shared 空间回收，给后续 block 复用。
>
> 全局内存 Global Memory 是片外的 GDDR 显存，不在硅片内部，GPU 所有 SM 都能访问它，容量大但访问延迟很高。

### 0.4.8 ❓ 自测

**Q1**：多个 block 能不能放到同一个 SM 上？

> 可以，SM 资源够的话，可以加载多个 block，分时调度 warps。但是这些 block 各自独立，不能互访 shared memory。

**Q2**：shared memory 是每个 block 单独分配一块物理 SRAM 吗？

> 不是。SM 有一块物理 shared SRAM。block 占用一部分，block 执行完就释放，供下一个 block 复用。

**Q3**：同一个 SM 上两个 block，能通过 shared memory 互相传数据吗？

> 不能。shared 的作用域仅限 block 内部。block 之间通信只能走全局显存 Global Memory。

**Q4**：为什么 block 声明的 shared 越大，occupancy 越低？

> SM 的 shared SRAM 总量固定（如 Ampere 164KB）。一个 block 要 32KB → 同 SM 最多 5 个 block；要 80KB → 最多 2 个。block 数量少 = 同时驻留的 warp 少 = occupancy 低。

**Q5**：Block 能不能跨 SM 拆分？

> 不能。一个完整 block 必须全部跑在同一个 SM 上，这是硬件规则。

---

## 第 1 章：数据搬运优化

### 1.1 Pinned Memory（锁页内存）

#### 🏠 生活类比：快递集散

你从北京发货到上海仓库（GPU）：

**普通内存（pageable）**：

- 货物散放在老百姓家里，操作系统随时可能把货搬到别处（换页）
- 快递员来收货，发现"这家的货被搬走了"，要先找到、集中到中转站
- 多一道"找货+集中"的手续

**Pinned memory（锁页）**：

- 货物锁在中转站，操作系统保证不动它
- 快递员来直接装车，省一道手续
- DMA（直接内存访问）引擎直接拿地址搬运

#### 📖 是什么

用 `cudaMallocHost` 分配的 host 内存，物理页固定在内存中，不会被操作系统换出到硬盘。

#### 🎯 为什么需要

CUDA 的 DMA 引擎搬运数据时，需要物理地址连续且固定。pageable 内存可能被换页，驱动必须先拷到临时 pinned 缓冲再 DMA，多一次拷贝。

#### ⚙️ 怎么做

```cpp
// 普通 malloc（慢）
float* hCloud = (float*)malloc(N * sizeof(float));

// Pinned（快）
float* hCloud;
cudaMallocHost(&hCloud, N * sizeof(float));  // 锁页

// 释放
cudaFreeHost(hCloud);  // 不能用 free()
```

#### 🗣️ 面试讲法

> "数据搬运的第一步是 pinned memory。普通 malloc 的内存是 pageable 的，操作系统可以换页，CUDA DMA 搬运时要多一道中转拷贝。我用 `cudaMallocHost` 分配锁页内存，物理页固定，DMA 直接搬运，省一次拷贝。"

#### ❓ 自检

- pinned memory 的代价是什么？→ 占用物理内存不能被换出，长期占用影响系统内存
- 什么时候不该用？→ 数据量极小（<1KB），中转开销可忽略

---

### 1.2 Async Copy + CUDA Stream

#### 🏠 生活类比：流水线收费站

**同步搬运**：

- 卡车发货（cudaMemcpy H2D），你在收费站等它到上海卸完货才回来
- 等待期间你（CPU）和加工线（GPU kernel）都闲着

**异步搬运**：

- 卡车自己跑（cudaMemcpyAsync），你立刻去准备下一批货或启动加工
- 用 CUDA stream 把"搬运"和"计算"放不同队列，可以并行

#### 📖 是什么

- **CUDA stream**：GPU 上的任务队列。同 stream 内按顺序执行，不同 stream 间可以并行。
- **cudaMemcpyAsync**：异步拷贝，CPU 立刻返回，GPU 在 stream 内排队执行搬运。

#### 🎯 为什么需要

数据搬运（H2D）和计算（kernel）是两个独立操作。如果同步执行：

```
搬运 5ms → 计算 10ms → 搬运 5ms → 计算 10ms = 30ms
```

异步 pipeline：

```
搬运 5ms ──→ 计算 10ms
            搬运 5ms ──→ 计算 10ms  = 20ms（重叠了搬运和计算）
```

#### ⚙️ 怎么做

```cpp
cudaStream_t stream;
cudaStreamCreate(&stream);

// 异步搬运（立刻返回，GPU 在 stream 内排队搬运）
cudaMemcpyAsync(devPtr, hostPtr, size, cudaMemcpyHostToDevice, stream);

// 同一个 stream 内的 kernel 会等搬运完成才执行
myKernel<<<grid, block, 0, stream>>>(devPtr);

// 不同 stream 的任务可以和上面并行
cudaStream_t stream2;
cudaStreamCreate(&stream2);
otherKernel<<<grid, block, 0, stream2>>>(otherDevPtr);
```

#### 🗣️ 面试讲法

> "光用 pinned 还不够，数据搬运和计算是两个独立操作。我用 `cudaMemcpyAsync` + CUDA stream，把搬运放一个 stream，kernel 放同 stream 排在后面。GPU 的 DMA engine 搬数据时，SM 可以同时跑另一个 stream 的 kernel。这就是 pipeline 思想——搬运和计算重叠。"

#### ❓ 自检

- 同一个 stream 内的搬运和 kernel 能并行吗？→ 不能，同 stream 内按序执行。要并行必须不同 stream。
- 异步拷贝后立刻读结果会怎样？→ 数据可能还没搬完，必须 `cudaStreamSynchronize` 等待。

---

## 第 2 章：内存布局优化

### 2.1 AoS vs SoA

#### 🏠 生活类比：仓库货架摆放

你有 100 万个包裹，每个包裹有长宽高三个属性。

**AoS（Array of Struct，结构体数组）**：

- 货架上摆 `[长1, 宽1, 高1, 长2, 宽2, 高2, ...]`
- 想取所有"长"？要隔 3 个拿一个，跑来跑去

**SoA（Struct of Array，数组结构体）**：

- 分三个货架：长货架 `[长1, 长2, ...]`、宽货架、高货架
- 想取所有"长"？一个货架顺序拿，一趟搞定

#### 📖 是什么

```cpp
// AoS：每个点的数据挨着存
struct Point { float x, y, z; };
Point cloud[N];        // cloud[0].x, cloud[0].y, cloud[0].z, cloud[1].x...

// SoA：每个维度分开存
struct CloudSoA { float* x; float* y; float* z; };
CloudSoA cloud;        // x[0], x[1], x[2]... y[0], y[1]...
```

#### 🎯 为什么 SoA 在 GPU 上快

这要回到 warp 的工作方式。warp 内 32 个线程**同时**访问内存：

- 线程 0 访问 `cloud[0].x`，线程 1 访问 `cloud[1].x`...
- AoS：`cloud[0].x` 在地址 0，`cloud[1].x` 在地址 12（每个 Point 12 字节）
- 32 线程访问的地址间隔 12 字节，**不连续**，不是一次 128B 事务能覆盖的

SoA：

- 线程 0 访问 `x[0]`，线程 1 访问 `x[1]`...
- 地址连续：0, 4, 8, 12... 32 线程访问 128 字节连续区间

#### ⚙️ 合并访存（Coalesced Access）

GPU 的 global memory 控制器一次处理 **128 字节**事务。32 个线程（每线程 4 字节 float）正好 128 字节：

- **合并**：32 线程访问连续 128B → 1 次事务，带宽利用率 100%
- **非合并**：32 线程访问散乱地址 → 可能 32 次事务，带宽利用率 3%

```
AoS：32 线程访问 cloud[0..31].x，地址间隔 12B → 散乱 → ~10 次事务 → 带宽 10%
SoA：32 线程访问 x[0..31]，地址连续 128B → 1 次事务 → 带宽 100%
```

> **这就是 50ms → 15ms 的根因**。不是算法变了，是数据摆放方式让带宽利用率从 10% 拉到 60%+。

#### 💻 代码

```cpp
// AoS 版本（慢，非合并）
__global__ void knnAoS(Point* cloud, int n, Point query, int* out) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    float dx = cloud[i].x - query.x;  // 32 线程访问 cloud[0..31].x，间隔 12B
    // ...
}

// SoA 版本（快，合并）
__global__ void knnSoA(
    const float* __restrict__ xs,  // 告诉编译器无别名
    const float* __restrict__ ys,
    const float* __restrict__ zs,
    int n, float qx, float qy, float qz, int* out
) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    float dx = xs[i] - qx;  // 32 线程访问 xs[0..31]，连续 128B
    // ...
}
```

#### 🗣️ 面试讲法

> "AoS baseline 50ms 已经 40 倍加速了，但带宽利用率只有 30%。我 profile 发现 warp 内 32 线程访问 `cloud[i].x`，地址间隔 12 字节（每个 Point 12B），不连续。GPU 一次处理 128B 事务，32×4B=128B 刚好一次，但 AoS 的散乱地址让它变成多次事务。改成 SoA 后，`xs[i]` 连续 128B，1 次事务，带宽到 60%+，时间降到 15ms。**这不是算法优化，是让数据布局匹配硬件访问粒度**。"

#### ❓ 自检

- `__restrict__` 是什么？→ 告诉编译器"这个指针指向的内存没有其他指针别名"，编译器可以更激进地优化（如把 load 提前到 store 前面）。
- 什么时候 AoS 反而更好？→ 访问对象的所有字段都要用（取完 x 紧接着取 y、z），AoS 一次 load 进缓存，SoA 要三次 load。

---

### 2.2 Bank Conflict（共享内存冲突）

#### 🏠 生活类比：超市收银

shared memory 内部分 **32 个收银台**（bank），warp 内 32 个线程每人去一个收银台。

**无冲突**：32 人各去不同收银台 → 32 路并行，一次搞定。

**Bank conflict**：多个线程去了**同一个收银台** → 那个收银台排队，串行处理。32 人撞同一个 bank → 32 倍慢。

#### 📖 是什么

shared memory 物理上分成 32 个 bank，每个 bank 可以独立服务一个线程。bank 的映射规则：`bank = (address / 4) % 32`（每 4 字节一个 bank）。

#### 🎯 什么时候会撞 bank

经典坑——**stride 访问**：

```cpp
__shared__ float buf[1024];
// 如果线程 i 访问 buf[i * 32]，那 32 个线程访问的地址都是 bank 0
// → 32 倍 bank conflict！
float val = buf[threadIdx.x * 32];  // 灾难
```

#### ⚙️ 怎么规避

**Padding 法**：数组长度加 1，错开 bank 映射：

```cpp
// 有冲突：1024 是 32 的倍数，stride 32 访问全撞 bank 0
__shared__ float buf[1024];

// 无冲突：1025 不是 32 的倍数，bank 映射错开
__shared__ float buf[1024 + 1];  // padding 1 个元素
```

#### 🗣️ 面试讲法

> "shared memory 分 32 个 bank，每个 bank 串行处理。如果 warp 内 32 线程访问同一 bank，就退化成串行，慢 32 倍。经典坑是 stride 访问 `buf[i*32]`，全撞 bank 0。我用 padding（数组 1024 改 1025）错开 bank 映射。性能问题不能猜，我用 ncu profile 才发现这个 conflict，改完快了 5 倍。"

#### ❓ 自检

- 广播（32 线程读同一个地址）算 bank conflict 吗？→ 不算，广播是一条指令给所有线程，硬件专门优化过。但写同一地址是未定义行为。
- 怎么定位 bank conflict？→ `ncu --metrics shared_mem_utilization` 或看 Nsight Compute 的 Source 页面，会标红。

---

## 第 3 章：并行调度优化

> ⚠️ **本章导读**：阶段 5 是整个项目的性能高潮（59ms → 4.72ms）。三个技术——smem tiling、bank conflict 规避、warp shuffle——表面是三个故事，但内部都对应**硬件事实 + 代码映射 + 工程取舍**。下面先把三个故事"切片深挖"到代码层和工程层，再展开每个技术。

### 3.0 三故事深挖：从故事 → 硬件 → 代码 → 工程

#### 📕 故事 1 深挖：Shared Memory Tiling —— 工地协作

**故事回顾**：1000 工人查 10000 块砖哪个离自己最近。不分组 = 1000×10000 = 1000 万次仓库访问；分 256 人一组协作搬 1024 块到工位共享 → 每块搬 1 次被 4 人查，仓库访问降到 250 万次。

**❓ tiling 是不是"分块"？**
✅ **是。但比普通的"分块"更精确**：

- "分块"是结果——把 10000 个点切成 10 个 1024 大小的 tile
- "tiling"是机制——**block 内 256 线程协作把一个 tile 从 global 搬到 smem，让 256 个线程共享这 1024 个点**
- 关键不在"切"，而在"**协作搬运 + 块内复用**"——这才是 tiling 的工程本质

**🔧 硬件事实（为什么能省 4 倍）**：

1. global → smem 一次搬 1024 个点 = 256 线程 × 每线程搬 1 个 = 256 次合并访存（1 个 cache line 搬 32 个 float，刚好 8 个事务）
2. 搬到 smem 后，**256 个线程都从 smem 读这 1024 个点**——读 smem 不走 global，免费
3. 复用率 = tile_size / block_size = 1024 / 256 = **4 倍**：每点从 global 搬 1 次，被 4 个线程从 smem 读 4 次

**📍 代码映射**（[knn_search_kernel.cu:55-76](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/knn_search_kernel.cu)）：

```cpp
// 外层循环：遍历所有 tile
for (size_t tileStart = 0; tileStart < cloudN; tileStart += blockDim.x) {
    // ① 协作拷贝：thread t 搬 tile 中第 t 个点（一人搬一块砖）
    size_t gi = tileStart + tid;
    if (gi < cloudN) {
        tileX[tid] = cxs[gi];   // ← 这里是 global→smem 的搬运
        tileY[tid] = cys[gi];
        tileZ[tid] = czs[gi];
    }
    __syncthreads();   // ② 等 256 人都搬完，smem 数据就绪
    // ③ 全 block 从 smem 读，每个线程算自己的最近候选
    if (gi < cloudN) {
        float dx = tileX[tid] - qx;   // ← 从 smem 读，不是 global
        ...
    }
    __syncthreads();   // ④ 等全 block 用完，再搬下一 tile
}
```

**🎯 工程取舍**（tile 大小怎么选）：

- tile 太小（如 32）：复用率 32/256<1，没省到，还多了 syncthreads 开销 → 慢
- tile 太大（如 16384）：一个 block 的 smem 占用 = 16384×3×4B = 192KB，超出 SM 的 164KB 上限 → 跑不起来；即使跑起来，一个 SM 只能放 1 个 block → occupancy 暴跌
- 我们选 256：tile = blockDim，一人搬一个，零冗余搬运；smem 占用 3KB，一个 SM 还能放 5+ 个 block，occupancy 健康

**⚠️ 代码里的"反直觉"细节**：很多人写 tiling 是"全 block 每个线程扫整个 tile"——我们**不是**这么写的。看代码第 70 行：`if (gi < cloudN) { float dx = tileX[tid] - qx; }`——**每个线程只算 tile 中第 tid 个位置**，不扫整个 tile。这样 256 线程并行处理 256 个点，零重复工作。扫整个 tile 是旧版 bug，180ms 比 SoA baseline 还慢，已修复。

---

#### 📕 故事 2 深挖：Bank Conflict —— 超市 32 收银台

**故事回顾**：smem 内部分 32 个收银台（bank），warp 32 线程每人去一个收银台。无冲突 = 32 路并行；撞同一个收银台 = 串行排队。

**❓ "多人撞同一收银台"在什么情况发生？**

核心是**地址映射规则**：`bank_id = (byte_address / 4) % 32`。每 4 字节一个 bank，32 个 bank 一组循环。

**3 种典型撞 bank 场景**：

**场景 A：stride 访问（最经典坑）**

```cpp
__shared__ float buf[1024];
// 线程 i 访问 buf[i * 32]
float v = buf[threadIdx.x * 32];
// 线程0: addr=0,    bank=(0/4)%32=0
// 线程1: addr=128,  bank=(128/4)%32=0   ← 撞 bank 0！
// 线程2: addr=256,  bank=(256/4)%32=0   ← 撞 bank 0！
// ... 32 线程全撞 bank 0 → 32 路串行
```

**场景 B：矩阵转置按列读**

```cpp
__shared__ float mat[32][32];
// 线程 i 读 mat[i][0] 的列
float v = mat[threadIdx.x][0];
// 线程0: addr=0,    bank=0
// 线程1: addr=128,  bank=0   ← 列方向每行跨 32 个 float=128B，全映射到 bank 0
```

**场景 C：结构体数组放 smem**

```cpp
struct Point { float x, y, z; };
__shared__ Point pts[32];
// 线程 i 读 pts[i].x
float v = pts[threadIdx.x].x;
// 线程0: addr=0,    bank=0
// 线程1: addr=12,   bank=(12/4)%32=3   ← 没撞！
// 线程2: addr=24,   bank=6
// 这里恰好分散开了，但 pts[i].y 又是另一组 bank
```

**❓ Padding 为什么有用？——打断"周期对齐"**

```cpp
// 有冲突：1024 是 32 的整数倍
__shared__ float buf[1024];
// 线程 i 访问 buf[i * 32]
// bank = (i*32*4 / 4) % 32 = (i*32) % 32 = 0  ← 永远是 0！

// Padding：数组改 1025
__shared__ float buf[1025];
// 还是要错开访问模式，配合 padding
// 线程 i 访问 buf[i * 33]  ← stride 改成 33 不是 32
// bank = (i*33*4 / 4) % 32 = (i*33) % 32
// i=0: 0, i=1: 1, i=2: 2, ... 全部不同 bank！
```

**🔑 本质**：padding 不是"加一个元素就完了"，而是**让 stride 不再是 32 的整数倍**。bank 映射是 mod 32，只要 stride 和 32 互质（如 33），就保证 32 线程访问 32 个不同 bank。

**📍 我们项目里有 bank conflict 吗？**

看 [knn_search_kernel.cu:35-37](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/knn_search_kernel.cu)：

```cpp
float* tileX = smem;              // tileX[0..255]
float* tileY = smem + blockDim.x; // tileY[0..255]
float* tileZ = smem + 2*blockDim.x;
```

访问模式：线程 tid 读 `tileX[tid], tileY[tid], tileZ[tid]`。

- tid=0: tileX[0] @ bank 0, tileY[0] @ bank 0 (smem+256, 256*4=1024B, bank=(1024/4)%32=0)
- tid=1: tileX[1] @ bank 1, tileY[1] @ bank 1

**看起来 X/Y/Z 的 tid 都映射到同一 bank？** 实际不会冲突，因为**访问是分时的**——dx/dy/dz 是三条独立 load 指令，每条指令下 32 线程读 tileX[0..31] 是连续 32 个 bank → 无冲突。三条指令顺序执行，互不干扰。

**⚠️ 但归约阶段有潜在 conflict**：

```cpp
float* warpBestDist = smem + 3 * blockDim.x;  // warpBestDist[8]
int* warpBestIdx = (int*)(smem + 3*blockDim.x + blockDim.x/32);
```

warp 0 的 32 线程读 `warpBestDist[lane]`（lane<8 才有数据，其余读 1e30f）。lane 0..7 各读不同 bank，lane 8..31 都读同一个 padding 值 1e30f——**这是广播，不算 conflict**（硬件优化了广播）。

**🛠️ 怎么定位**：

```bash
ncu --metrics shared_mem_utilization,l1_shared_memory_bank_conflicts ./cuda_spatial_accel
# Nsight Compute Source 页面会标红冲突行
```

---

#### 📕 故事 3 深挖：Warp Shuffle —— 32 人传话游戏

**故事回顾**：32 人站成一圈找最小值。朴素 = 写白板+串行比较 32 次；shuffle = 5 轮传话，每轮看对面的人取小，log2(32)=5 步全找到。

**❓ 为什么是 5 步？**

32 = 2^5，**树形归约**：每轮人数减半。

```
轮次  offset  配对方式       剩余候选
─────────────────────────────────────
 1     16     0↔16, 1↔17...    32→16
 2     8      0↔8,  1↔9...     16→8
 3     4      0↔4,  1↔5...     8→4
 4     2      0↔2,  1↔3...     4→2
 5     1      0↔1,  2↔3...     2→1  ← 全员一致
```

**🔧 硬件本质（为什么不走 smem）**：

`__shfl_xor_sync` 是一条**硬件指令**，让 warp 内线程直接读对方**寄存器**的值：

- 不分配 smem
- 不触发 bank conflict
- 不需要 syncthreads（warp 内天然同步）
- 延迟 ~1 cycle（寄存器→寄存器）

vs smem + atomic：

- smem 写入 20 cycles
- atomic 串行 32 次 = 32 × 20 = 640 cycles
- smem 读回 20 cycles
- 合计 680 cycles，而 shuffle 只要 5 cycles

**📍 代码映射**（[knn_search_kernel.cu:80-88](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/knn_search_kernel.cu)）：

```cpp
// 第 1 级归约：warp shuffle 在 warp 内找最小
for (int offset = 16; offset > 0; offset >>= 1) {
    float otherDist = __shfl_xor_sync(0xffffffff, bestDist, offset);
    int  otherIdx  = __shfl_xor_sync(0xffffffff, bestIdx, offset);
    if (otherDist < bestDist) {
        bestDist = otherDist;
        bestIdx = otherIdx;
    }
}
// 5 轮后，warp 内 32 线程的 bestDist 都是本 warp 的最小值
```

逐行解读：

- `0xffffffff` = 全 warp（32 线程）都参与
- `__shfl_xor_sync(mask, val, offset)` = 把自己 val 发给 lane^(offset) 的线程，同时收到 lane^(offset) 的 val
- `offset=16` 时：lane 0 收到 lane 16 的，lane 1 收到 lane 17 的...两两配对取小
- 5 轮后所有 lane 都拿到 warp 的全局最小

**🎯 但我们 block 有 256 线程 = 8 个 warp，怎么跨 warp 归约？**

这是 shuffle 的限制——**shuffle 只在 warp 内（32 线程）有效，跨 warp 必须走 smem**。

代码用**两级归约**：

```
256 线程 = 8 个 warp
级 1：每个 warp 内 shuffle 归约 → 得到 8 个 warp 最小值
       ↓ lane 0 写到 smem warpBestDist[warpId]
级 2：warp 0 把 8 个值载入自己的 lane（lane<8 才有数据）
       再做一次 shuffle 归约 → 1 个全局最小值
       ↓ lane 0 写回 global
```

看 [knn_search_kernel.cu:90-110](file:///home/sti/Documents/trae_projects/cv/project_expe/cuda_project/src/knn_search_kernel.cu)：

```cpp
// 第 1 级归约后，每个 warp 的 lane 0 持有本 warp 最小值
if (lane == 0) {
    warpBestDist[warpId] = bestDist;   // 8 个 warp 各写一个
    warpBestIdx[warpId]  = bestIdx;
}
__syncthreads();

// 第 2 级：warp 0 把 8 个值搬进自己的 lane
if (warpId == 0) {
    float myDist = (lane < 8) ? warpBestDist[lane] : 1e30f;
    int  myIdx  = (lane < 8) ? warpBestIdx[lane]  : -1;
    // 再做一次 warp shuffle
    for (int offset = 16; offset > 0; offset >>= 1) {
        ...
    }
    if (lane == 0) {   // warp 0 lane 0 = 全局最小
        outDists[q] = myDist;
        outIndices[q] = myIdx;
    }
}
```

**⚠️ 工程坑（我们踩过）**：

- 旧版 bug：只做 warp 0 的 shuffle，没做跨 warp 归约 → 8 个 warp 只有 warp 0 的结果对，其他 7 个 warp 的最小值丢了
- 修复：加 smem 中转 + 第 2 级 shuffle，8 个 warp 都参与

**🎯 性能对比**：

| 方式                     | 步数          | 周期                       |
| ------------------------ | ------------- | -------------------------- |
| smem + atomic            | 32 次串行     | 680 cycles                 |
| warp shuffle（1 级）     | 5 步并行      | 5 cycles                   |
| 两级 shuffle（256 线程） | 5 + 5 = 10 步 | ~30 cycles（含 smem 中转） |

**🚀 迁移场景**：

- LLM attention 的 softmax reduce-sum：FlashAttention row-wise reduction 就是这套
- 任何 reduce（sum/max/min）算子都这么写
- 经典 CUDA reduce 算子模板

---

### 3.1 Shared Memory Tiling（分块复用）

#### 🏠 生活类比：工地协作

1000 个工人（线程）要查 10000 块砖（点云）中哪块离自己最近。

**不用 tiling**：每个工人各自跑去仓库（global）取 10000 块砖来看 → 1000×10000 = 1000 万次仓库访问，仓库门堵死。

**用 tiling**：1000 人分成若干组，每组 256 人。每次一组协作从仓库搬 1024 块砖到工位（shared memory），组内 256 人共享这 1024 块砖查距离。下一批再搬 1024 块。

```
复用率 = 1024 / 256 = 4 倍（每块砖从仓库搬一次，被 4 个工人查）
```

#### 📖 是什么

把 global memory 的数据分块（tile），block 内线程协作拷到 shared memory，所有线程从 shared memory 读，避免反复访问 global。

#### 🎯 为什么有效

1. shared memory 延迟 ~20 cycles，global ~400 cycles，差 20 倍
2. 每 tile 被整个 block（256 线程）复用，global 访问量降为原来的 1/复用率

#### ⚙️ 怎么做

```cpp
__global__ void knnSmemTiling(
    const float* __restrict__ cxs, const float* __restrict__ cys,
    const float* __restrict__ czs, int cloudN,
    const float* qxs, const float* qys, const float* qzs,
    int queryN, int* outIdx, float* outDist
) {
    // 1. 分配 shared memory tile
    extern __shared__ float tile[];
    float* tileX = tile;
    float* tileY = tile + blockDim.x;
    float* tileZ = tile + 2 * blockDim.x;

    int q = blockIdx.x;     // 一个 block 处理一个查询点
    float qx = qxs[q], qy = qys[q], qz = qzs[q];

    float bestDist = 1e30f;
    int bestIdx = -1;

    // 2. 分块遍历点云
    for (int tileStart = 0; tileStart < cloudN; tileStart += blockDim.x) {
        int t = threadIdx.x;
        int gi = tileStart + t;

        // 3. 协作拷贝：每个线程搬一个点
        if (gi < cloudN) {
            tileX[t] = cxs[gi];
            tileY[t] = cys[gi];
            tileZ[t] = czs[gi];
        }
        __syncthreads();   // 等全 block 搬完

        // 4. 所有线程从 shared memory 读，查最近距离
        int tileN = min(blockDim.x, cloudN - tileStart);
        for (int i = 0; i < tileN; ++i) {
            float dx = tileX[i] - qx;
            float dy = tileY[i] - qy;
            float dz = tileZ[i] - qz;
            float d = dx*dx + dy*dy + dz*dz;
            if (d < bestDist) {
                bestDist = d;
                bestIdx = tileStart + i;
            }
        }
        __syncthreads();   // 等全 block 用完再搬下一批
    }

    // 写回结果
    if (threadIdx.x == 0) {
        outIdx[q] = bestIdx;
        outDist[q] = bestDist;
    }
}
```

#### 🗣️ 面试讲法

> "SoA 已经合并访存了，但每个查询点都要从 global 反复读 100 万个点，带宽瓶颈。我用 shared memory tiling：block 内 256 线程协作，每次把 1024 点的 tile 从 global 拷到 smem，然后全 block 从 smem 读。每个 tile 被复用 1024/256=4 次，global 访问量降 4 倍。加上 smem 延迟只有 global 的 1/20，整体从 15ms 降到 8ms。"

> **迁移场景**（面试加分项）：LLM 的 attention 里，Q/K/V 的 tile 复用就是同一个思路。把 K、V 分块拷到 smem，多个 query token 复用同一块 K/V tile。FlashAttention 的核心就是这个。

#### ❓ 自检

- tile 太大会有什么问题？→ shared memory 占满，一个 SM 能跑的 block 数（occupancy）下降，延迟无法用并行掩盖。
- `__syncthreads()` 放错位置会怎样？→ 如果有线程没到 syncthreads 就继续执行，可能读到别的线程还没写完的数据（data race），结果错误。

---

### 3.2 Warp Shuffle Reduction（寄存器级归约）

#### 🏠 生活类比：传话游戏

32 个人站成一圈，每人手里有一个数字。要找 32 个数中的最小值。

**朴素做法（smem + atomic）**：

- 每人把数字写到工位白板（shared memory）
- 一个一个比较取最小（串行 atomic min）
- 慢：32 次白板读写 + 串行

**Warp shuffle 做法**：

- 第 1 轮：每人转头看**对面那个人**的数字，取小的留下（32→16 个不同值）
- 第 2 轮：再看更近的人（16→8）
- 第 3 轮：8→4
- 第 4 轮：4→2
- 第 5 轮：2→1
- 5 轮后所有人手里都是最小值！

> 这就是**树形归约**，log2(32) = 5 步搞定 32 数归约。

#### 📖 是什么

`__shfl_xor_sync` 指令让 warp 内线程直接互看对方**寄存器**的值，不需要经过 shared memory。

```cpp
// XOR shuffle：thread i 和 thread (i ^ mask) 交换数据
float other = __shfl_xor_sync(0xffffffff, myVal, mask);
// mask=16: 0↔16, 1↔17, ... (两两配对)
// mask=8:  0↔8, 1↔9, ...
// mask=4:  0↔4, 1↔5, ...
// mask=2:  0↔2, 1↔3, ...
// mask=1:  0↔1, 2↔3, ...
```

#### 🎯 为什么快

| 方式          | 步骤     | 访问                       |
| ------------- | -------- | -------------------------- |
| smem + atomic | 串行     | smem 读写 ~20 cycles × 32 |
| warp shuffle  | 5 步并行 | 寄存器交换 ~1 cycle × 5   |

#### ⚙️ 怎么做

```cpp
// warp shuffle 归约找最小值
for (int offset = 16; offset > 0; offset >>= 1) {
    float otherDist = __shfl_xor_sync(0xffffffff, bestDist, offset);
    int otherIdx   = __shfl_xor_sync(0xffffffff, bestIdx, offset);
    if (otherDist < bestDist) {
        bestDist = otherDist;
        bestIdx = otherIdx;
    }
}
// 5 步后，warp 内所有线程的 bestDist 都是最终最小值
```

#### 🗣️ 面试讲法

> "找 KNN 最近邻时，warp 内 32 线程各算一个距离候选，要找最小值。朴素做法写回 smem + atomic min，要 32 次串行。我用 `__shfl_xor_sync` warp shuffle，32 线程直接互看寄存器，树形归约 5 步（log2(32)）完成。不经过 smem，无 bank conflict，纯寄存器操作，从 8ms 降到 5ms。"

> **迁移场景**：LLM attention 的 softmax 归一化要 reduce-sum，FlashAttention 就是 warp shuffle 做 row-wise reduction。CUDA reduce 算子（reduce-sum/max/min）全是这套。

#### ❓ 自检

- 归约超过 32 个元素怎么办？→ 先 warp 内 shuffle 归约到每 warp 一个值，再跨 warp 用 smem + atomic 归约。
- `__shfl_xor_sync` 的第一个参数 `0xffffffff` 是什么？→ mask，指定哪些线程参与，全 1 是全部参与。

---

## 第 4 章：空间索引构建

### 4.0 三故事深挖：从故事 → 硬件 → 代码 → 工程

> 阶段 6 对应深挖。三个故事其实是一条流水线：**计数（atomic）→ 定位（scan）→ 排队（sort）**。
> 这是 GPU 上一切"空间哈希 / grid / counting sort"的标准三步范式，也是粒子模拟、BVH 构建的通用套路。

#### 📕 故事 1 深挖：atomicAdd —— 取号机为什么安全

**先问一个问题**：`counter++` 明明是一行代码，为什么不安全？

**硬件根因**：一行 C++ 在 GPU 上编译成三条 SASS 指令：

```
LDG   R1, [counter]     ← load
IADD  R1, R1, 1         ← add
STG   [counter], R1     ← store
```

两个线程同时执行：A 读到 5、B 读到 5、A 写 6、B 写 6 → **丢一次更新**。总计数值随机小于等于真实值，且不可复现。

**GPU 的残酷现实**：跨 block 没有互斥锁、没有全局同步（kernel 边界是唯一全局屏障）。`atomicAdd` 是硬件提供的**唯一安全并发写**：在 **L2 cache 原子单元**执行，同地址请求在硬件队列里**排队串行**，不同地址完全并行。

**验证丢更新存在**（30 秒实验）：把 `atomicAdd(&c, 1)` 改成 `c = c + 1`，跑完把 cellCounts 求和，结果 < n。

**代码映射**：[uniform_grid.cu](../src/uniform_grid.cu) `countCellsKernel`：

```cpp
if (cellId >= 0) atomicAdd(&cellCounts[cellId], 1);   // L43
```

**工程取舍（面试考点）**——atomic 的代价模型 = 同地址串行：

| 场景                                   | 冲突程度           | 对策              |
| -------------------------------------- | ------------------ | ----------------- |
| 点云均匀（本项目，100 万点散在百万格） | 极少               | 直接 atomic，够了 |
| 点云聚集（如桌面扫描堆在几个格）       | 100 万次撞同一地址 | 必须优化          |
| 极端热点                               | 退化串行           | 换数据结构        |

优化路径（由轻到重）：
1. **warp 内预合并**：warp 里多个线程撞同一 cell 时，先用 shuffle/reduce 合并成一次请求，再发一次 atomic
2. **smem 局部计数**：block 内各 cell 先在 shared memory 计数，block 结束统一 flush 到 global——把上千次 atomic 压成几十次（counting sort 的标准套路）
3. **细化 cell**：格子更小 → 点更散 → 冲突自然少（代价：cell 数量平方增长，scan/sort 变贵）

##### 深挖：smem 局部 reduce 具体怎么做（白板方案）

**思路**：global atomic 要跑到 L2（全 GPU 共享，所有 SM 在那排队）。给每个 block 发一块**白板（shared memory）**，块内先自己记，块结束统一汇报一次。

```
无优化（现状）：
  100 万线程 ──每点 1 次──▶ L2 原子单元（全 GPU 在这排队）

smem 优化后：
  Block 0（256 线程）              Block 1（256 线程）
  ┌ smem 白板 counts ┐            ┌ smem 白板 counts ┐
  │ 256 次 smem atomic│            │ 256 次 smem atomic│  ← SM 内部解决，不出芯片
  └────────┬─────────┘            └────────┬─────────┘
           │ block 结束：每格 1 次 global atomic
           └──────────▶ L2 ◀──────────────┘
```

```cpp
__global__ void countCellsSmem(...) {
    __shared__ int smemCounts[NUM_CELLS];   // 块私有白板
    for (int i = tid; i < NUM_CELLS; i += blockDim.x)
        smemCounts[i] = 0;                   // 线程合作清零
    __syncthreads();

    if (cellId >= 0) atomicAdd(&smemCounts[cellId], 1);  // 块内计数

    __syncthreads();
    for (int i = tid; i < NUM_CELLS; i += blockDim.x)    // 块末 flush
        if (smemCounts[i] > 0)
            atomicAdd(&cellCounts[i], smemCounts[i]);    // 一次汇报总数
}
```

**为什么 smem atomic 快**：smem atomic 在 **SM 自己内部**执行，不出芯片去 L2；不同 SM 的白板互不相干 → 竞争域从"全 GPU 所有 SM"缩小到"本 block 256 人"。

**收益算账**（面试点）——把"每点一次"变成"每块每格一次"，收益正比于聚集度：

| 场景 | global atomic 次数 | smem 后 | 收益 |
|------|-------------------|---------|------|
| 均匀：256 点散在 256 个不同 cell | 256 | flush 仍 256 次（每格计数 1） | 无收益也无损失 |
| 聚集：256 点全挤同一 cell | 256 次撞同地址（串行灾难） | 256 次 smem + **1 次** global | **256 倍削减** |

**⚠️ 坑：白板放不下怎么办**——smem 白板方案假设 `NUM_CELLS × 4B ≤ 164KB`。本项目 cell 数 = 100³ = 100 万个 int = **4MB，smem 根本放不下**。生产代码的真实解法是 **warp 聚合**（不需要白板）：

```cpp
unsigned mask = __match_any_sync(0xffffffff, cellId);  // warp 内谁跟我同 cell？
int leader = __ffs(mask) - 1;                          // 组内最低 lane 当队长
if (lane == leader)
    atomicAdd(&cellCounts[cellId], __popc(mask));      // 队长一次加 N
```

32 人同 cell → 32 次 atomic 变 1 次。cub/thrust 的 histogram、生产级空间哈希都这么写。

**本项目的取舍**：点云均匀 → 热点不存在 → 白板和聚合都是过度设计，直接 global atomic。面试话术："我知道怎么治热点，但我判断当前场景不值得治"——比"会这招就到处用"高一档。

**面试讲法**：

> "grid 计数用 atomicAdd，它是 GPU 上唯一安全的并发写，硬件在 L2 原子单元把同地址请求串行化。代价是热点 cell 会退化串行，标准优化是先在 smem/warp 内做局部归约，再合并成少量 global atomic，能把 atomic 次数压一个数量级。我们项目点云均匀，实测直接 atomic 就够，但我能讲清楚聚集场景的优化路径。"

**❓ 自检**：

- `++` 为什么不安全？→ 三条指令 LDG/IADD/STG，读和写之间会被插入别人的读
- atomic 在硬件哪里执行？→ L2 原子单元，同地址排队串行，不同地址并行
- 什么时候必须优化 atomic？→ 冲突地址数 × 请求频率高（点聚集、hash 桶少）

#### 📕 故事 2 深挖：Exclusive Scan —— 串行依赖是 GPU 天敌

**为什么不能写 `for` 循环**：`starts[i] = starts[i-1] + counts[i-1]` 是 **O(N) 依赖链**，每步等上一步。GPU 有一万个线程也只能干瞪眼——**串行依赖和 bank conflict 并列 GPU 两大天敌**。

**并行 scan 思想**（Blelloch）：log₂(N) 轮，每轮 N/2 线程同时工作：

- **up-sweep**（向上收集）：相邻配对求和，像倒着的金字塔
- **down-sweep**（向下分发）：把前缀和分发回每个位置
- 总深度 O(log N)，work-efficient 版总工作量 O(N)

**知道思想即可，禁止手写**——边界、temp buffer 管理、跨 block 通信全是坑，NVIDIA 帮你写好了。

**代码映射——cub 两段式调用 pattern**（[uniform_grid.cu](../src/uniform_grid.cu) L86-93）：

```cpp
size_t tempBytes = 0;
// 第 1 次：传 nullptr，只问"需要多少临时空间"
cub::DeviceScan::ExclusiveSum(nullptr, tempBytes, cellCounts, cellStarts, n, stream);
cudaMalloc(&tempBuf, tempBytes);
// 第 2 次：真跑
cub::DeviceScan::ExclusiveSum(tempBuf, tempBytes, cellCounts, cellStarts, n, stream);
```

**这是所有 `cub::Device*` API 的通用套路**（size-query then run）。为什么这么设计：不同输入规模/数据分布需要的 temp 不同，库不替你管内存，让你自己分配复用。

**exclusive vs inclusive**（易错）：

- exclusive：`out[i] = sum(in[0..i-1])`，不含自己 → **cellStart 要这个**（起始位置 = 前面所有人总数）
- inclusive：`out[i] = sum(in[0..i])`，含自己 → 用它做 start 会差一位

**工程取舍**：本项目每次 build 都 `cudaMalloc(tempBytes)` 再 free——**教学简化**。工程正确做法：temp buffer 按最大规模**一次分配、缓存复用**。`cudaMalloc` 有隐式同步 + 分配开销，高频调用是性能大忌（尤其放在每帧调用的 build 里）。

**面试讲法**：

> "cell 起始位置用 cub 的 exclusive scan。串行 scan 是 O(N) 依赖链，GPU 上必死；cub 的 Blelloch work-efficient scan 是 O(log N) 深度 O(N) 工作量。cub 的 API 是两段式：第一次传 nullptr 查 temp 大小，第二次真跑。temp buffer 工程上要缓存复用，别每帧 malloc。"

**❓ 自检**：

- 串行 scan 为什么 GPU 上慢？→ O(N) 依赖链，每步等上一步，并行度 1
- cub 为什么调用两次？→ 第一次 size-query 算 temp 大小，第二次执行——所有 Device* API 通用
- cellStart 用 exclusive 还是 inclusive？→ exclusive，start = 前面的总数不含自己

#### 📕 故事 3 深挖：Radix Sort —— GPU 为什么抛弃比较排序

**比较排序（快排/归并）在 GPU 上的三宗罪**：

1. O(N log N) 次比较，比较次数比 radix 的线性扫描多
2. 分支发散：比较结果不一致 → warp 内走岔路（对照阶段 5 的 if 危害）
3. 不规则访存：partition 交换地址乱跳，cache line 全废

**Radix 的反击**：32-bit int key = **4 pass × 8-bit 分桶**。每个 pass 内部就是"计数 + scan + scatter"——**全是刚学过的原语**，访存规则、零分支。GPU 天然亲 radix。

**key-value pair 是精髓**（[uniform_grid.cu](../src/uniform_grid.cu) L107-127）：

```cpp
// values 初始化为 0..n-1（点的原始索引）
thrust::sequence(thrust::cuda::par.on(stream), idxIn, idxIn + cloud.n);
// 按 keys=cellIds 排序，values（索引）跟着搬家
cub::DeviceRadixSort::SortPairs(temp, tempBytes,
    cellIds, sortedCellIds,   // keys in → out
    idxIn, grid.sortedIndices, // values in → out
    n, 0, sizeof(int)*8, stream);
```

排完后 `sortedIndices` 中同 cell 的点**连续存放**。查询端：

```cpp
// 查 cell c 的所有点：sortedIndices[cellStarts[c] .. cellStarts[c]+cellCounts[c])
// 连续区间 → 阶段 4 的合并访存在这里闭环
```

**为什么这条链自洽**：count（atomic）→ scan（cub）→ sort（radix 内部又是 count+scan+scatter）——**空间索引构建 = 并行原语的接力**。这就是面试官想听的"体系化理解"。

**工程取舍**：

- `thrust::sort_by_key` 一行也能排（int key 内部也走 radix），为什么直接用 cub：省一层迭代器抽象、temp/stream 全可控；thrust 本身就是 cub 的封装
- `begin_bit=0, end_bit=32`：只按 32 位全位排序；若 key 范围小（如 cellId < 65536）可只排 16 位，**快一倍**——免费优化
- SortPairs **不支持 input==output 别名**（代码注释里标了）——in-place 需求要用双缓冲换着排

**面试讲法**：

> "按 cellId 排序用 cub radix sort。GPU 不用比较排序：O(N log N) 比较 + 分支发散 + 不规则访存三宗罪；radix 4 pass 8-bit 分桶，每 pass 就是 count+scan+scatter，全是规则访存。key-value pair 排完后同 cell 点连续，查询端切连续区间，合并访存闭环。key 范围小的时候可以截断位数白拿一倍加速。"

**❓ 自检**：

- GPU 为什么不用快排？→ 比较发散 + 不规则访存 + O(N log N) 比较
- 32-bit key 排几次？→ 4 次（每 pass 处理 8 bit）
- sort 之后哪里闭环了前面的优化？→ 同 cell 连续 → 查询合并访存（阶段 4 的布局思想在索引结构上重现）

#### 🎯 破坏-修复：本仓库埋着的真 bug（L43 vs L57）

```cpp
// countCellsKernel：越界点【不计数】
if (cellId >= 0) atomicAdd(&cellCounts[cellId], 1);

// fillCellIdsKernel：越界点 key【写 0】
cellIds[i] = (cellId >= 0) ? cellId : 0;
```

**爆雷条件**：点云中出现 grid 范围外的点（越界点数记 K > 0）。

**灾难机制**（推演一个 5 点小例子）：

```
counts（只数 in-bounds）= [1, 1, 1] → cellStarts = [0, 1, 2]
keys = [2, 1, 0, 0, 0]   ← p3、p4 是越界点，被写成 key 0
排序后 keys = [0, 0, 0, 1, 2]   ← key-0 块有 3 个点，比 counts[0] 多 2！

查询 cell 0: [0, 1) → 对（运气好）
查询 cell 1: [1, 2) → 拿到 key-0 块的尾巴（越界点！）自己的点漏了
查询 cell 2: [2, 3) → 同上，混入陌生点、丢失自己的点
```

**根因**：key-0 块实际长度 = counts[0] + K，但所有 cellStarts 都基于不含 K 的 counts → **每个 cell 的查询区间整体左移 K 位**——不只 cell 0，全部错位。

**为什么测试没炸**：本项目生成数据全在 [-100,100]³ 内，K 恒为 0 → **潜伏 bug**，换一张有离群点的真实点云立刻爆。这是"两处独立判断同一条件"的经典 bug 温床。

**修复**（一行）：

```cpp
cellIds[i] = (cellId >= 0) ? cellId : totalCells;  // 哨兵 key，排序后天然聚在数组末尾
```

越界点 key 设为 totalCells（比一切合法 cellId 大）→ 排序后聚在末尾，任何合法查询区间都碰不到，且**不干扰**合法 cell 的相对位置。

**工程教训**：

1. "同一个语义在两处代码各自判断"= bug 温床（这里两处各自处理 `cellId >= 0`）
2. 边界条件（越界输入）必须进测试用例——正常数据测一万次也抓不到这个 bug
3. 哨兵值（sentinel）是处理"异常元素参与排序"的标准手法

---

### 4.1 Atomic 并发计数

#### 🏠 生活类比：多人计数

1000 个志愿者要统计 100 万个包裹分别进了哪个仓库（cell）。每个仓库有个计数器。

**串行**：1 人点完全部 100 万件 → 100 万次操作。

**并行 + atomic**：1000 人**分包裹**，每人 1000 件（总共还是 100 万件，不是每人 100 万）。GPU 版更极端：100 万线程，每人只管自己那 1 个点。
- 看包裹、算属于哪个仓库 → **并行**（各算各的坐标，互不干扰）
- 同一仓库计数器同时被多人 +1 → **硬件强制排队，一次一个**——这才是 atomic 的"串行"，不是整个统计变串行

**检票口比喻**：音乐节 100 个入口。你走 3 号口、我走 7 号口，互不等待（不同地址的 atomic 完全并行）；同时冲向 3 号口就得排队（同一地址的 atomic 串行）。

**atomicAdd**：硬件保证"读-改-写"是原子的，不会丢更新。

#### 📖 是什么

```cpp
int old = atomicAdd(&counter, 1);
// 硬件保证这一步不可被打断：读 counter、+1、写回，一气呵成
```

#### 🎯 为什么需要

构建 uniform grid 第一步：每个点算出它属于哪个 cell，给那个 cell 的计数器 +1。100 万点同时写计数器，不用 atomic 就会丢更新（两个线程同时读到 5，都写 6，实际应该是 7）。

#### ⚙️ 代价

atomic 是 GPU 上唯一安全的并发写方式，但**同一地址的 atomic 是串行的**。如果 100 万个点都落在同一 cell，100 万次 atomicAdd 全串行——灾难。

**优化**：先在 shared memory / register 内做局部 reduce，再 atomic 写 global（减少 global atomic 次数）。

#### 🗣️ 面试讲法

> "uniform grid 构建第一步是 atomic 计数每个 cell 的点数。atomicAdd 是 GPU 上唯一安全的并发写方式，但同一地址的 atomic 是串行的。如果点分布不均，热门 cell 的 atomic 会退化成串行。我先用 shared memory 做局部 reduce，再 atomic 写 global，减少 global atomic 次数。这是 GPU 工程的标准优化手法。"

---

### 4.2 cub Sort/Scan（官方优化原语）

#### 🏠 生活类比：分组排队

100 万人按"属于哪个仓库"排队。同仓库的人要挨着站，每个仓库的起始位置要知道。

**三步构建 uniform grid**：

1. **计数**：每个 cell 多少点（atomic，上面讲了）
2. **前缀和**（exclusive scan）：算每个 cell 在排序后数组中的起始位置
3. **排序**：按 cellId 排序，同 cell 的点挨着存

```
cellId:  [3, 1, 3, 0, 1, 3]   → 排序后: [0, 1, 1, 3, 3, 3]
                                       ↑  ↑     ↑
cellStart(cell 0) = 0               ↗  |     |
cellStart(cell 1) = 1    ────────────┘     |
cellStart(cell 3) = 3    ───────────────────┘
```

#### 📖 是什么

- **Exclusive Scan（前缀和）**：`out[i] = sum(in[0..i-1])`
  ```
  in:  [3, 1, 1, 2]
  out: [0, 3, 4, 5]   // out[i] = 前面所有元素之和
  ```
- **Radix Sort（基数排序）**：按 key 分桶排序

NVIDIA 官方提供了 `cub` 库，里面是**极致优化过的 GPU 原语**，比手写快得多。

#### ⚙️ 怎么用 cub

```cpp
#include <cub/cub.cuh>

// 1. Exclusive scan：从 cellCounts 算 cellStarts
cub::DeviceScan::ExclusiveSum(
    d_tempStorage, tempStorageBytes,
    cellCounts, cellStarts, numCells, stream
);

// 2. Radix sort：按 cellId 排序点
cub::DeviceRadixSort::SortPairs(
    d_tempStorage, tempStorageBytes,
    cellIds,       // key（要排序的）
    pointIndices,  // value（跟着 key 排序）
    numPoints, 0, 32, stream  // 按 32 位 key 排
);
```

#### 🗣️ 面试讲法

> "grid 构建三步：atomic 计数每个 cell 点数，cub exclusive sum 算 cell 起始位置，cub radix sort 把点按 cellId 排序。我不手写 scan 和 sort，因为 cub 是 NVIDIA 官方优化的原语，用了 SSE 级的并行 scan 算法（Blelloch work-efficient scan），比手写快且正确。1M 点 grid 构建约 3ms。"

> **工程常识**：不要重新造轮子。scan/sort/reduce 这些基础原语用 cub，自己写大概率不如官方实现。但要知道原理（scan 是 work-efficient parallel prefix sum）。

#### ❓ 自检

- 为什么要 sort？不 sort 直接用 cellStart 查不行吗？→ 不 sort 的话，同一 cell 的点散落在数组各处，cache 不友好。sort 后同 cell 点连续，内存访问高效。
- cub 为什么快？→ 用了 work-efficient scan 算法（O(N) work + O(log N) depth），以及针对 GPU 的优化（shared memory tiling、warp shuffle）。

---

## 第 5 章：算子协作优化

### 5.1 Kernel Fusion（核函数融合）

#### 🏠 生活类比：流水线合并工序

工厂做零件：工序 A（算距离）→ 工序 B（取最小）→ 工序 C（写回）。

**不融合**：A 把结果存到仓库（global），B 从仓库读，算完存仓库，C 再读再写。三次仓库读写。

**融合**：一个工人一口气做完 A→B→C，中间结果放自己口袋（寄存器），只读一次、写一次仓库。

#### 📖 是什么

把多个串联的 kernel 融合成一个 kernel，中间结果留在寄存器，不写回 global memory。

#### 🎯 为什么有效

| 操作               | 延迟        |
| ------------------ | ----------- |
| global memory 读写 | ~400 cycles |
| 寄存器访问         | ~1 cycle    |
| kernel launch      | ~5 us       |

融合后：

1. 省掉 global 读写（400x 差异）
2. 省掉 kernel launch 开销

#### ⚙️ ESDF 多 pass 融合

```cpp
// 不融合：3 个 kernel
computeDistKernel<<<...>>>();   // 算距离，写 global
findMinKernel<<<...>>>();        // 读 global，取最小，写 global
writeBackKernel<<<...>>>();     // 读 global，写 global

// 融合：1 个 kernel
__global__ void fusedEsdfPass(SeedCode* seeds, float* dists, ...) {
    int cell = blockIdx.x * blockDim.x + threadIdx.x;
  
    // 中间结果全在寄存器
    float bestDist = 1e30f;
    SeedCode bestSeed = -1;
  
    for (int dz = -1; dz <= 1; ++dz)
    for (int dy = -1; dy <= 1; ++dy)
    for (int dx = -1; dx <= 1; ++dx) {
        // 算距离（寄存器）
        float d = seedDistance(...);
        // 取最小（寄存器）
        if (d < bestDist) { bestDist = d; bestSeed = ...; }
    }
    // 只写一次 global
    seeds[cell] = bestSeed;
    dists[cell] = bestDist;
}
```

#### 🗣️ 面试讲法

> "ESDF 每个 pass 本来是算距离 + 取最小 + 写回三个 kernel，每次都读写 global，~400 cycles 一次。我融合成一个 kernel，中间结果留寄存器（~1 cycle），只读写一次 global。从 8ms 降到 5ms。**这就是为什么 LLM 推理要做算子融合——把 attention + softmax + MLP 融合，省掉大量 global 读写**。"

#### ❓ 自检

- 什么情况下不该融合？→ 融合后寄存器压力过大导致 occupancy 下降；或 kernel 之间有复用关系，融合后其他场景没法单独调用。
- 为什么不能全部融合成一个超大 kernel？→ 寄存器数量有限（每线程 255 个），寄存器太多 occupancy 骤降。`__launch_bounds__` 可以显式限制。

---

### 5.2 Jump Flooding 并行算法

#### 🏠 生活类比：烽火台传信

64×64×64 个格子（城市），每个格子要知道最近的"障碍格"（医院）在哪。

**暴力**：每个格子挨个查所有医院 → 64³ × N 医院 = 天文数字。

**Jump Flooding（烽火台）**：

- 初始：只有医院格子知道自己在哪（有种子）
- 第 1 轮：每个格子问 26 个邻居中**距离 32 格**的，谁有种子？有就抄来
- 第 2 轮：问距离 16 格的邻居...
- 第 3 轮：距离 8 格...
- ...
- 第 6 轮：距离 1 格
- log2(64) = 6 轮后，所有格子都找到了最近医院

#### 📖 是什么

Jump Flooding 算法：从种子点（障碍）开始，多 pass 跳跃传播，每 pass 跳跃距离减半，log(N) pass 收敛。

#### 🎯 为什么比暴力快

- 暴力：O(V × N)，V=体素数，N=障碍数
- Jump Flooding：O(V × 26 × log(N))，26 邻居 × log(N) pass

64³ 体素、1 万障碍：

- 暴力：64³ × 10000 = 26 亿次
- Jump Flooding：64³ × 26 × 14 ≈ 1.5 亿次

#### ⚙️ 多 pass 跳跃

```cpp
// 初始：障碍点设为自己的种子
initSeedsKernel<<<...>>>();  // seeds[cell] = cell (if obstacle)

// 多 pass 跳跃传播
for (int jump = GRID_SIZE / 2; jump >= 1; jump >>= 1) {
    jumpFloodPassKernel<<<grid, block>>>(
        seeds, dists, gridSize, voxelSize, jump
    );
}
```

每个 pass 内每个格子查 26 邻居（3×3×3 立方减自身），取距离最近的种子。

#### 🗣️ 面试讲法

> "ESDF 用 Jump Flooding 算法并行构建。暴力是 O(V×N)——每个体素查所有障碍，太贵。Jump Flooding 从障碍点开始多 pass 跳跃传播，跳跃距离从 N/2 减半到 1，log(N) pass 收敛。每个 pass 内每个体素查 26 邻居更新最近障碍。GPU 上 V 个体素同时算，64³ 体素从 CPU 暴力 500ms 优化到 8ms。"

> **为什么是 26 邻居？** 3D 体素的 3×3×3 立方邻域减去自身 = 27-1 = 26。2D 就是 8 邻居（3×3-1）。

#### ❓ 自检

- 障碍极稀疏时 Jump Flooding 效果如何？→ 大多数格子初始没种子，前几 pass 白跑。可以加"有种子才扩散"的 early-out。
- 为什么跳跃距离减半？→ 数学证明：每次减半能在 log(N) pass 内让信息传遍整个网格，类比二分搜索。

---

### 5.3 CUDA Graph（流程捕获）

#### 🏠 生活类比：一键播放 vs 逐条指令

**不用 Graph**：
你每次都要给军团下达 10 条指令："A 去搬砖，B 去和泥，C 去砌墙..."。每条指令传达有延迟（kernel launch ~5us），10 条 = 50us 浪费。

**用 Graph**：
你把 10 条指令录成磁带（cudaGraphCapture），之后每次只要按播放键（cudaGraphLaunch），一次搞定。

#### 📖 是什么

用 `cudaStreamBeginCapture` / `cudaStreamEndCapture` 把 stream 内的 kernel 序列录制成 graph，之后每次 `cudaGraphLaunch` 一次性提交整个序列。

#### 🎯 为什么快

1. **省 launch 开销**：10 个 kernel × 5us = 50us → 1 次 launch
2. **driver 提前规划**：GPU driver 看到 graph 全貌，可以提前优化调度

#### ⚙️ 怎么用

```cpp
cudaStream_t stream;
cudaStreamCreate(&stream);

// 1. 开始捕获
cudaStreamBeginCapture(stream, cudaStreamCaptureModeGlobal);

// 2. 正常 launch kernel（不会执行，会被录制）
for (int jump = GRID_SIZE/2; jump >= 1; jump >>= 1) {
    jumpFloodPassKernel<<<grid, block, 0, stream>>>(seeds, dists, ...);
}

// 3. 结束捕获，得到 graph
cudaGraph_t graph;
cudaStreamEndCapture(stream, &graph);

// 4. 实例化为可执行图
cudaGraphExec_t graphExec;
cudaGraphInstantiate(&graphExec, graph, 0);

// 5. 之后每次只要一次 launch
cudaGraphLaunch(graphExec, stream);
```

#### 🗣️ 面试讲法

> "ESDF 多 pass 流程固定（6 pass），每次启动 kernel 有 ~5us launch 开销。我用 CUDA Graph 把整个流程捕获成图，之后每次只要 `cudaGraphLaunch` 一次提交。从 5ms 降到 3ms。**这就是为什么 LLM 推理引擎（vLLM、TensorRT-LLM）都用 graph——固定推理流程一次提交，省掉 launch 开销**。"

#### ❓ 自检

- 什么情况下不能用 Graph？→ 流程不固定（动态 shape、动态 pass 数、条件分支）。Graph 要求执行序列在捕获时就确定。
- Graph 捕获有开销吗？→ 有，捕获和实例化是一次性开销。适合多次执行的固定流程，单次执行不值得。

---

## 第 6 章：工程质量

### 6.1 Occupancy 调优

#### 🏠 生活类比：工厂排班

一个车间（SM）可以同时容纳多个班组（block）在跑。班组越多，一个组等数据时另一个组可以继续算，延迟被掩盖。

**Occupancy = 活跃 warp 数 / SM 最大 warp 数**

影响因子：

1. **寄存器用量**：每个线程用的寄存器越多，一个 SM 能塞的线程越少
2. **shared memory 用量**：同理
3. **block size**：block 内线程数

#### 📖 是什么

GPU 的每个 SM（流式多处理器）有固定的寄存器和 shared memory 资源。这些资源被 block 内的线程平分。

```
SM 资源：65536 寄存器 + 164KB shared memory
如果每线程用 64 寄存器：65536/64 = 1024 线程 → 32 个 warp
如果每线程用 128 寄存器：65536/128 = 512 线程 → 16 个 warp（occupancy 减半）
```

#### ⚙️ 调优工具

```cpp
// 显式限制寄存器用量
__launch_bounds__(256, 4)  // 每 block 256 线程，每 SM 至少 4 block
__global__ void myKernel(...) { ... }

// 验证 occupancy
int maxBlocks;
cudaOccupancyMaxActiveBlocksPerMultiprocessor(
    &maxBlocks, myKernel, blockSize, dynamicSmem
);
```

#### 🗣️ 面试讲法

> "occupancy 是 SM 上活跃 warp 占最大 warp 的比例。影响因子是寄存器用量、smem 用量、block size。寄存器用太多 occupancy 低，延迟无法用并行掩盖。我用 `__launch_bounds__` 显式限制寄存器用量，用 `cudaOccupancyMaxActiveBlocksPerMultiprocessor` 验证。但 occupancy 不是越高越好——有时低 occupancy 但每个 warp 算得更快（更多寄存器做循环展开），总性能更好。要 profile 实测。"

#### ❓ 自检

- occupancy 100% 就一定最快吗？→ 不一定。高 occupancy 意味着每线程寄存器少，可能要多访存。低 occupancy + 更多寄存器 + 循环展开有时更快。要 ncu 实测。
- 怎么看当前 occupancy？→ `ncu --metrics achieved_occupancy` 或 Nsight Compute 的 Occupancy 页面。

---

### 6.2 数值稳定性（Kahan Summation）

#### 🏠 生活类比：零钱罐

你每天存 0.001 元到银行，存 100 万天。银行用 float 存（精度 7 位有效数字）。

```
余额：1000000.0
+0.001 → 1000000.001 → float 存不下 → 存成 1000000.0 → 小数丢了！
```

存 100 万次，余额还是 1000000.0，丢了 1000 元。

**Kahan 补偿**：用一个"零钱罐"变量记住被丢的小数部分，攒够了再补一次。

#### 📖 是什么

```cpp
float sum = 0, c = 0;  // c = 补偿变量
for (int i = 0; i < N; ++i) {
    float y = val[i] - c;       // 减掉之前丢的
    float t = sum + y;         // 加新值
    c = (t - sum) - y;         // 算出这次丢了多少
    sum = t;
}
// 1M 累加：朴素误差 1e-3，Kahan 误差 1e-7
```

#### 🗣️ 面试讲法

> "大点云浮点累加会有精度问题——float 有效位 7 位，1e10 + 1e-5 = 1e10，小数被吞。我用 Kahan summation 补偿被吞的部分，关键节点用 `isfinite()` 检查 NaN/inf。单测覆盖空点云、重复点、共线点退化场景，与 CPU baseline 容差 1e-4 对齐。"

---

### 6.3 Benchmark 自动化（CUDA Event 计时）

#### 📖 是什么

用 CUDA Event 精确计时 kernel 执行时间（比 CPU 端 gettimeofday 精确，因为包含 GPU 异步执行等待）。

```cpp
cudaEvent_t start, stop;
cudaEventCreate(&start);
cudaEventCreate(&stop);

cudaEventRecord(start, stream);
myKernel<<<grid, block, 0, stream>>>(...);
cudaEventRecord(stop, stream);
cudaEventSynchronize(stop);  // 等 stop 被记录

float ms;
cudaEventElapsedTime(&ms, start, stop);
printf("Kernel time: %.3f ms\n", ms);
```

#### 🗣️ 面试讲法

> "计时用 CUDA Event，不是 CPU 端 gettimeofday。因为 kernel 是异步的，CPU 端计时会包含 launch 开销但不包含实际 GPU 执行时间。cudaEventRecord 在 GPU 端打时间戳，cudaEventElapsedTime 算两个 event 之间的间隔，精确到 us。"

---

## 全局总结：4 个矛盾 → 16 个优化点

| 矛盾     | 优化点               | 一句话根因                                            |
| -------- | -------------------- | ----------------------------------------------------- |
| 数据搬运 | Pinned memory        | pageable 要中转拷贝，pinned 让 DMA 直连               |
| 数据搬运 | Async copy + stream  | 同步搬运让 CPU 和 GPU 都等，异步让搬运计算重叠        |
| 内存布局 | AoS → SoA           | GPU 一次 128B 事务，AoS 地址散乱，SoA 连续            |
| 内存布局 | __restrict__   | 告诉编译器无别名，允许 load 重排到 store 前           |
| 并行调度 | Shared memory tiling | global 延迟 400 cycles，smem 20 cycles，复用 N 倍     |
| 并行调度 | Bank conflict 规避   | smem 分 32 bank，撞 bank 串行 32 倍                   |
| 并行调度 | Warp shuffle         | 寄存器级数据交换，5 步归约 32 数，无 smem 读写        |
| 空间索引 | Atomic counter       | GPU 上唯一安全并发写，同地址串行                      |
| 空间索引 | cub scan/sort        | 官方 work-efficient 原语，别造轮子                    |
| 算子协作 | Jump flooding        | log(N) pass 传播，O(V×26×logN) vs 暴力 O(V×N)      |
| 算子协作 | Kernel fusion        | global 400 cycles vs 寄存器 1 cycle，中间结果寄存器化 |
| 算子协作 | CUDA Graph           | 多 pass 固定流程一次提交，省 launch 开销              |
| 工程质量 | Occupancy 调优       | 寄存器/smem 用量影响活跃 warp 数，影响延迟掩盖        |
| 工程质量 | 数值稳定性           | Kahan 补偿浮点累加丢的小数                            |
| 工程质量 | Benchmark 自动化     | CUDA Event 精确计时 + 表格输出对比                    |

---

## 面试万能答题框架

遇到任何 CUDA 优化问题，按这个框架答：

```
1. 问题是什么 → "这个场景的瓶颈是 [global memory 带宽 / launch 开销 / 精度 / ...]"
2. 硬件根因 → "因为 GPU 的 [global 延迟 400 cycles / 一次 128B 事务 / warp 32 线程锁步 / ...]"
3. 我的方案 → "我用 [pinned memory / SoA / smem tiling / kernel fusion / ...]"
4. 量化数据 → "从 X ms 降到 Y ms，Z 倍提升"
5. 为什么有效 → "因为 [DMA 直连 / 合并访存 / 复用 N 倍 / 寄存器级操作]"
6. 迁移场景 → "这个技术可以迁移到 [LLM 推理 / attention / 矩阵乘法]"
```

**记住**：面试官最看重的是第 2 步"硬件根因"和第 5 步"为什么有效"。能答出这两步，说明你真懂，不是背的。
