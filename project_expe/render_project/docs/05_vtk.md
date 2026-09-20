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

## 五、什么时候用 VTK（决策）

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

## 七、面试讲法（30 秒版）

> VTK 是科学可视化工具包，和游戏引擎的根本区别是它管"数据流水线"
> 而非"场景图"：Source 读入 vtkDataSet（点云对应 vtkPolyData），
> Filter 串接加工（平滑/裁剪/等值面），Mapper 决定颜色映射，Actor
> 进渲染器，底层默认用 OpenGL。它的价值是上百个现成 Filter 和
> Mapper（尤其体绘制），几十行代码出可交互三维图，是医学影像、
> CFD、点云工具（ParaView/PCL）的地基。代价是抽象税和渲染定制
> 天花板，追求帧率的游戏场景不选它。

## 八、自检问答

1. **Q: VTK 和 Unity 都是"3D 引擎"，本质区别？**
   A: 数据模型不同：VTK 是数据流水线（Filter 加工数据），Unity 是场景图（物体+物理+资产）；前者优化"科学数据→准确图"，后者优化"美术资产→实时画面"。
2. **Q: 点云在 VTK 里是什么数据类型？**
   A: vtkPolyData（只有 points 没 cells 的退化形式）。
3. **Q: VTK 的体绘制用的是什么算法思想？**
   A: Ray casting 逐像素沿视线采样合成（光线追踪思想，但只穿体数据不需要求交场景几何）。
4. **Q: 为什么 LidarAssistant 不用 VTK 而手写 OpenGL？**
   A: 定制自由度 + 轻量依赖 + 性能可控；VTK 的通用 Mapper 抽象税对单一点云场景是负资产。
