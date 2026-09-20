# 06 — Shader 编程：给 GPU 写的小程序

## 一、Shader 是什么：流水线上"插进去的自定义车间"

回顾 01 篇的光栅化流水线。1995 年前，所有车间都是**固定功能**
（Fixed Function）：能调参数（颜色、光源位置），不能改逻辑。

2001 年起（可编程 GPU），流水线上**两个车间被掏空，换成你的代码**：

```
①顶点着色 ──→ ②图元装配 ──→ ③光栅化 ──→ ④片段着色 ──→ ⑤测试混合
 (你的代码)    (固定)        (固定)      (你的代码)     (固定)
```

"Shader"（着色器）这个历史名字来自它的第一个用途（算光照/着色），
今天它就是**流水线上跑的 GPU 小程序**，什么都能算。

## 二、Shader 和 OpenGL 的关系：宿主与程序

**一句话**：OpenGL 是 CPU 调用的 API（接口规范）；Shader 是运行在
GPU 上的小程序。OpenGL 提供函数把 shader 送进驱动、编译、绑定、执行。

**类比**：OpenGL = 操作系统（Windows）；Shader = 你写的 exe。
Windows 提供 API 把 exe 加载进内存、运行——但 Windows 本身不带你的
业务程序。同理，**OpenGL 不内置任何 shader 代码**：它只做
"搬运 + 编译 + 调度"，shader 源码由上层提供（VTK 内置 GLSL，或你手写）。

### Shader 的生命周期：一整条 API 流水线

```c
// ---- 编译期：从文本到 GPU 程序 ----
glCreateShader(GL_VERTEX_SHADER)   // 在驱动里创建一个空 shader 对象
glShaderSource(sh, src)            // 把 GLSL 文本字符串传给驱动
glCompileShader(sh)                // 驱动现场编译文本 → GPU 指令

glCreateProgram(&prog)             // 创建"程序"容器
glAttachShader(prog, vs)           // 挂上编译好的顶点 shader
glAttachShader(prog, fs)           // 挂上片段 shader
glLinkProgram(prog)                // 链接：合并成完整可执行的 GPU 程序
                                   //（此步解析 varying/in/out 的对接）

// ---- 运行期：每帧 ----
glUseProgram(prog)                 // 激活："接下来的绘制用这个程序"
glUniformMatrix4fv(loc, ..., mvp)  // 把 CPU 侧的相机矩阵塞进 shader 的 uniform
glDrawElements(...)                // 触发！GPU 按当前管线配置跑 shader
```

记忆锚点：**编译三步（建/传/编）→ 链接两步（挂/链）→ 运行两步
（用/传参）→ 一触（draw）**。这套流程和 C++ 的"编译→链接→加载→运行"
一一对应，只是全在运行时发生（见第五节调试坑）。

### 用 VTK 场景串一遍（谁提供什么）

```cpp
// VTK 上层 C++ 里硬编码了 GLSL 源码字符串（VTK 替你写了 shader）
const char* vertexShaderSource = R"(
#version 330 core
layout(location=0) in vec3 pos;
uniform mat4 mvp;
void main(){ gl_Position = mvp * vec4(pos,1.0); }
)";

// 然后 VTK 调 OpenGL API 完成闭环：
// glShaderSource(...)   ← 把 GLSL 字符串交给驱动
// glCompileShader(...)  ← 驱动编译链接成 program
// glUniformMatrix4fv(..)← 渲染时把相机矩阵传给 shader
// glDrawElements(...)   ← 触发 GPU 执行
```

👉 分工：**VTK 提供 shader 源码，OpenGL 提供接口把它送上 GPU 执行**。
所以"VTK 和 OpenGL 谁写 shader"这个问题：VTK 写（内置），
你手写 Qt+OpenGL 时你自己写——OpenGL 永远只是宿主。

### 边界三连（常被问混）

1. **GLSL 是专配 OpenGL 的语言**（OpenGL Shading Language）；
   Vulkan 不吃 GLSL 文本，吃 SPIR-V 二进制（见下节）。
2. **老 OpenGL（2.x 以前）是固定管线，没有 shader**——光照靠
   glLightfv 等 API 参数控制，GPU 逻辑焊死。OpenGL 3.3+ 核心模式
   **强制**可编程管线：没 shader 画不出任何东西。VTK 用的就是后者。
3. **从属关系**：Shader 是被 OpenGL 管理、调度执行的 GPU 小程序；
   OpenGL 是 CPU 侧 API，负责和驱动通信、管理 shader 生命周期。

## 三、GLSL 快速上手：和 C 的四个区别

```glsl
// ---- 顶点着色器：每个顶点跑一次 ----
#version 330 core
layout(location = 0) in vec3 aPos;      // 区别①：向量是内置类型
layout(location = 1) in vec3 aColor;

uniform mat4 uMVP;                      // uniform = 所有顶点共享的常量
                                        //（本帧不变，从 CPU 传入）

out vec3 vColor;                        // out = 传给下一站的插值变量

void main() {
    gl_Position = uMVP * vec4(aPos, 1.0);   // 硬性任务：MVP 变换
    vColor = aColor;                         // 顺手把颜色传下去
}

// ---- 片段着色器：每个像素跑一次 ----
#version 330 core
in vec3 vColor;                         // 拿到的是"插值后"的颜色
                                        //（三个顶点的值按重心坐标混合）
out vec4 FragColor;

void main() {
    FragColor = vec4(vColor, 1.0);      // 硬性任务：定这个像素的颜色
}
```

