# 04 — Vulkan：显式控制哲学（附 OpenGL 全面对比）

## 一、一句话定位

Vulkan（2016，Khronos）= 把 OpenGL 里**驱动替你做的所有决定**，
全部还给你自己做。口号：**"我们不猜，你说了算"**。

代价：画一个三角形 ~1500 行。回报：性能可控、多线程、跨厂商行为一致。

## 二、先给结论：和 OpenGL 到底怎么选

| 你在做什么 | 选 |
|---|---|
| 学图形学 / 写工具 / 点云可视化 | OpenGL（或直接 VTK） |
| 写游戏引擎 / 高性能渲染器 | Vulkan |
| 苹果平台 | Metal（苹果亲儿子，同代思想） |
| 浏览器 | WebGPU（Vulkan 思想的 JS 版） |
| 只要用 GPU 算数，不画图 | CUDA |

> **挂钩 CUDA**：你学 CUDA 时已经吃过 Vulkan 同款哲学——CUDA stream
> 显式管理依赖、cudaEvent 显式同步、显存自己 malloc/free。
> Vulkan 的 command buffer ≈ CUDA 的 stream（提交后异步执行），
> fence/event ≈ cudaEvent（CPU-GPU 同步点）。**CUDA 是计算界的 Vulkan，
> Vulkan 是图形界的 CUDA**——2006 和 2016 年 Khronos/NVIDIA 各自把
> "显式控制"带进自己的领域。懂了这个映射，Vulkan 一半概念你已经会了。

## 三、1500 行都在干什么：七个层层递进的对象

OpenGL 一行 `glDrawArrays` 背后，驱动替你建了整套体系。Vulkan 要求
你亲手搭：

```
① Instance        → 应用级入口（"我要用 Vulkan，启用哪些扩展"）
② PhysicalDevice  → 枚举显卡、查能力（选哪块 GPU）
③ Device + Queue  → 逻辑设备和命令提交队列（GPU 的"工种"：
                     graphics/compute/transfer 三类队列）
④ CommandBuffer   → 预录制的命令包（"画什么、怎么画"打包提交，GPU 异步执行）
⑤ Pipeline        → 一整条渲染管线的"编译产物"：shader+混合+剔除+格式
                     全部焊死成一个不可变对象
⑥ RenderPass      → "这一趟渲染写哪些附件、什么格式、怎么过渡"
                     （帧缓冲的说明书）
⑦ 同步原语        → Semaphore（GPU 内部跨队列同步）、Fence（CPU 等 GPU）、
                     Barrier（内存可见性）
```

### 灵魂：Pipeline 不可变（和 OpenGL 最大的分水岭）

- OpenGL：状态机随时改开关 → 驱动必须在**每次 draw call 前验证状态组合**
  （历史上 GPU 前端的大负担）
- Vulkan：把整条管线（shader+所有状态）**一次性编译成不可变对象**，
  之后 draw 不再验证。要换状态 = 换另一个 pipeline 对象（提前建好）

这就是显式 API 的本质：**把运行时的检查成本搬到初始化时的构建成本**。
游戏加载界面那 10 秒里，引擎在编译几百个 pipeline。

### 灵魂：Command Buffer 多线程录制

```
线程1: 录命令包 A（地面+建筑）
线程2: 录命令包 B（角色）
线程3: 录命令包 C（特效）      ← 三核并发，OpenGL 做不到
        ↓
主线程: 提交 A+B+C 到队列 → GPU 执行
```

现代游戏 draw call 上千/帧，单线程录制是 OpenGL 后期的真实瓶颈。
Vulkan 从 API 层面解决。

## 四、全维度对比表（背这张表）

