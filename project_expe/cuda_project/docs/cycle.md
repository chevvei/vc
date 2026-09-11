stall 停滞

Cycle 是 GPU 硬件的时钟节拍，是硬件最小工作单位。访问寄存器只需要约 1 个 cycle，非常快；访问 Global 显存需要几百个 cycle，延迟很高。GPU 靠 SM 上多组 warps 切换，来掩盖显存的长延迟。如果 occupancy 不够，没有备用 warp，SM 就会空闲。


			

单个 warp 访问显存时会 stall，但是 SM 上有很多 warps。当一个 warp 等待显存，硬件自动切换去执行别的已经准备好的 warp，用大量并行线程把显存延迟掩盖掉。前提是 occupancy 足够，有足够多就绪 warp。




# GPU内存层级汇总表（Ampere 3090Ti，Trae文档，面试直接用）

> cycle：硬件时钟节拍，芯片最小心跳。频率越高，1个cycle对应的纳秒越短。下面数字是**访问延迟（latency）**，发起请求到拿到数据大约需要多少cycle。

| 存储类型                       | 访问延迟        | 归属范围                            | 容量                | 工程使用说明                                                                                                                  |
| ------------------------------ | --------------- | ----------------------------------- | ------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Register 寄存器                | ~1 cycle        | **单线程私有**                | 每个线程几十个      | 最快。保存计算临时变量（距离、中间浮点结果）。寄存器消耗会直接限制SM能容纳的warp数量，影响occupancy。                         |
| Shared Memory 共享内存         | ~20 cycle       | **同一个block内所有线程共享** | 每块SM：48~164KB    | 速度远高于global显存。把重复读取不变数据（ESDF网格常量、采样参数）加载到smem，减少访问全局显存。smem开太大也会压低occupancy。 |
| L1 / L2 Cache 缓存             | ~30–100 cycle  | 硬件自动管理                        | L1很小；L2几MB      | 程序员不用手动读写。缓存global显存的数据，硬件自动预取。                                                                      |
| Global Memory 全局显存（DRAM） | ~400–800 cycle | **所有block、所有线程共享**   | 数GB（3090Ti 24GB） | 容量最大，延迟极高。是大部分kernel瓶颈。优化重点：**合并访问coalesced**，减少读写。                                     |

## 核心原理一句话

访问Global显存要等几百个cycle，warp会stall。GPU靠SM上大量warps互相切换来掩盖这个长延迟；前提是occupancy足够，有备用就绪warp。如果occupancy低，没有其他warp可以切换，SM就空转浪费算力。

## 配套面试段落（直接复制进文档）

> GPU的内存延迟差异巨大：寄存器1cycle，shared内存约20cycle，L1/L2缓存几十到上百cycle，全局显存高达几百cycle。
> Global显存延迟最高，是很多kernel的瓶颈。GPU不是让一个warp死等，而是SM上准备很多warps；当一个warp卡在显存访问，硬件切去跑其他就绪warp，以此掩盖延迟。
> 但如果每个线程寄存器或者shared memory占用太多，SM放不下足够多warps，achieved occupancy就会变低，没有备用warp，硬件就没法隐藏显存延迟，性能下滑。
> 优化思路就是：尽量复用寄存器、shared memory，减少global显存访问，并且保证warp访问global内存地址连续，实现coalesced合并访问。

## 记忆卡片

1. cycle = 硬件时钟节拍，不是固定纳秒，和芯片频率相关
2. 延迟差距巨大：寄存器最快，Global显存最慢，差几百倍cycle
3. 高显存延迟靠**warp切换**掩盖，依赖足够高的occupancy
4. 寄存器、shared memory用量，直接限制occupancy

---

现在我们CPU+GPU整套性能分析链路已经齐全：
CPU：perf / cache locality / AoS/SoA / SIMD / 循环展开
GPU：SM、warp、SIMT、内存层级、ncu、nsys、DRAM throughput、occupancy、warp stall

下一部分，你想：
选项A：整理一整套**面试连续问答串**（面试官顺着问性能优化，你连贯回答）
选项B：写一段极简CUDA伪代码（批量距离计算，带合并访问）
选项C：继续学习 warp stall 的各类原因（ncu里常见stall类型，面试高频追问）？