和 C 的区别只有四个，全是为了图形学场景：
1. **向量/矩阵内置**：`vec3/vec4/mat4` 和 `a*b` 重载（乘矩阵），
   光栅化的 MVP 就一行
2. **swizzle**：`vColor.rgb`、`vColor.bgr` 任意重组分量，编译成零成本选择
3. **没有 printf/文件系统/堆**：GPU 上千线程并发，I/O 无意义；
   调试只能输出颜色当"染料"看（下文调试节）
4. **限定符三件套**（数据的来源决定性能）：
   - `in/out`：管线上下站传数据（自动插值）
   - `uniform`：本帧全线程只读的常量（放显存常量缓存，最快）
   - `texture`：贴图采样（有专门硬件）

## 四、GLSL vs SPIR-V：两种 shader 交付方式（OpenGL vs Vulkan 的缩影）

第二节的生命周期有个隐藏问题：**GLSL 是运行时交给驱动"现场编译"的**。
每家驱动内嵌自己的 GLSL 编译器 → 同一份 shader 在 N 卡/A 卡上编译出
不同指令、不同 bug、不同性能——这就是 OpenGL"驱动抽奖"问题的源头之一。

Vulkan 的答案：**shader 提前离线编译成 SPIR-V 标准二进制**，
驱动只做"字节码 → 硬件指令"的后端翻译。

```
OpenGL 路线（运行时编译）：
  你的 GLSL 文本 ──运行时──→ 驱动内嵌编译器 ──→ GPU 指令
  （每厂商编译器一个实现；首次编译有卡顿；行为看厂商）

Vulkan 路线（离线编译）：
  你的 GLSL ──离线工具──→ SPIR-V 字节码 ──运行时──→ 驱动只翻译后端
  （glslangValidator/shaderc 提前编译；驱动编译器只剩后端，
   跨厂商行为一致；启动快；还能离线优化/验证）
```

**类比**：GLSL = 把源代码发给对方现场编译（对方编译器版本决定一切）；
SPIR-V = 直接发编译好的 .o 文件，对方只负责链接。中间表示标准化后，
"方言问题"消失了。

| 维度 | GLSL（OpenGL） | SPIR-V（Vulkan） |
|---|---|---|
| 形态 | 文本源码 | 标准二进制字节码 |
| 编译时机 | 运行时（驱动内） | 离线（工具链完成） |
| 驱动负担 | 完整编译器（前端+后端） | 只剩后端翻译 |
| 跨厂商一致性 | 差（编译器各异） | 好（同一份字节码） |
| 首次运行 | 有编译卡顿 | 近乎零（只需翻译） |
| 工具链 | 弱 | 强（spirv-opt 优化器 / spirv-val 验证器） |

两个加分点：
- **哲学同源**：SPIR-V 和 04 篇的"pipeline 不可变"是同一个思想——
  把运行时的不确定性（编译时间、编译器差异）搬到初始化期解决。
- **冷知识**：OpenGL 4.6 起也能吃 SPIR-V（ARB_gl_spirv 扩展）；
  游戏界的"首次放技能卡一下"很多就是 shader 运行时编译造成的，
  现代引擎用预编译缓存（pipeline cache）规避——本质都是 SPIR-V 思想。

## 五、六个 Shader 阶段全景（+1 个"脱轨"的）

