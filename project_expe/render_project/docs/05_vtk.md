# 05 — VTK：科学可视化的瑞士军刀

## 一、定位：VTK 管的是"数据"，不是"游戏"

一句话分家：
- **Unity/Unreal（游戏引擎）**：管**场景**——角色、物理、AI、碰撞、资产工作流。优化目标：好看+实时。
- **VTK（可视化工具包）**：管**数据**——把科学计算的结果（体数据/网格/流场/点云）变成人能看懂的图。优化目标：**准确 + 快速出图**。

典型用户：医学影像（CT/MRI 三维重建）、CFD 流场、地质建模、粒子模拟、
**激光点云**（LidarAssistant 那类工具的近亲 VTK/PCL/CloudCompare 全家）。

## 二、灵魂设计：流水线（Pipeline）架构

VTK 把可视化建模成一条**数据流水线**，每个环节是一个对象：

```
Source（数据源）
   │  读文件/生成几何
   ▼
Filter（过滤器）──→ Filter ──→ Filter     ← 数据在这里被加工
   │  （平滑/裁剪/等值面提取/下采样）
   ▼
Mapper（映射器）
   │  决定"数据 → 图形属性"（颜色映射查表、点大小、透明度）
   ▼
Actor（演员）
   │  一个可显示的实体（位置/姿态/属性）
   ▼
Renderer + RenderWindow
      （把所有 Actor 画出来）
```

**生活类比：洗照片**。Source 是底片（原始数据），Filter 是冲洗修图
（裁剪、调色、提取轮廓），Mapper 是"颜色怎么上"（CT 值→灰度/伪彩的
对照表），Actor 是装裱好的相片，Renderer 是展厅墙面。

这个设计的威力在 **Filter 可以自由串接**：

```cpp
// 读 CT → 提取骨骼等值面 → 平滑 → 显示（6 行搭完一条医学重建管线）
vtkNew<vtkStructuredPointsReader> reader;   // Source
vtkNew<vtkMarchingCubes> bones;             // Filter: 提取骨头等值面
bones->SetValue(0, 1150);                   //   CT 值 1150 HU 是骨
bones->SetInputConnection(reader->GetOutputPort());
vtkNew<vtkSmoothPolyDataFilter> smooth;     // Filter: 三角形平滑
smooth->SetInputConnection(bones->GetOutputPort());
vtkNew<vtkPolyDataMapper> mapper;           // Mapper
mapper->SetInputConnection(smooth->GetOutputPort());
vtkNew<vtkActor> actor;                     // Actor
actor->SetMapper(mapper);
```

## 三、VTK 的数据模型：一切皆 vtkDataSet

游戏引擎的核心结构是"场景图"（物体父子层级）；VTK 的核心结构是
**vtkDataSet**（数据集）——每个 Filter 吃一种数据集、吐一种数据集：

| 数据集类型 | 长什么样 | 典型来源 |
|---|---|---|
| vtkPolyData | 点/线/三角形 soup | 点云、STL 模型、等值面输出 |
| vtkImageData | 规则体素网格 | CT/MRI 切片堆 |
| vtkStructuredGrid | 规则拓扑+曲线几何 | 数值模拟网格变形 |
| vtkUnstructuredGrid | 任意拓扑单元 | 有限元（FEM）结果 |

关键认知：**LidarAssistant 的点云在 VTK 世界里就是一个
vtkPolyData（只有 points，没有 cells）**。理解了这一点，
"点云渲染"和"VTK"就接上了。

## 四、渲染后端：VTK 不是渲染 API 的竞争者

VTK 9.x 的渲染栈：`vtkRenderer → vtkOpenGLActor → ... → OpenGL`
（可选 Vulkan 后端实验支持）。VTK 替你做了：
- 相机/光源/坐标变换（MVP）管理
- 内置上百种 Mapper（点/线/面/体绘制/流线）
- 交互器（vtkRenderWindowInteractor：鼠标旋转缩放平移）
- **体绘制（Volume Rendering）**：医学影像镇场之宝——不用提等值面，
  直接"烟雾状"渲染整个体数据（Ray Casting 逐像素采样合成，
  是"光线追踪思想在医学影像的标准应用"，串起 02 篇）

## 五、VTK 与 Shader：谁写、谁编译、你要不要写

