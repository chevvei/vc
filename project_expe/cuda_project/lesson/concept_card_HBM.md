# 概念卡片：

> 命名：knowledge/concepts/{YYYYMMDD}_{概念缩写}.md，例：20260902_agent-loop.md
> 入库标准：**通过费曼检验（脱稿讲 10 分钟）才写卡**。写卡是掌握的输出，不是学习的输入。

## 一句话定义

（外行也能听懂）


# 核心结论先放前面

1. **SRAM、HBM（GPU Global Memory）全都是易失性存储器 → 断电数据全部丢失，都不是非易失**
2. SRAM：**片上静态存储器（在 GPU 芯片内部 SM/L1/L2 里）**
3. HBM：**GPU 的全局显存 Global Memory，是 DRAM，2.5D 封装贴在 GPU 旁边，不在 GPU 核心硅片上**


* SRAM：片上、快、容量小、静态 RAM（不需要刷新）
* HBM：片外 DRAM（属于 Global Memory）、慢很多、容量大、动态 RAM（需要不断刷新维持电荷）
* 两者**都是易失性！断电数据消失**
* 非易失例子：SSD (NAND Flash)、硬盘、ROM
* 

## 它解决什么工程问题

（没有它会怎样？）

## 关键机制

（3-5 条，每条一句话，可配伪代码）

## 易错点 / 我踩过的坑



3. 容易踩坑的概念澄清
   坑 1：HBM 贴在 GPU 旁边，是不是片上内存？
   ❌ 不是！
   只是 2.5D 封装距离很近，带宽高，但 HBM 仍然是独立的 DRAM 裸片，不属于 GPU 核心硅片，属于片外存储。
   SRAM 是直接做在 GPU 核心那块硅片上面。


### 坑 2：Global Memory = HBM？

逻辑层面：CUDA 编程模型里叫 Global Memory。

物理层面：在新的 AI GPU 上 Global Memory 就是 HBM DRAM；老消费卡是 GDDR DRAM。

> Global Memory 是 **编程模型名词** ；HBM 是 **硬件物理介质名词** 。




## . 和你前面 CUDA 知识串起来

* `__shfl_xor_sync`：寄存器之间交换，寄存器是 SRAM，完全不碰 HBM。
* 访存读取 global 内存：去 HBM DRAM 拿数据，先进入 L2/L1（SRAM 缓存），再送到 SM。
* 优化目标：尽量复用片上 SRAM（shared、cache），减少去 HBM DRAM 的访问。




## 与其他概念的关联

（上游：__　下游：__　对比：__）


3. L1 Cache
   ✅ 硬件：SRAM，每个 SM 私有
   ✅ 归属：硬件自动管理，程序员不能直接读写 L1，只能通过访问 Global Memory，硬件自动缓存。
   ✅ 和 Shared Memory：同一块 SM 内部 SRAM 池，动态 / 静态划分。
   ✅ 缓存对象：Global Memory 的数据；支持 load 缓存，也可以配置是否缓存 store。
   ✅ 作用：同一个 SM 多次访问同一个全局地址时，命中 L1 就不用去 L2/HBM。
   ✅ 局限：只属于当前 SM；别的 SM 看不到这个 SM 的 L1 内容。
   ⚠️ CUDA 里 L1 和 Shared Memory 是 “抢同一块 SRAM”，这是 GPU 和 CPU 非常大的区别。CPU 的 L1 Cache 是固定硬件，不能拿来当用户内存。



4. L2 Cache
   ✅ 硬件：SRAM，整个 GPU 所有 SM 共享（不是每个 SM 一份）
   ✅ 归属：硬件自动管理，程序员无法直接读写
   ✅ 不会和 Shared Memory 抢资源，L2 是独立的 SRAM 大块。H100 L2 是 50MB。
   ✅ 作用：
   所有 SM 访问 Global Memory 都要经过 L2
   跨 SM 的数据可以在 L2 缓存
   充当 L1 和 HBM 之间的缓冲；合并请求、过滤重复访问
   ✅ 特点：容量比单个 SM 的 L1/Shared 大很多，但延迟高于 L1/Shared。




| 存储               | 位置           | 管理者               | 可见范围                | 硬件材质                     |
| ------------------ | -------------- | -------------------- | ----------------------- | ---------------------------- |
| 寄存器             | 每个 SM 内     | 编译器 / 硬件        | 单个线程私有            | SRAM                         |
| Shared Memory      | 每个 SM 内     | **程序员手动** | 同一个 block 内线程可见 | SRAM（和 L1 共享一片存储池） |
| L1 Cache           | 每个 SM 内     | **硬件自动**   | 当前 SM                 | SRAM                         |
| L2 Cache           | GPU 全局       | **硬件自动**   | GPU 全部 SM             | SRAM（独立）                 |
| Global Memory(HBM) | 2.5D 封装 DRAM | 程序员               | 全部线程                | DRAM                         |




## 在我项目中的落点

（哪个项目哪个文件用到了它）

## 掌握自评

- [ ] 能画图讲清流程
- [ ] 能说清失败模式
- [ ] 能对比替代方案

- 自评分数：_/5（低于 3，一周后重测）
