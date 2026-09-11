# GPU 加速 3D 点云最近邻查询 + ESDF 距离场构建工具｜设计规格

> 日期：2026-08-05
> 状态：设计待审
> 目标：构建一个 CUDA 项目，覆盖工程上几乎所有常见 CUDA 优化考点，作为简历缺口补充 + 面试反复可讲素材

---

## 1. 目标与非目标

### 1.1 目标
- 实现一个 GPU 加速的 3D 点云空间查询工具：**批量最近邻搜索 (KNN)** + **ESDF 距离场构建**
- 在每一模块嵌入一个 CUDA 工程优化考点，量化性能提升
- 生成可对比的性能 benchmark 报告
- 输出面试讲稿，每个优化点对应一套问答模板
- 代码可跑可读，工程化组织（分层 + 单测 + benchmark）

### 1.2 非目标（YAGNI）
- 不做 ROS 集成
- 不做实时数据流（用合成点云）
- 不做完整 PCD/PLY 解析器
- 不做多 GPU 分布式
- 不做 RTX 光追
- 不做 GUI 可视化（如有时间再加）

---

## 2. 架构总览

```
┌─────────────────────────────────────────────┐
│  main.cpp  (入口：跑全套对比)                │
└──────────┬──────────────────────────────────┘
           │
           ├─→ PointCloudGenerator      生成合成点云（高斯团/球面）
           │
           ├─→ CpuBaseline              CPU 暴力 KNN + 暴力 ESDF（对照基线）
           │
           ├─→ GpuBaselineAoS           GPU 暴力 AoS（cache miss 严重）
           │
           ├─→ GpuOptimizedSoA         SoA + 内存对齐 + 合并访存
           │
           ├─→ UniformGridGpu          哈希网格构建（atomic + sort + scan）
           │
           ├─→ KnnSearchKernel         GPU 批量最近邻（smem tiling + warp shuffle）
           │
           ├─→ EsdfJumpFloodKernel     GPU 并行 ESDF（多 pass + kernel fusion）
           │
           ├─→ BenchmarkRunner         计时 + 性能报告
           │
           └─→ UnitTests               正确性 + 数值稳定性
```

---

## 3. 模块职责与 CUDA 考点映射

### 3.1 点云生成模块 `pointcloud.h/cpp`
- **职责**：生成合成 3D 点云（高斯团、球面、噪声点）
- **CUDA 考点**：**Pinned memory + async copy**
  - 用 `cudaMallocHost` 分配主机 pinned 内存
  - `cudaMemcpyAsync` + CUDA stream 异步拷贝到 GPU
  - 面试讲法：CPU→GPU 数据传输优化，pinned 比 pageable 快 2~5 倍

### 3.2 CPU Baseline `baseline_cpu.h/cpp`
- **职责**：暴力 KNN + 暴力 ESDF，作为正确性参考 + 性能对照基线
- **CUDA 考点**：无（基线）

### 3.3 GPU AoS Baseline `gpu_baseline_aos.cu`
- **职责**：用 AoS 布局跑暴力 KNN，cache miss 严重
- **CUDA 考点**：**AoS 布局 + cache miss 实测**
  - `struct Point { float x, y, z; }` 数组
  - 面试讲法：AoS 访问单字段时浪费 cache 行，实测带宽利用率 30%

### 3.4 GPU SoA 优化 `gpu_optimized_soa.cu`
- **职责**：重构为 SoA + 32B 对齐，做合并访存
- **CUDA 考点**：**SoA + memory alignment + coalesced access**
  - `float* xs, ys, zs` 分别连续
  - `alignas(32)` 保证 cache 行对齐
  - warp 内线程访问连续地址，合并访存带宽利用率 60%+
  - 面试讲法：数据布局优化是 CUDA 工程第一波提速手段

### 3.5 Uniform Grid 哈希 `uniform_grid.cu`
- **职责**：把点云按体素网格分桶，构建 hash grid 加速邻域查询
- **CUDA 考点**：
  - **Atomic counter**：每个点原子地累加所属桶的计数
  - **Radix sort + scan**：用 cub 库做点云按桶 ID 排序、prefix sum
  - **Warp divergence 处理**：hash 不均导致分支，用 predication
  - 面试讲法：空间索引 GPU 构建的全套工程难点