**一句话**：VTK（OpenGL 后端）自带写好的 GLSL 源码并在内部自动编译，
正常业务开发**一行 shader 都不用写**；默认效果不够时可以注入自定义片段。

### 谁持有 shader 源码？→ VTK

VTK 的 OpenGL 后端（`vtkOpenGLPolyDataMapper` / `vtkOpenGLVolumeMapper`
等）内置了一堆 GLSL 源码字符串，**写死在 VTK 库代码里**：

| 内置 shader | 干什么 | 对应业务 |
|---|---|---|
| 面渲染 vs+fs | 三角面片光照绘制 | 骨骼等值面（第二节 CT 例子） |
| 体渲染 vs+fs | ray casting 逐像素采样合成 | CT 软组织体渲染 |
| 颜色映射 | 标量值 → 颜色 | 仿真云图（CFD 压力场） |
| 配套件 | 法线/光照/透明度/裁剪面 | 各种绘制选项 |

这些是 VTK 团队写好的——**OpenGL 不自带任何 shader 代码**，
它只是 API（06 篇第二节"宿主与程序"讲过这层关系）。

### 编译谁干？→ VTK 调 OpenGL API，且只编译一次

第一次绘制某个 Actor 时：

1. VTK 取出内置 GLSL 源码字符串
2. VTK 调 `glCreateShader` → `glShaderSource` → `glCompileShader` →
   `glLinkProgram`（驱动现场编译）
3. 成功后**缓存 program 句柄** → 后续帧直接 `glUseProgram` 复用，
   不再重复编译

VTK 内部（简化自 `vtkOpenGLShaderCache`）：

```cpp
// VTK 内部伪代码：第一次用某套 shader 时现场编译，之后查缓存
GLuint GetProgram(const std::string& vsSrc, const std::string& fsSrc) {
    auto key = hash(vsSrc + fsSrc + "#版本/选项宏");  // 源码+配置 = 缓存键
    if (cache.count(key)) return cache[key];          // ② 二次以后：直接命中
    GLuint vs = glCreateShader(GL_VERTEX_SHADER);     // ① 第一次：现场编译
    glShaderSource(vs, vsSrc.c_str());                //    库里写死的字符串
    glCompileShader(vs);                              //    GPU 驱动干编译
    // ... fs 同理 → attach 到 program → link → 存 cache ...
    return cache[key] = prog;
}
```

**类比**：VTK 自带 C 源码，调用 gcc（OpenGL 驱动）编译成可执行文件——
编译一次，永久复用。

### 两种开发场景：要不要写 shader？

**场景 A：普通使用 VTK（绝大多数医学/仿真软件）**
不写任何 shader。搭好 Source→Filter→Mapper→Actor 管线，
VTK 自动选 shader、自动编译、每帧自动传 uniform
（相机矩阵/颜色/窗宽窗位）。底层对业务完全透明。

**场景 B：默认效果不够（进阶）**
通过 VTK 的 **shader 回调/替换机制**注入自定义 GLSL：
在 VTK 内置 shader 管线上做**钩子注入**（改法线/颜色/透明度），
也可以整套替换。

> **工程经验：注入优于替换**。VTK 内置 shader 处理了大量边角功能
> （拾取、裁剪、LOD、深度 peel），整套换掉等于放弃这些白送的能力，
> 而且矩阵/颜色映射/光照的 uniform 全要自己接管。微调用注入，
> 只有彻底重做渲染才考虑替换。

### 三个高频混淆点（面试纠错用）

1. ❌ "OpenGL 自带 shader" → 错。API 零代码，源码永远来自上层（VTK 或你）
2. ❌ "VTK 把 shader 预编译成二进制" → 默认不是。VTK 存 GLSL **文本**，
   运行时由驱动现场编译（Vulkan 后端例外，见下）
3. ❌ "每帧都重新编译" → 错。首次编译一次、缓存句柄复用；
   "第一次渲染某物体卡一下"的根源正是这次编译（06 篇 warm-up 套路）

### 小补充：VTK 的 Vulkan 后端（实验版）逻辑不同

Vulkan 不吃 GLSL 文本 → VTK Vulkan 后端内置的是 **SPIR-V 二进制**
（离线编译好），运行时直接加载，没有"驱动现场编译"这一步。
06 篇第四节 GLSL vs SPIR-V 的对比在这里得到实例印证。

