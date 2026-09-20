# 03 — OpenGL：30 年图形 API 老将

## 一、先定位：OpenGL 是"指挥 GPU 的说明书"

OpenGL **不是**软件、不是引擎、不是库——它是一份** API 规范**（约 300 页 PDF），
规定了一组 C 函数的名字和行为（glDrawArrays、glBindBuffer…）。
显卡驱动负责实现这份规范。你调 `glDrawArrays`，驱动翻译成 GPU 指令。

```
你的代码 → OpenGL API（规范）→ 驱动（实现）→ GPU
```

出身：1992 年 SGI（做图形工作站的贵族）把它从自家私有 API
（IRIS GL）开放出来，统一了 Unix 工作站图形市场。
那个年代的定位：**CAD/科学可视化**，不是游戏。

## 二、核心心智模型：一台"状态机"

OpenGL 最重要的一个理解：它是一台**巨大的隐式状态机**。

```c
// 你以为在"调用函数"，实际在"拨开关 + 塞参数"
glEnable(GL_DEPTH_TEST);              // 开关：打开深度测试
glBindBuffer(GL_ARRAY_BUFFER, vbo);   // 旋钮：当前绑定 VBO = 7号
glVertexAttribPointer(...);           // 对"当前绑定"的对象设置属性
glDrawArrays(GL_TRIANGLES, 0, 3);     // 按当前所有状态画
```

**没有对象参数传递，一切靠"当前状态"**——这就是老代码又长又碎的原因：
画一个东西前要摆好十几个开关。好处是 API 简单统一，坏处是状态散落
在全局，出了错不知道是哪个开关没拨对。

## 三、画一个三角形的最小流程（现代版）

```c
// 1. 建缓冲：把顶点数据从内存搬到显存
glGenBuffers(1, &vbo);
glBindBuffer(GL_ARRAY_BUFFER, vbo);
glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);

// 2. 建顶点数组对象（VAO）：记录"顶点属性怎么读缓冲"
//    （OpenGL 3.3 核心模式强制：属性配置必须存进 VAO）
glGenVertexArrays(1, &vao);
glBindVertexArray(vao);
glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 12, 0);
glEnableVertexAttribArray(0);

// 3. 编译 shader（顶点+片段），链接成程序
//    （GLSL 源码字符串编译，见 06 篇）

// 4. 每帧：绑 VAO、用 shader program、发绘制命令
glBindVertexArray(vao);
glUseProgram(prog);
glDrawArrays(GL_TRIANGLES, 0, 3);   // ← 就这一行真正画
```

记住四个对象的名字和作用，OpenGL 就懂了一半：

| 对象 | 生活类比 | 作用 |
|---|---|---|
| VBO（Vertex Buffer Object） | 仓库货架 | 显存里放顶点数据 |
| VAO（Vertex Array Object） | 提货单 | 记录"哪个缓冲、怎么解读（布局）" |
| Texture | 贴纸 | 显存里放图片 |
| Shader Program | 流水线工人的操作手册 | 你写的 GPU 小程序 |

## 四、OpenGL 的历史包袱（为什么被 Vulkan 取代）

理解"为什么有 Vulkan"（04 篇）= 理解 OpenGL 的四个结构性问题：

1. **驱动黑盒**：内存怎么放、指令怎么调度全由驱动猜。
   同一份代码在不同厂商驱动上性能差 2~5 倍，你还无法干预。
2. **单线程瓶颈**：context 绑定单线程，主线程一边组装渲染命令一边
   只能干等；多核 CPU 的其余 15 个核在看戏。
3. **全局状态机**：任何模块都可能偷偷改状态，调试地狱。
4. **抽象泄漏的老 API**：30 年增量补丁（1992 年的设计容纳 2015 年的
   需求），Immediate Mode（glBegin/glEnd）→ VBO → VAO 层层叠叠，
   新手教程一半在讲"哪些是历史垃圾别学"。

**但它没死**，因为：
- **简单**：100 行画三角形 vs Vulkan 1500 行（04 篇对比）
- **到处都有**：Windows/Linux/macOS(已弃)/WebGL(网页)/Android ES
- **老资产遍地**：CAD/科研/工业软件 30 年积累，改不动也不想改
  （LidarAssistant 的点云渲染就是 Qt+OpenGL——点云场景简单，
  OpenGL 的性能上限绰绰有余，换成 Vulkan 纯属自虐）

## 五、家族谱系（分清这些名字）

| 名字 | 关系 | 一句话 |
|---|---|---|
| OpenGL | 本尊 | 桌面版，1992 |
| OpenGL ES | 儿子 | 嵌入式裁剪版（手机/嵌入式），2003 |
| WebGL | 孙子 | OpenGL ES 映射到浏览器 JS，2001→2011 |
| WebGL2 / WebGPU | 孙子+ | WebGPU ≈ Vulkan 思想进浏览器（2023+） |
| GLSL | 配套语言 | OpenGL 的 shader 语言（见 06） |

## 六、什么场景用 OpenGL（决策）

用 OpenGL，当：
- **学习图形学**：概念最少干扰最小，全世界教程最全（LearnOpenGL.com）
- **工具类/科学可视化**：Qt+OpenGL 是桌面点云/医学影像标配，
  性能上限远未触及
- **跨平台简单渲染**：不想为 1500 行初始化买单
- **维护存量代码**：行业三十年积累

不用 OpenGL，当：
- 要榨干 GPU、精确控制显存/同步 → Vulkan（04）
- 做科研可视化，连 OpenGL 都不想碰 → VTK（05，它替你封装了）
- 苹果平台 → Metal（苹果 2018 年弃用 OpenGL）

## 七、面试讲法（30 秒版）

> OpenGL 是 1992 年 SGI 开放的图形 API 规范，心智模型是一台全局状态机：
> 绑定 VBO/VAO/Texture 设置状态，glDrawArrays 触发管线，中间可编程阶段
> 跑 GLSL shader。它的优点是简单、跨平台、生态三十年沉淀，是工具类软件
> 和点云可视化的合理选择；结构性缺陷是驱动黑盒、单线程 context、全局
> 状态难调试，这些正是 Vulkan 2016 年用显式 API 针对性解决的。我做过
> Qt+OpenGL 点云渲染，那类场景 OpenGL 性能上限远未触及，没有理由用 Vulkan。

## 八、自检问答

1. **Q: OpenGL 是引擎吗？和 VTK 什么关系？**
   A: 不是，是驱动层的 API 规范；VTK 是上层框架，内部调 OpenGL。
2. **Q: VBO 和 VAO 为什么是两个对象？**
   A: VBO 是数据仓库（存顶点），VAO 是提货单（记录怎么解读哪个缓冲的布局）；分离后同一种数据可以多种解读。
3. **Q: OpenGL 为什么被诟病多线程差？**
   A: context 与线程绑定，渲染命令只能单线程提交；Vulkan 的 command buffer 可多线程并发录制再统一提交。
4. **Q: glBegin/glEnd 为什么是垃圾？**
   A: Immediate Mode 每顶点一次函数调用走总线，1992 年的遗产；现代模式一次 glDrawArrays 让 GPU 从显存 VBO 自己取数。
