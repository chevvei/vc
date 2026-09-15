# 逆向诊断题库 —— 症状 → 概念的反向检索训练

> 配套 [AGENTS.md §2.4 惰性知识对抗协议](../AGENTS.md)。费曼讲得清是 L2，症状面前会用才是 L3。
> **用法**：每张卡先遮住答案，口头答出三问——**怀疑对象？验证方法（工具+指标）？修复方向？**——再核对。
> 卡片标注 🎯 的是本项目**真实踩过**的坑，面试可讲。

---

## 使用规则（导师与学员共同遵守）

1. 每阶段验收第 4 条（L3 运用验收）从本库对应阶段抽卡
2. 间隔重复：进入新阶段时，导师随机抽上一阶段 1 张卡复测
3. 答题格式固定三问：**怀疑 → 验证 → 修复**。只会"修复"不会"验证"= 没过（工程里验证手段就是定位能力）
4. 每次新踩坑，学员自己写一张新卡追加进对应阶段（踩坑 → 卡片化，是最好的复习）

---

## 阶段 2：数据传输（pinned / async / stream）

### 🎴 诊断卡 1：H2D 拷贝慢得离谱

**症状**：1M 个点（12MB）CPU→GPU 拷贝耗时 8ms。PCIe 4.0 x16 理论 ~25GB/s，12MB 应该 <1ms。拷贝期间 `nvidia-smi` 显示 GPU 计算单元空闲。

**先自答三问**：怀疑什么？用什么验证？怎么修？

**答案**：
- **怀疑**：pageable memory（普通 malloc 的内存）。pageable 内存拷贝时驱动要先中转进 pinned 池，多一次拷贝且无法 DMA 直传
- **验证**：代码里查 host 缓冲是不是 `new`/`malloc` 分配的；用 nsys timeline 看 memcpy 是不是分成了两段（staging 拷贝 + DMA）
- **修复**：`cudaMallocHost()` 分配 pinned 内存（本项目 [pointcloud.cpp](../src/pointcloud.cpp) 的做法），拷贝速度可翻数倍，且 `cudaMemcpyAsync` 才能真正异步
- **项目锚点**：[pointcloud.cpp — pinned memory 异步拷贝](../src/pointcloud.cpp)

### 🎴 诊断卡 2：memcpy 和 kernel 完全串行

**症状**：nsys timeline 上，多个 batch 的 H2D 拷贝和 kernel 执行完全首尾相接：拷贝时 SM 空闲，计算时 PCIe 空闲。总时间 = Σ(拷贝时间) + Σ(计算时间)。

**先自答三问**：

**答案**：
- **怀疑**：单 stream 串行执行；或用了同步版 `cudaMemcpy`（隐式同步）
- **验证**：nsys timeline 看 stream 轨道数量；代码里查 `cudaMemcpy`（同步）还是 `cudaMemcpyAsync` + stream 参数
- **修复**：双 stream + ping-pong 双缓冲——copyStream 搬第 N+1 批时，computeStream 算第 N 批，用 `cudaStreamWaitEvent` 控依赖
- **项目锚点**：[code_walkthrough.md 前置章节 — CUDA Stream / Pipeline](../docs/code_walkthrough.md)

---

## 阶段 4：访存优化（SoA / 合并访存 / cache line）

### 🎴 诊断卡 3：occupancy 正常但 kernel 慢

**症状**：ncu 显示 `achieved_occupancy 88%`、`sm__throughput 30%`、`dram__throughput 28%`。占用率明明很高，SM 却大量空闲，带宽也没吃满。

**先自答三问**：

**答案**：
- **怀疑**：延迟受限（latency bound）。占用率高说明驻留 warp 够多，但每个 warp 都在等内存返回——典型原因：**非合并访存**（每次事务只搬回少量有用字节，带宽利用率低但请求次数多）
- **验证**：ncu Source 页面看 global load 效率指标（`l1tex__average_t_sectors_per_request`，理想 4）；Memory Workload Analysis 图看 sectors/request 是否超标
- **修复**：改数据布局 AoS→SoA，或调整线程→数据的映射让 warp 内 32 线程读连续地址
- **项目锚点**：[gpu_optimized_soa.cu](../src/gpu_optimized_soa.cu)——AoS 89ms → SoA 59ms

### 🎴 诊断卡 4：改一个字段名，性能差 3 倍

**症状**：同事把 kernel 里的 `cxs[i]` 改成 `cloud[i].x`（SoA 改回 AoS），算法逻辑完全没变，KNN 从 59ms 慢到 89ms。

**先自答三问**：