### 3.6 KNN 搜索 Kernel `knn_search_kernel.cu`
- **职责**：GPU 并行批量查询 N 个查询点的 K 近邻
- **CUDA 考点**：
  - **Shared memory tiling**：把点云分块载入 smem 复用
  - **Warp shuffle reduction**：K 个候选距离用 `__shfl_sync` 归约
  - **Bank conflict 规避**：smem 访问模式设计，padding 规避 32-bank 冲突
  - **Kernel fusion**：距离计算 + 比较融合，省一次 global mem 写回
  - 面试讲法：GPU 加速批量查询，smem tiling + warp shuffle 是核心

### 3.7 ESDF Jump Flooding `esdf_jump_flood.cu`
- **职责**：用跳跃洪泛算法 GPU 并行构建 ESDF 距离场
- **CUDA 考点**：
  - **多 pass 迭代**：jump flooding 从障碍点开始多 pass 跳跃传播
  - **Kernel fusion**：相邻 pass 融合，减少 global mem 读写
  - **CUDA streams + events**：pass 之间用 stream pipeline
  - **CUDA Graph**：固定流程捕获为 graph，减少 launch 开销
  - **Occupancy 调优**：寄存器/smem 占用率分析
  - 面试讲法：经典 GPU 并行算法 + kernel 间优化

### 3.8 数值稳定性 `numerical_stability.cu`
- **职责**：浮点累加防 NaN/inf
- **CUDA 考点**：**Kahan summation + 边界检查**
  - 距离累加用 Kahan 防误差累积
  - 关键节点 `isfinite()` 检查
  - 面试讲法：浮点迭代防 NaN 的工程实践

### 3.9 Benchmark `benchmark.h/cpp`
- **职责**：自动跑全部模块对比，生成性能表格
- **CUDA 考点**：**CUDA Event 计时 + 报告生成**
  - `cudaEventRecord` + `cudaEventSynchronize` 精确计时
  - 多档对比表格输出（CPU / AoS / SoA / 全优化）
  - 面试讲法：性能优化的量化证据

### 3.10 单元测试 `tests/test_knn_esdf.cpp`
- **职责**：验证 GPU 实现与 CPU baseline 一致，覆盖边界 case
- **CUDA 考点**：**GPU 单测模式 + 数值边界**
  - 零向量、共线点、空网格、重复点
  - 容差 `1e-4` 比对

---

## 4. 数据流

```
生成点云 (pinned host)
   │
   │ cudaMemcpyAsync (stream A)
   ▼
GPU SoA 缓冲 (device)
   │
   ├──→ Uniform Grid 构建 ──┐
   │                         │
   ▼                         ▼
KNN 查询 (smem tiling)   ESDF 构建 (jump flood, stream B)
   │                         │
   ▼                         ▼
距离结果 (device)       距离场 (device)
   │                         │
   └────→ 单测 + benchmark ──┘
```

---

## 5. 项目结构

```
project_expe/cuda_project/
├── README.md                   # 项目说明 + 面试讲法总览
├── docs/
│   ├── design.md               # 本设计文档
│   ├── interview_talk.md       # 面试讲稿（每模块对应问答模板）
│   └── benchmark_report.md     # 性能数据 + 优化前后对比表
├── src/
│   ├── pointcloud.h/cpp        # 点云生成 + AoS/SoA 双布局
│   ├── baseline_cpu.h/cpp      # CPU 暴力 baseline
│   ├── gpu_baseline_aos.cu      # GPU AoS baseline
│   ├── gpu_optimized_soa.cu    # SoA + 对齐 + 合并访存
│   ├── uniform_grid.cu          # 哈希网格构建
│   ├── knn_search_kernel.cu    # GPU 批量 KNN
│   ├── esdf_jump_flood.cu       # ESDF 跳跃洪泛
│   ├── numerical_stability.cu   # 数值稳定性工具
│   ├── benchmark.h/cpp          # 计时 + 报告生成
│   └── main.cpp                 # 入口：跑全套对比
├── tests/
│   └── test_knn_esdf.cpp        # 单元测试
├── scripts/
│   ├── build.sh                 # 编译脚本
│   └── run_benchmark.sh         # 一键跑性能对比
└── CMakeLists.txt               # CMake 构建
```

