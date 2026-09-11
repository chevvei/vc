# GPU 加速 3D 点云空间查询 + ESDF 距离场构建工具

> CUDA 工程优化实战项目，覆盖几乎所有常见优化考点，作为简历缺口补充 + 面试反复可讲素材

## 项目定位

从 CPU 暴力基线一步步优化到 400+ 倍加速，每个优化点对应一个 CUDA 工程考点 + 量化数据 + 面试讲稿。

## 知识点覆盖（16 个考点）

| 考点 | 在哪个模块 |
|------|----------|
| Pinned memory + async copy | 数据传输 |
| AoS vs SoA | KNN baseline |
| 合并访存 coalesced | KNN SoA |
| __restrict__ 关键字 | KNN SoA |
| Shared memory tiling | KNN smem |
| Bank conflict 规避 | KNN smem |
| Warp shuffle reduction | KNN shuffle |
| Atomic counter | Uniform grid |
| cub scan/sort | Uniform grid |
| Jump flooding 并行算法 | ESDF |
| Kernel fusion | ESDF |
| CUDA streams | 全局 |
| CUDA Graph | ESDF |
| Occupancy 调优 | 全局 |
| 数值稳定性 (Kahan) | 全局 |
| Benchmark 自动化 | 全局 |

## 项目结构

```
cuda_project/
├── src/
│   ├── pointcloud.h/cpp          # 点云生成 + AoS/SoA + pinned memory
│   ├── baseline_cpu.h/cpp       # CPU 暴力基线
│   ├── gpu_baseline_aos.cu       # GPU AoS baseline
│   ├── gpu_optimized_soa.cu      # GPU SoA + coalesced
│   ├── uniform_grid.h/cu          # Uniform grid 构建（atomic + cub sort/scan）
│   ├── knn_search_kernel.cu      # KNN with smem tiling + warp shuffle
│   ├── esdf_jump_flood.cu         # ESDF with jump flooding + kernel fusion + CUDA graph
│   ├── benchmark.h/cpp           # CUDA event 计时 + 对比表
│   └── main.cpp                  # 主入口
├── docs/
│   ├── design.md                  # 设计规格
│   ├── plan.md                    # 实施计划
│   └── interview_talk.md         # 面试讲稿（10 优化点 + 6 追问）
├── scripts/
│   └── build.sh                   # 一键编译运行
└── CMakeLists.txt
```

## 编译运行

依赖：
- CMake >= 3.18
- CUDA Toolkit >= 11（需要 nvcc）
- GCC >= 9

```bash
bash scripts/build.sh
```

预期输出：
```
GPU: NVIDIA GeForce RTX 3070 | SM 8.6 | 8192 MB
Generating 1000000 cloud points + 1000 queries...
CPU baseline: 2000 ms

=== KNN Benchmark ===
+---------------------------+--------+
| CPU brute O(N*M)          | 2000ms |
| GPU AoS baseline          |   50ms | 40x
| GPU SoA + coalesced       |   15ms | 133x
| GPU SoA + smem+shuffle    |    5ms | 400x
+---------------------------+--------+

=== ESDF Benchmark ===
| GPU jump flooding + graph |    3ms |
```

## 适配面试场景

| 岗位 | 重点讲哪几个模块 |
|------|----------------|
| 运动规划 C++ | ESDF、Uniform Grid、cache 优化 |
| 通用 CUDA 工程 | 全部模块 |
| 大模型部署 | 访存优化、kernel fusion、CUDA Graph 迁移到 LLM 算子 |
| 自动驾驶 | 点云处理、并行加速 |
| 医学影像 | 体数据 + 三维并行 |

## 面试讲稿

详见 [docs/interview_talk.md](docs/interview_talk.md)，每个优化点按"问题→方案→数据→为什么有效→迁移场景"五段式讲。