**答案**：
- **怀疑**：访存模式退化。`cloud[i].x` 相邻线程地址间隔 12B（xyz 捆绑），warp 32 线程读 x 跨 384B = 3 个 cache line；SoA 下连续 128B = 1 个 cache line
- **验证**：ncu 对比两个版本的 `dram__throughput`（有用带宽占比）和 sectors/request
- **修复**：布局改回 SoA。本质：**让 warp 的访问模式匹配 128B cache line 粒度**
- **项目锚点**：[teaching_mastery.md §3.0 故事1 / cache line 专题](../docs/teaching_mastery.md)

### 🎴 诊断卡 5：L2 命中率高但 DRAM 流量还是大

**症状**：ncu 显示 L2 hit rate 70%，但 `dram__bytes` 总量巨大——同一个 tile 的数据被反复从 global 读，L2 命中也只是"缓了一口气"。

**先自答三问**：

**答案**：
- **怀疑**：global 重复读，缺 shared memory tiling。L2 命中≠免费，200 cycles 延迟仍在；同一数据被 block 内所有线程各读一次
- **验证**：算数据复用率——若 tile 内每个点平均被 block 内多线程访问，就该搬进 smem；ncu 看 `l1tex__t_bytes_pipe_lsu_mem_global`（L1 级 global 流量）
- **修复**：block 协作搬运 tile 进 shared memory（每点从 global 只搬 1 次），block 内线程从 smem 读（20 cycles）
- **项目锚点**：[knn_search_kernel.cu — tiling 主循环](../src/knn_search_kernel.cu)

---

## 阶段 5：并行调度（tiling / bank conflict / shuffle / 归约）

### 🎴 诊断卡 6：加了 smem tiling 反而变慢 🎯（真实踩坑）

**症状**：在 SoA baseline（59ms）基础上加了 shared memory tiling，结果变成 180ms。优化变负优化。

**先自答三问**：

**答案**：
- **怀疑**：tiling 写法引入了重复劳动。本卡真实根因：旧版让**每个线程扫整个 tile**——256 线程 × 每人扫 256 点 = 65536 次比较/tile，是"假并行真串行"
- **验证**：读代码看 tile 循环体——`for (int j = 0; j < blockDim.x; j++)` 出现在线程内部即中招；ncu 对比 `sm__inst_executed` 指令总量暴涨
- **修复**：每个线程只处理 tile 中**第 tid 个位置**（一人一砖），256 线程并行覆盖 256 点，零冗余
- **项目锚点**：[knn_search_kernel.cu — 修复后的写法](../src/knn_search_kernel.cu)；故事见 [teaching_mastery.md §3.0](../docs/teaching_mastery.md)

### 🎴 诊断卡 7：只有 1/8 的查询结果正确 🎯（真实踩坑）

**症状**：KNN 输出 8 个 query 里只有 warp 0 对应的 query 结果正确。编译无警告，无越界。

**先自答三问**：

**答案**：
- **怀疑**：跨 warp 归约缺失。真实根因：旧版只做了 warp 0 的 shuffle 归约——但 shuffle 只在 warp 内（32 线程）有效，block 有 8 个 warp，7 个 warp 的最小值没参与最终归约
- **验证**：读归约代码——搜 `warpId == 0`，确认前面有没有"每 warp lane 0 写 smem → warp 0 再归约"的中间级
- **修复**：两级归约：① 每 warp 内 shuffle 得 warp 最小 → lane 0 写 smem；② warp 0 读 8 个 warp 结果再 shuffle 一次 → lane 0 写回 global
- **项目锚点**：[knn_search_kernel.cu — 两级归约](../src/knn_search_kernel.cu)

### 🎴 诊断卡 8：结果偶发错误，重跑又对了

**症状**：kernel 输出时对时错，错误率约几万分之一。加 printf 调试后错误消失（Heisenbug）。

**先自答三问**：

**答案**：
- **怀疑**：race condition——最常见是 tiling 循环里缺 `__syncthreads()`：线程 A 还在读上一个 tile 的 smem，线程 B 已开始写入下一个 tile，读写交错
- **验证**：代码审查 syncthreads 位置——tiling 循环需要**两处**屏障（搬完等全员、用完等全员）；Compute Sanitizer `racecheck` 子工具可实测
- **修复**：补齐两处 `__syncthreads()`；注意"搬完"和"用完"是两个不同屏障，缺一不可
- **项目锚点**：[knn_search_kernel.cu tiling 循环的两处 __syncthreads](../src/knn_search_kernel.cu)

### 🎴 诊断卡 9：ncu 报 bank conflicts 超标

