# 岗位描述 Job Description

> 岗位定位：**大模型 / 多模态 VLM 嵌入式 NPU 量化部署工程师**
> 核心工作：LLM/VLM 在嵌入式端 PTQ/QAT 量化、量化工具体系建设、模型精度性能闭环调优。

---

## 一、岗位职责（JD 原文）

1. 深度学习模型（含 LLM / VLM / 视觉多任务）在嵌入式 NPU / DSP 平台的量化部署，覆盖 PTQ / QAT 全流程，负责精度对齐与性能达标；
2. 量化工具链开发与优化（W4A8 / INT8 / FP8），推动业界前沿方案（AWQ、GPTQ、SmoothQuant、KV cache 量化等）在自研平台落地；
3. 与算法、芯片、编译团队协作，反馈量化友好的模型结构建议，闭环解决精度掉点、算子不支持、性能瓶颈；
4. 沉淀量化部署方法论与自动化工具，支撑多机型 / 多平台规模化交付。

## 二、任职要求（JD 原文）

1. 熟练掌握 Python，熟悉 C/C++，具备良好工程能力；
2. 精通 PyTorch，熟悉计算图分析、算子改写、模型转换（ONNX 等）；
3. 深入理解量化原理：对称/非对称、per-channel/per-tensor、Observer/Calibration、weight-only vs activation 量化、混合精度；
4. 熟悉至少一款推理引擎或部署框架（TensorRT / ONNX Runtime / TVM / MNN / TFLite / 自研 NPU 编译器）。

---

## 三、岗位职责逐条拆解 + 现状对齐

| # | 岗位要做什么 | 我的已有基础 | 缺口 |
| --- | --- | --- | --- |
| 1 | LLM/VLM/视觉多任务在 NPU/DSP 量化部署，PTQ/QAT，精度对齐+性能达标 | 医学图像分割、点云模型 TensorRT 部署，做过模型部署与精度性能调优 | 大语言模型、VLM 多模态、QAT 训练侧量化经验 |
| 2 | 量化工具链：W4A8/INT8/FP8；AWQ/GPTQ/SmoothQuant/KV-Cache 量化落地自研平台 | 普通 CV 模型 INT8 PTQ | **最大缺口**：大模型专用量化（GPTQ/AWQ/KV-Cache） |
| 3 | 协同算法/芯片/编译团队，闭环解决精度掉点、算子不支持、性能瓶颈 | ✅ 速腾工具链与硬件/算法协同定位 bug；迈瑞算子适配、精度损失调参 | 匹配度高，可直接复用 |
| 4 | 沉淀自动化量化部署工具，支撑多机型规模化交付 | ✅ 激光雷达工具链、自动化脚本、流水线工程化沉淀 | 匹配度高，可直接复用 |

## 四、任职要求逐条分析

| 要求 | 现状 | 需补强 |
| --- | --- | --- |
| Python 熟练，熟悉 C/C++ | ✅ 很强，两大公司均 C++ 工程开发 | Python 做量化工具脚本；C++ 实现自定义算子、推理侧算子 |
| 精通 PyTorch；计算图分析、算子改写、ONNX 转换 | 懂 PyTorch，做过模型转换 | 图遍历、算子替换、ONNX 修改、算子实现 |
| 量化原理：对称/非对称、per-channel/per-tensor、Observer/Calibration、weight-only、混合精度 | 懂基础 INT8 量化 | **重点**：大模型 Weight-Only、AWQ/GPTQ 原理、KV-Cache 量化 |
| 至少一款推理引擎（TensorRT/ONNXRuntime/TVM/MNN/TFLite/NPU 编译器） | ✅ 会 TensorRT | 补 TVM 或 NPU 编译链路，理解算子编译、图优化 |

## 五、核心总结

- **巨大优势**：CV 部署、C++ 工程、工具链开发、硬件端到端链路。很多做量化的人只有 Python，缺少底层工程经验——这是差异化竞争力。
- **主要差距**：大模型（VLM+LLM）整套量化技术栈（GPTQ/AWQ、W4A8、KV-Cache、QAT），缺少端到端完整项目经历。
- **补齐路径**：通过「VLM 多模态大模型端侧量化部署项目」（见 `plan_table.md`）覆盖岗位 90% 技术点。

---

## 六、我的背景速览

| 公司 | 领域 | 技术栈 |
| --- | --- | --- |
| 迈瑞 | 超声 3D 成像、OpenGL 三维重建、医学图像分割 | CV、三维视觉、C++、PyTorch → ONNX → TensorRT INT8 |
| 速腾聚创 | 激光雷达点云、数据流水线、硬件传感器链路 | Linux C++、TensorRT、工程化工具链开发 |

## 七、高频面试预判

1. PTQ 与 QAT 的区别，什么时候用 QAT？
2. 大模型为什么要用 Weight-Only W4A8，不能直接 INT8 PTQ？AWQ 和 GPTQ 原理差异？
3. KV-Cache 量化的收益？精度风险？
4. 量化后精度暴跌，排查思路？
5. 自研 NPU 有算子不支持，如何与算法、编译团队闭环解决？