| 维度 | OpenGL | Vulkan |
|---|---|---|
| 诞生 | 1992 SGI | 2016 Khronos（前身为 AMD Mantle） |
| 心智模型 | 全局状态机 | 显式对象 + 不可变 pipeline |
| 画三角形 | ~100 行 | ~1500 行 |
| 驱动角色 | 替你做决定（黑盒，性能看厂商） | 只做翻译（行为跨厂商一致） |
| 多线程 | 单线程 context | command buffer 并发录制 |
| 内存管理 | 驱动管（glBufferData 黑盒） | 显式分配器（vkAllocateMemory，还要考虑内存堆类型） |
| 同步 | 驱动隐式保证 | 全手动：fence/semaphore/barrier，**忘了就是花屏** |
| 错误检查 | 运行时驱动检查 | 关闭（发布模式零开销），Validation Layer 调试期开启 |
| 错误后果 | 性能差 | 崩溃/花屏/驱动重置 |
| 适合 | 学习、工具、科研可视化 | 引擎、极限性能、专业软件 |
| 移植 | 老 macOS 已弃 | Windows/Linux/Android/Switch/Steam Deck |

## 五、为什么"难"是对的：Validation Layer

Vulkan 的调试哲学值得一背：发布版 Vulkan **几乎不检查任何错误**
（为了性能）。但调试时可以插入 **Validation Layer**——驱动和你的代码
之间插入一层中间人，逐条 API 检查规范违规并给出人话报告
（"你在第 2341 行用了未绑定的 pipeline"）。

> 这套设计和 CUDA 的区别：CUDA 宁可运行时也检查（返回错误码），
> Vulkan 把检查做成可插拔层（性能优先到极致）。学 Vulkan 的第一课
> 就是"永远开着 Validation Layer 开发"。

## 六、什么场景用 Vulkan（决策）

用 Vulkan，当：
- **写引擎**：draw call 多（>2000/帧）、CPU 瓶颈明确、要多线程录制
- **要确定性的性能**：跨厂商行为一致，不玩"驱动抽奖"
- **跨平台发布**：一份代码 Windows/Android/Steam Deck 通吃
- **计算+图形混合**：compute shader 和 graphics 深度交织（Vulkan 的
  queue 家族天然支持，异步 compute 是 UE5 级引擎的标配技术）

不用 Vulkan，当：
- 工具/科研/点云可视化 → OpenGL 或 VTK（1500 行初始化的复杂度
  换不来任何用户可感知的收益）
- 学习图形学第一步 → OpenGL（先懂管线再懂工程）
- 苹果独占 → Metal

## 七、面试讲法（30 秒版）

> Vulkan 是 2016 年 Khronos 推出的显式图形 API，哲学和 CUDA 同源：
> 把驱动黑盒打开，内存、同步、管线全部程序员显式管理。三大结构改进：
> 不可变 pipeline 把状态验证成本搬到初始化；command buffer 支持多线程
> 并发录制提交；同步靠 fence/semaphore/barrier 显式声明。代价是画
> 三角形要 1500 行、错误直接花屏，靠 Validation Layer 开发期兜底。
> 选型上：引擎级负载和多线程录制需求选 Vulkan，工具类可视化 OpenGL
> 性能上限都没碰到，没有切换理由。

## 八、自检问答

1. **Q: Vulkan 的 1500 行和 OpenGL 的 100 行，差值花在哪？**
   A: 搭七层对象（instance/device/queue/command buffer/pipeline/renderpass/同步），以及显存和同步的显式管理——全是 OpenGL 驱动偷偷替你做的事。
2. **Q: 为什么 pipeline 做成不可变？**
   A: 状态组合在初始化时编译焊死，运行时 draw 不再验证——用构建时间换每帧的稳定性能。
3. **Q: Vulkan 的 fence 和 semaphore 区别？**
   A: fence 是 GPU→CPU 的通知（CPU 等命令完成）；semaphore 是 GPU 内部队列/阶段间的顺序（GPU 自己用）。≈ cudaEvent 的 stream 间同步 vs host 同步。
4. **Q: “CUDA 是计算界的 Vulkan”对在哪？**
   A: 同代际思想：显式内存、显式队列（stream/command buffer）、显式同步（event/fence）、跨硬件一致行为。一个 2006 面向计算，一个 2016 面向图形。