**症状**：ncu 显示 `l1tex__data_bank_conflicts_pipe_lsu_mem_shared` 数值很高，shared memory 利用率反而低。

**先自答三问**：

**答案**：
- **怀疑**：warp 内多线程访问同一 bank。经典来源：stride 为 32 的倍数（如 `buf[i*32]`，bank=(i×32)%32=0 恒定）；或矩阵按列访问 `mat[i][0]`
- **验证**：ncu Source 页面标红的 smem 访问行；手算 `bank = (byte_addr/4) % 32` 验证 warp 内 32 线程的 bank 分布
- **修复**：padding——数组加 1 列（32→33），让 stride 与 32 互质，32 线程散到 32 个 bank；或改访问顺序
- **项目锚点**：[teaching_mastery.md §3.0 故事2 — 三种撞 bank 场景](../docs/teaching_mastery.md)

---

## 阶段 6+：调度与工程化（occupancy / smem 上限 / launch 开销）

### 🎴 诊断卡 10：kernel 直接启动失败

**症状**：把 tile 从 256 改成 16384（想提高复用率），kernel launch 返回 `cudaErrorInvalidValue`，程序崩溃。改回 256 又正常。

**先自答三问**：

**答案**：
- **怀疑**：smem 超限。16384 点 × 3 分量 × 4B = 192KB。两个限制：① 单 block 静态 smem 默认上限 48KB（超过需 `cudaFuncSetAttribute(cudaFuncAttributeMaxDynamicSharedMemorySize, ...)`）；② Ampere SM 物理上限 164KB，192KB 怎么都放不下
- **验证**：`cudaGetLastError()` 读返回码；`cudaFuncGetAttributes` 查 kernel 的 smem 需求
- **修复**：tile 压回合理值。工程判断：tile 大→复用率高但 occupancy 掉（一个 SM 塞不下几个 block）；tile=blockDim 是零冗余搬运的平衡点
- **项目锚点**：[AGENTS.md §0.4.6 — shared 划分与 occupancy](../docs/teaching_mastery.md)

### 🎴 诊断卡 11：GPU 利用率锯齿波动

**症状**：nsys 显示 GPU 计算和空闲交替出现，像锯齿。每帧总耗时远大于 kernel 计算时间之和。CPU 侧只有一个循环逐个 launch。

**先自答三问**：

**答案**：
- **怀疑**：launch 开销 + 单 stream 串行。kernel 间隙全是 CPU launch 与 stream 排队的空泡；N 个小 kernel = N 次往返
- **验证**：nsys 量 kernel 间隙时长占比；若间隙 > 计算本身，就是调度开销主导
- **修复**：三选一按侵入度递增——① kernel fusion 合并小 kernel；② 多 stream 流水重叠；③ CUDA Graph 一次性提交整帧
- **项目锚点**：[code_walkthrough.md — Stream/Pipeline 章节](../docs/code_walkthrough.md)

### 🎴 诊断卡 12：白纸复现 —— 256 线程求最小值

**症状**：不算诊断，是**产出验收**。不看任何参考，从空文件写：`__global__` kernel，输入 256 个 float，block 内归约出最小值，lane/thread 0 写回。

**验收点（导师检查清单）**：
1. 两级归约结构（warp shuffle → smem 中转 → warp 0 终归约）
2. `__syncthreads()` 位置正确（写 smem 后、读 smem 前）
3. shuffle mask `0xffffffff`、offset 从 16 减半到 1
4. 只有 block 内一个线程写回 global
5. 能口述每一步对应的硬件行为（寄存器交换 / smem 延迟 / 屏障成本）

**参考**：写完对照 [knn_search_kernel.cu 归约段](../src/knn_search_kernel.cu)自查。

---

## 附：症状 → 概念速查表（急救用，平时禁止先看这个）

| 症状关键词 | 第一怀疑对象 | 卡号 |
|-----------|-------------|------|
| 拷贝慢、GPU 空转 | pageable memory | 1 |
| 拷贝计算不重叠 | 单 stream / 同步 memcpy | 2 |
| 占用高但慢 | 非合并访存（latency bound） | 3 |
| 改字段名慢 3 倍 | AoS 布局 | 4 |
| 重复读 global | 缺 smem tiling | 5 |
| 优化变负优化 | tiling 重复劳动 | 6 |
| 部分结果错 | 归约层级缺失 | 7 |
| 偶发错误 | race / 缺 syncthreads | 8 |
| smem 利用率低 | bank conflict | 9 |
| launch 失败 | smem 超限 | 10 |
| 利用率锯齿 | launch 开销 / 串行 | 11 |
| （从零写不出） | 白纸复现缺失 | 12 |
