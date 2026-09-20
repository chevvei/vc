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

## 二、GLSL 快速上手：和 C 的四个区别

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

## 三、五个 Shader 阶段全景（+1 个"脱轨"的）

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

## 四、光照实战：一个 fragment shader 的进化史

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

## 五、调试与工程套路（血泪经验）

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

## 六、什么场景用什么阶段（决策速查）

- 静态网格常规渲染 → vertex + fragment，管住这两个就够 80% 场景
- 大规模粒子/物理模拟/图像处理 → compute（图形 API 里最接近 CUDA）
- 地形 LOD → tessellation
- 几何体实时生成（毛发/破坏）→ geometry（现代引擎渐被 compute 取代）

## 七、面试讲法（30 秒版）

> Shader 是光栅化流水线上可编程阶段的 GPU 小程序：vertex shader 每顶点
> 跑一次做 MVP，fragment shader 每像素跑一次算光照颜色，中间属性由
> 硬件重心插值传递（varying）；GLSL 相对 C 的特点是向量化类型、
> swizzle 和 uniform 常量缓存。现代扩展出 tessellation/geometry 和
> 脱离管线的 compute shader——后者是 GPGPU 的起点，CUDA 和 3DGS 都
> 站在这一步上。工程上 fragment 是调用次数大头的性能瓶颈，
> 能上移到 vertex/顶点数据的计算要上移。

## 八、自检问答

1. **Q: vertex 和 fragment 的输入输出是怎么衔接的？**
   A: vertex 的 out 变量经硬件重心坐标插值后成为 fragment 的 in——所以 fragment 拿到的法线/颜色是三个顶点的加权混合。
2. **Q: uniform 为什么比 in 快？**
   A: uniform 本帧不变、全线程共享，放常量缓存/专用寄存器；in 每像素不同值还得插值计算。
3. **Q: 为什么说 compute shader 是 GPGPU 的起点？**
   A: 它第一次让 GPU 脱离图形管线跑任意逻辑（不再伪装成纹理/颜色），CUDA 是同年代的系统化演进。
4. **Q: 屏幕随机黑点，第一怀疑什么？**
   A: NaN 传播（除零/反三角越界）——用红色标记法定位源头。