## 六、什么时候用 VTK（决策）

用 VTK，当：
- **科学数据可视化**：医学影像、CFD、FEM、点云、地理数据
- 要**快速搭原型**：几十行 C++/Python 出一张可交互三维图
- 数据是"计算结果"而非"美术资产"——没有贴图/骨骼/动画需求
- 桌面软件集成：Qt + VTK 是工业软件经典组合（PCL Visualizer、
  ParaView、3D Slicer 全是 VTK 系）

不用 VTK，当：
- 做游戏/AR/VR → Unity/Unreal（VTK 没有场景/物理/资产工作流）
- 追求极限帧率 → 直接 OpenGL/Vulkan 手写（VTK 通用 Mapper 有抽象税）
- 网页端 → three.js/WebGPU 生态（VTK 有 wasm 版但重）

> **面试加分**：VTK 和 OpenGL 的关系常被问混。记住层级：
> "VTK 是可视化框架，底层调 OpenGL；我的点云渲染经历是 Qt+OpenGL
> 手写，和 VTK 的差别是 VTK 把 Mapper/交互/数据流水线都封装好了，
> 代价是抽象税和定制天花板。"

## 六、和点云工具链的关系（行业地图）

```
PCL（点云算法库：滤波/配准/分割）
   │  数据结构 pcl::PointCloud ≈ vtkPolyData
   │  自带可视化 pcl::visualization ≈ VTK 的薄封装
   ▼
VTK（通用科学可视化）
   │  ParaView = VTK 的桌面成品（拖拽式流水线）
   ▼
OpenGL（底层渲染）
```

LidarAssistant 走的是"Qt + OpenGL 手写"路线（轻量、可控），
PCL/CloudCompare 走"VTK 系"路线（功能全、开箱即用）。
两条路线没有对错，是"定制自由度 vs 开发速度"的经典取舍。

## 八、面试讲法（30 秒版）

> VTK 是科学可视化工具包，和游戏引擎的根本区别是它管"数据流水线"
> 而非"场景图"：Source 读入 vtkDataSet（点云对应 vtkPolyData），
> Filter 串接加工（平滑/裁剪/等值面），Mapper 决定颜色映射，Actor
> 进渲染器，底层默认用 OpenGL。它的价值是上百个现成 Filter 和
> Mapper（尤其体绘制），几十行代码出可交互三维图，是医学影像、
> CFD、点云工具（ParaView/PCL）的地基。shader 层面 VTK 内置全套
> GLSL 并自动编译缓存，业务层零 shader；要定制效果用回调注入而非
> 整套替换。代价是抽象税和渲染定制天花板，追求帧率的游戏场景不选它。

## 九、自检问答

1. **Q: VTK 和 Unity 都是"3D 引擎"，本质区别？**
   A: 数据模型不同：VTK 是数据流水线（Filter 加工数据），Unity 是场景图（物体+物理+资产）；前者优化"科学数据→准确图"，后者优化"美术资产→实时画面"。
2. **Q: 点云在 VTK 里是什么数据类型？**
   A: vtkPolyData（只有 points 没 cells 的退化形式）。
3. **Q: VTK 的体绘制用的是什么算法思想？**
   A: Ray casting 逐像素沿视线采样合成（光线追踪思想，但只穿体数据不需要求交场景几何）。
4. **Q: 为什么 LidarAssistant 不用 VTK 而手写 OpenGL？**
   A: 定制自由度 + 轻量依赖 + 性能可控；VTK 的通用 Mapper 抽象税对单一点云场景是负资产。
5. **Q: 用 VTK 的业务工程师需要写 shader 吗？**
   A: 默认不用——VTK 内置全套 GLSL，自动选 shader、编译、缓存、传 uniform；只有默认效果不够时才通过回调机制注入自定义片段（注入优于整套替换）。
6. **Q: VTK 的 shader 是每帧编译吗？预编译成二进制了吗？**
   A: 都不是。首次绘制时把内置 GLSL 文本交驱动现场编译一次，缓存 program 句柄后续复用；存的是文本不是二进制（Vulkan 后端例外，内置 SPIR-V）。
7. **Q: "第一次渲染某物体卡一下"，VTK 场景下怎么解释？**
   A: 首次编译+链接该物体的 shader program（运行时编译 GLSL 的固有成本）；解法是加载期 warm-up 或预编译缓存。
