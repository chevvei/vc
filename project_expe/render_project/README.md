# render_project — 3D 渲染知识体系

> 目标：不是背概念，而是**讲得清来龙去脉、答得出"什么场景用什么技术"**。
> 风格：深入浅出，生活类比先行，具体数字说话，不讲抽象空话。

## 文档地图（按学习顺序）

| 顺序 | 文档 | 讲什么 | 一句话核心 |
|---|---|---|---|
| 1 | [00_big_picture](docs/00_big_picture.md) | 3D 渲染全景 | 屏幕上的 3D 是数学骗局；两大流派 40 年战争 |
| 2 | [01_rasterization](docs/01_rasterization.md) | 光栅化 | 把三角形"投影+涂满"，快但不真实 |
| 3 | [02_ray_tracing](docs/02_ray_tracing.md) | 光线追踪 | 从像素反着"问"世界，真实但贵 |
| 4 | [03_opengl](docs/03_opengl.md) | OpenGL | 30 年图形 API 老将：状态机哲学 |
| 5 | [04_vulkan](docs/04_vulkan.md) | Vulkan | 显式控制哲学：1500 行画一个三角形 |
| 6 | [05_vtk](docs/05_vtk.md) | VTK | 科学可视化框架：和游戏引擎不是一回事 |
| 7 | [06_shader](docs/06_shader.md) | Shader 编程 | 给 GPU 写的小程序；GPU 本为它而生 |
| 8 | [07_3dgs](docs/07_3dgs.md) | 球谐函数 + 3DGS | 高斯雪球叠加：新渲染范式，NeRF 的实用化 |
| 9 | [08_decision_map](docs/08_decision_map.md) | 决策地图 | 场景 → 技术选择速查表 + 面试话术 |

## 知识依赖图

```
00 全景（必读， establishes 地图）
├── 01 光栅化 ──┐
│              ├──→ 06 Shader（管线的可编程阶段，两边都要懂）
├── 02 光线追踪 ─┘
├── 03 OpenGL ←─┐
│              ├──→ 04 Vulkan（对比着学，单独背是背不住的）
├── 05 VTK（站在 OpenGL 肩膀上的框架层）
└── 07 3DGS（用到了 01 的光栅化思想 + 排序 + 球谐数学）
        │
        └── 08 决策地图（收口：全部串成"什么场景用什么"）
```

## 与 cuda_project 的知识挂钩

GPU **本来就是为图形学发明的**（1999 GeForce 256 的卖点叫"GPU"，
就是硬件 T&L——Transform & Lighting，光栅化的两个步骤）。
你在 cuda_project 学的每个概念都有图形学出身：

| CUDA 概念 | 图形学出身 |
|---|---|
| warp（32 线程同指令） | fragment shader 天然按 2×2 像素块（quad）调度 |
| SM 内 smem | 早期是纹理缓存 |
| 压缩纹理/硬件插值 | 光栅化 "varying" 插值的硬件电路 |
| CUDA stream | Vulkan command buffer 的直接前辈 |
| unified memory | 图形 API 先做的 zero-copy |

所以学渲染 = 学 CUDA 的"出厂设置"。

## 学习验收标准（自测）

读完本体系，你应该能不查资料回答：

1. 为什么实时光追 2018 年才普及，而电影光追用了 30 年？（硬件专用化）
2. 画同一个三角形，OpenGL 100 行，Vulkan 1500 行，多出来的 1400 行在干什么？
3. 为什么游戏用光栅化、电影用光追、3DGS 突然火？（各自的最优化目标不同）
4. VTK 和 Unity 都是"3D 引擎"，为什么完全不可互换？（数据模型 vs 场景模型）
5. 球谐函数到底解决什么问题？（视角相关外观的压缩表示）