---

## 6. 关键设计决策

### 6.1 为什么选 KNN + ESDF 而不是只做一个
- KNN 涵盖：smem tiling、warp shuffle、atomic、sort/scan
- ESDF 涵盖：多 pass 算法、kernel fusion、streams、CUDA Graph、occupancy
- 两者互补，覆盖的 CUDA 考点几乎不重叠，一个项目讲两套故事

### 6.2 为什么用合成点云而不是真实 PCD
- 合成数据可控制规模（10K / 1M / 10M），方便 benchmark
- 避免 PCD 解析器代码膨胀（YAGNI）
- 面试时业务无关，可对应激光雷达/医学/通用场景

### 6.3 为什么用 cub 而不是手写 sort/scan
- cub 是 NVIDIA 官方库，工业标准
- 手写 sort/scan 是另一种工程能力，但偏离主题（考点是"会用工具"）
- 面试讲法：知道何时用现成库、何时自己写

### 6.4 为什么多 baseline 对照
- 性能优化的说服力来自量化对比
- "我从 50ms 优化到 3ms" vs "我做了优化"，前者更强

---

## 7. 性能目标（基线 + 优化）

| 指标 | CPU baseline | GPU AoS | GPU SoA | GPU 全优化 |
|------|------------|---------|---------|----------|
| KNN 查询 1M 点 × K=8 | ~2000 ms | ~50 ms | ~15 ms | ~3 ms |
| ESDF 构建 64³ 体素 | ~500 ms | ~80 ms | ~30 ms | ~8 ms |
| 显存带宽利用率 | - | 30% | 60% | 85% |

> 注：具体数字会随实现和硬件变，但**多档对比**是面试讲故事的关键

---

## 8. 适配面试场景

| 岗位类型 | 重点讲哪几个模块 |
|---------|---------------|
| 运动规划 C++ | ESDF、Uniform Grid、cache 优化 |
| 通用 CUDA 工程 | 全部模块 |
| 大模型部署 | 访存优化、kernel fusion、CUDA Graph（迁移到 LLM 算子） |
| 自动驾驶 | 点云处理、并行加速 |
| 医学影像 | 体数据 + 三维并行 |

---

## 9. 风险与缓解

| 风险 | 缓解 |
|------|------|
| 体量过大无法完成 | 先做最小可跑版本（baseline + SoA + KNN），后续迭代加 ESDF |
| 性能数字不达标 | 各模块独立 benchmark，逐步优化 |
| CUDA 环境差异 | 用 CMake + FindCUDA，兼容 CUDA 11/12 |
| 面试讲不清 | interview_talk.md 强制写每模块问答模板 |

---

## 10. 交付物清单

- [ ] `src/` 完整源码（C++ + CUDA）
- [ ] `tests/` 单元测试通过
- [ ] `docs/design.md` 本设计文档
- [ ] `docs/interview_talk.md` 面试讲稿
- [ ] `docs/benchmark_report.md` 性能报告（实际数据）
- [ ] `README.md` 项目说明
- [ ] `CMakeLists.txt` + `scripts/build.sh` 可一键编译

---

## 11. 下一步

设计批准后，调用 `writing-plans` skill 生成详细实施计划，分阶段实施：

1. 阶段 1：搭建工程骨架 + CPU baseline + AoS GPU baseline（可跑）
2. 阶段 2：SoA 优化 + Uniform Grid 构建
3. 阶段 3：KNN kernel（smem tiling + warp shuffle）
4. 阶段 4：ESDF jump flooding + kernel fusion + CUDA Graph
5. 阶段 5：benchmark + 单测 + 面试讲稿