| 阶段 | 跑多少次 | 干什么 | 常见用途 |
|---|---|---|---|
| Vertex | 每顶点 | MVP + 传属性 | 顶点动画（风吹草） |
| Tessellation | 每图元 | 按需细分三角形 | LOD（近处细分，远处省） |
| Geometry | 每图元 | 增删改图元 | 毛发/粒子爆发 |
| **Fragment** | 每像素 | **算最终颜色** | **光照/纹理/后处理（主战场）** |
| Compute | 任意 | **脱离图形管线随便算** | 粒子物理/图像处理/**3DGS** |

**Compute Shader 是历史转折点**：2007 年起它把 GPU 从"图形专用"解放成
"通用计算"——CUDA 本质上是 compute 思想的独立进化（更早：GPGPU 时代
人们甚至用 fragment shader 装载浮点数据伪装成纹理来算数学，
CUDA 结束了这种受刑式编程）。今天 3DGS 的训练/渲染主力就是 compute
shader（07 篇）。

## 六、光照实战：一个 fragment shader 的进化史

**第 0 版：画画抹平（无光照）**
```glsl
FragColor = vec4(vColor, 1.0);   // 平面色块，像 1990 年的红警
```

**第 1 版：Lambert 漫反射（"面对太阳多亮"）**
```glsl
float diff = max(dot(normal, lightDir), 0.0);
FragColor = baseColor * (ambient + diff * lightColor);
// dot(n,l) = 两个方向的夹角余弦 —— 面越正对光越亮
// max(...,0) = 背面不给负亮度
```

**第 2 版：加 Blinn-Phong 高光（"反光亮点"）**
```glsl
vec3 halfDir = normalize(lightDir + viewDir);   // 半程向量
float spec = pow(max(dot(normal, halfDir), 0.0), 64.0);  // 64=越亮越聚焦
FragColor = baseColor * (ambient + diff + spec * lightColor);
```
→ 至此你有了 90 年代游戏画面。现代 PBR（基于物理的渲染）只是把
这两项换成能量守恒的微表面公式，**框架不变、系数换来源**。

## 七、调试与工程套路（血泪经验）

1. **没有 printf**——把待查变量映射到颜色输出：
   ```glsl
   FragColor = vec4(fract(myValue), 0, 0, 1);   // 值大小→红色亮度
   ```
   黑=0 亮=大，一眼看出梯度分布。
2. **顶点数据看不见 = 先把顶点涂成纯色**。画面全黑时二分排查：
   纯色都不显示→VAO/变换有 bug；纯色显示→shader 内部 bug。
3. **GLSL 编译错误在运行时**才爆（它是字符串传给驱动的！）。
   工程套路：加载函数里必查 `glGetShaderiv(GL_COMPILE_STATUS)`，
   否则一个拼写错误=黑屏无提示，新手一debug一整天。
4. **NaN 陷阱**：除零/acos(>1) 产生 NaN 会像病毒沿计算传播，表现为
   屏幕上随机黑点。套路：怀疑时主动 `if (isnan(x)) FragColor = 红色;`
5. **性能直觉**：fragment 跑的次数 = 覆盖像素数，是 vertex 的
   10~100 倍。**能搬到 vertex 算的别放 fragment**（凹凸贴图→法线
   贴图的迁移就是这个原则——正切空间变换挪到顶点级插值）。
   > 这就是 CUDA 里"计算搬出热路径"的同款思维：算力预算按调用次数排。
6. **shader 编译卡顿**：新 shader 首次使用那帧会卡（运行时编译+链接，
   大 shader 可达几十毫秒）。套路：加载期主动 warm-up 全部 program
   （预编译缓存/先画一帧离屏），别让玩家在战斗中第一次见到特效时卡。

## 八、什么场景用什么阶段（决策速查）

- 静态网格常规渲染 → vertex + fragment，管住这两个就够 80% 场景
- 大规模粒子/物理模拟/图像处理 → compute（图形 API 里最接近 CUDA）
- 地形 LOD → tessellation
- 几何体实时生成（毛发/破坏）→ geometry（现代引擎渐被 compute 取代）

## 九、面试讲法（30 秒版）

> Shader 是光栅化流水线上可编程阶段的 GPU 小程序，GLSL 写成文本、
> 由 OpenGL 的 API 链（编译→链接→useProgram→uniform→draw）送进驱动
> 执行——OpenGL 是宿主和调度器，本身不含 shader 代码，源码来自上层
> （VTK 内置或开发者手写）。vertex shader 每顶点跑一次做 MVP，
> fragment shader 每像素跑一次算光照，属性由硬件重心插值传递。
> GLSL 的痛点是运行时驱动编译、跨厂商行为不一致，Vulkan 用 SPIR-V
> 离线编译的二进制解决——把编译不确定性搬到初始化期，和 pipeline
> 不可变是同一哲学。compute shader 则是 GPGPU 起点，CUDA 和 3DGS
> 都站在这步上。

## 十、自检问答

1. **Q: vertex 和 fragment 的输入输出是怎么衔接的？**
   A: vertex 的 out 变量经硬件重心坐标插值后成为 fragment 的 in——所以 fragment 拿到的法线/颜色是三个顶点的加权混合。
2. **Q: uniform 为什么比 in 快？**
   A: uniform 本帧不变、全线程共享，放常量缓存/专用寄存器；in 每像素不同值还得插值计算。
3. **Q: OpenGL 和 shader 谁写光照逻辑？**
   A: shader 写（GPU 小程序）；OpenGL 只提供编译/绑定/传参/触发的 API，不内置任何 shader 代码。
4. **Q: 为什么说 compute shader 是 GPGPU 的起点？**
   A: 它第一次让 GPU 脱离图形管线跑任意逻辑（不再伪装成纹理/颜色），CUDA 是同年代的系统化演进。
5. **Q: GLSL 和 SPIR-V 的本质区别？**
   A: 文本源码 vs 标准二进制；运行时驱动编译 vs 离线工具链编译。SPIR-V 消除了"各厂商编译器方言"，是 Vulkan 确定性哲学的一部分。
6. **Q: 游戏里"首次放技能卡一下"的技术根源？**
   A: shader 以 GLSL/中间态运行时编译，首次使用才编译+链接；引擎用预编译 pipeline cache 规避（= SPIR-V 思想的工程化）。
