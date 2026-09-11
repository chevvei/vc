
好问题。这两个概念是 GPU 内存层次的进阶知识，用故事讲清楚。

---

## Cache Line（缓存行）= 货架最小取货单位

### 📖 故事：批发市场的最小装箱单位

你去批发市场买苹果。老板说："**最少拿一整箱（24 个）**，不拆卖。"

你只想买 3 个苹果，但必须拿 1 箱 24 个。剩下 21 个你拿走或扔掉，反正老板只按箱卖。

**GPU 也是这样**：global memory（显存）到 cache 的最小搬运单位是 **128 字节一箱**（一个 cache line），不拆卖。

### 🎯 GPU Cache Line 详解

GPU 内存层次：

```
寄存器 ← L1 cache ← L2 cache ← global memory
         ↑              ↑
         128B 粒度       128B/32B 粒度
```

当 GPU 要读 1 个 float（4 字节）时，**实际上会把它周围 128 字节一起搬进 cache**。这 128 字节 = 32 个 float = 一个 cache line。

### 为什么有 cache line

**硬件原因**：DRAM 访问有固定开销（寻址、激活行、突发传输）。一次读 4B 和一次读 128B 耗时几乎一样。**搬运"一箱"比搬运"一个"效率高 32 倍**。

### AoS 在 cache line 下的表现

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

### SoA 在 cache line 下的表现

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

### 关键洞察

**cache line 是 GPU 优化的物理基础**。所有"合并访存"概念本质都是：

- **让 warp 32 线程访问的数据落在同一 cache line** → 1 次事务
- **让访问跨多个 cache line** → 多次事务，带宽浪费

SoA 天然让"32 个 x"连续在 128B 内 = 1 个 cache line = 1 次事务。这是物理上的最优解。

---

## Prefetch（预取）= 猜你要买啥，提前装箱

### 📖 故事：聪明的批发商

老板发现你每周都买苹果。他学会**在你下周来之前，提前把下一箱苹果从冷库搬到前台**。你到的时候苹果已经在柜台，不用等冷库取货。

这就是 prefetch——**在你显式请求之前，硬件预测你要访问的内存，提前搬进 cache**。

### 🎯 GPU 的 prefetch 机制

GPU 有几种自动 prefetch：

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

### 为什么预取对 SoA 更有效

**SoA 顺序访问**：xs[0], xs[1], xs[2], ... → 完美顺序，prefetch 命中率高
**AoS 跨步访问**：cloud[0].x, cloud[1].x（间隔 12B）→ 跨步访问，prefetch 命中率低

GPU 的 L2 cache 和内存控制器**对顺序访问做激进 prefetch**。SoA 布局正好让数据"顺序可预取"。

---

## L2 Cache 的全局复用

### 📖 故事：仓库共享货架

L2 cache 是 GPU 上所有 SM 共享的"中间层货架"。global memory 是远在天边的大仓。

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

---

## 完整延迟表（背下来）

```
寄存器 Register        ~1 cycle      每线程私有
Shared Memory         ~20 cycles    SM 内共享
L1 Cache              ~30 cycles    SM 内自动
L2 Cache              ~200 cycles   全 GPU 共享
Global Memory         ~400-800      显存，最远
```

**所有 CUDA 优化的本质**：让数据尽量留在靠左边的层。

---

## 面试讲法

> GPU 内存访问有 cache line 粒度，128B 一行。当 warp 32 线程同时读 1 个 float 时，GPU 实际上搬一整 cache line（32 float）到 L2。SoA 让 32 个 x 连续 128B，刚好 1 个 cache line，32 线程全命中。AoS 跨度 384B，要 3 个 cache line。
>
> 此外 GPU 内存控制器对顺序访问做 prefetch 预取。SoA 的连续访问让预取命中率高，下一 cache line 一定有用。AoS 跨步访问让 prefetch 失效，命中率低。
>
> **本质都是让数据布局匹配硬件访问粒度**——cache line 128B + 顺序访问预取，这两个硬件事实决定了 SoA 比 AoS 快。

> **迁移**：LLM 推理时 KV Cache 用 SoA 布局，让 attention 访问 K 时连续，prefetch 命中率高。FlashAttention 的 tile 也是按 cache line 对齐设计的。

## ❓ 自检

- cache line 多大？→ 128 字节（32 个 float）
- 为什么 GPU 不"拆卖"4 字节？→ DRAM 寻址开销固定，搬 4B 和搬 128B 耗时几乎一样
- SoA 为什么 prefetch 更准？→ 顺序访问，下一 cache line 必有用
- AoS 同一 cache line 内的 10 个点命中，为什么还慢？→ warp 要 32 个，跨 3 个 cache line
