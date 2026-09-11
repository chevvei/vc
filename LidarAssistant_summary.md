# LidarAssistant 项目总结

> 仓库路径：`/home/sti/proj/LidarAssistant`
> 简历关联：速腾聚创 - 项目一（激光雷达点云数据预处理与可视化平台）

---

## 1. 项目概述

LidarAssistant 是速腾聚创内部的激光雷达端到端数据处理工具链，涵盖原始点云采集、协议解析、实时可视化、设备诊断控制，作为感知算法研发的数据质控底座。

| 维度 | 说明 |
| ---- | ---- |
| 技术栈 | C++17、Qt5/Qt6、OpenGL、CMake、OpenSSL |
| 平台 | Linux (Ubuntu 20.04+) / Windows |
| 依赖 | QXlsx、MbedTLS、libpcap、QtKvaserCANBus、QtZLGCANBus |
| 项目类型 | 独立工具链（桌面应用 + CLI 工具） |
| 版本 | 1.8.0 |

---

## 2. 架构设计精华

### 2.1 模块化分层架构

```
src/
├── cli/                    # CLI 命令行工具（la_cli）——桥接层隔离 UI 依赖
│   ├── cli_main.cpp        # 入口 + 命令分发 + daemon/socket 通信
│   ├── CliOps.h/cpp        # 业务桥接层（调用 Dcm/DatM 单例）
│   └── CliLog.h/cpp        # 双输出日志（终端+文件）+ capture 机制
└── swc/                    # 软件组件（SWC）
    ├── Base/               # 基础类型定义
    ├── DatM/               # 数据管理器（核心单例）——配置读写
    ├── Dcm/                # 诊断通信管理器（核心单例）——连接收发
    ├── Drv/                # 激光雷达驱动（点云解码）——复用 rs_driver SDK
    ├── DoIP/               # DoIP 协议栈
    ├── Can/                # CAN 总线通信（Kvaser/ZLG 适配）
    ├── PointCloud/         # 点云 OpenGL 渲染
    ├── Image/              # 图像/点云渲染组件
    ├── LifeCycle/          # 生命周期管理（OTA/AES-GCM 加密）
    └── ...                 # 其他功能模块
```

**设计精华**：
- **双核心单例**：`Dcm`（诊断通信）+ `DatM`（数据配置），职责清晰，全局协调
- **桥接模式**：`CliOps` 隔离 UI 依赖，使同一套业务逻辑支持 GUI 和 CLI 两种交互方式
- **模块解耦**：20+ 软件组件各自独立，通过 Signal/Slot 观察者模式通信

### 2.2 设计模式应用

| 模式 | 应用位置 | 说明 |
| ---- | ---- | ---- |
| 单例 | `Dcm`, `DatM` | 全局唯一诊断/数据管理器 |
| 工厂 | `DecoderFactory`, `ShelterPlatformFactory` | 按型号创建解码器/平台适配 |
| 观察者 | Qt Signal/Slot | UI 与业务解耦 |
| 策略 | `IShelterPlatform` | 不同雷达型号的保护罩控制策略 |
| 桥接 | `CliOps` | CLI 桥接层隔离 UI 依赖 |
| 适配器 | `CanBus` (Kvaser/ZLG) | 多厂商 CAN 设备适配 |

---

## 3. 核心技术模块详解

### 3.1 激光雷达驱动（Drv）——点云解码引擎

**位置**：`src/swc/Drv/driver/`

**架构**：复用 rs_driver SDK，三组件设计
- `Input`：数据采集（epoll 多路复用 / pcap 离线 / USB）
- `Decoder`：协议解析（MSOP/DIFOP → 点云）
- `LidarDriverImpl`：编排调度（双队列生产者-消费者模型）

**工厂模式支持 40+ 型号**：
```
decoder_factory.hpp → DecoderFactory::createDecoder(LidarType, param)
支持：RS16/RS32/RS48/RS80/RS128/RSBP/RSHELIOS/RSP48/RSP80/RSP128
      RSM1/RSM1_Jumbo/RSM1_Bar/RSM1_Mirror/RSM2/RSM2_Mirror/RSM3_0800
      RSMX/RSMX1404/RSE1/EM4_GRAY/EM4_HIST/EMX_GRAY/EMX_HIST/EMX_MEMS
      E2_GRAY/E2_HIST/E2_0610/E2_0611/E2_2520/AC2_GRAY/AC2_CMOS/AC2_Hist
```

**输入层多路复用**（`input_sock_epoll.hpp`）：
- Linux 使用 epoll，Windows 使用 select
- 非阻塞 socket + `SO_REUSEADDR` + 可选多播组 (`IP_ADD_MEMBERSHIP`)
- 支持 user_layer / tail_layer 字节偏移（VLAN 等自定义层）

### 3.2 点云实时渲染（PointCloud）——OpenGL 可视化

**位置**：`src/swc/PointCloud/PointCloud.h`

**实现**：
- 基于 `QOpenGLWidget` + `QOpenGLFunctions_3_3_Core`
- 自定义着色器程序 (`QOpenGLShaderProgram`)
- `VertexData` 结构：位置 (x,y,z) + 颜色 (r,g,b)
- 支持坐标轴、网格线、点数据绘制
- 鼠标交互：旋转、平移、缩放
- 百万级点云流畅渲染

### 3.3 DoIP 协议栈（DoIP）——ISO 13400 实现

**位置**：`src/swc/DoIP/DoIP.h`

**实现**：
- 完整 DoIP payload type 定义（0x0001-0x8003）
- 车辆标识请求/响应、路由激活、存活检查、诊断消息
- 错误码体系（NACK / 诊断 NACK）
- 超时管理：激活超时 60s，接收超时 5000ms
- 基于 `QTcpServer` / `QTcpSocket`

### 3.4 安全 OTA（LifeCycle）——AES-GCM 加密

**位置**：`src/swc/LifeCycle/AesGcm.h`

**实现**：
- 基于 OpenSSL EVP 接口
- 支持 AES-128/192/256-GCM
- HKDF 密钥派生
- 完整的加密结果结构（ciphertext + iv + tag）
- 用于 OTA 固件传输安全保护

### 3.5 配置驱动框架（DatM）——Excel 配置引擎

**位置**：`src/swc/DatM/DatM.cpp`

**实现**：
- 基于 QXlsx 读取 xlsx 配置文件
- 每个雷达型号一个项目目录，包含 9 类 xlsx 配置
- 配置项包括：DoIP 网络参数、DID 默认值、命令配置、内存映射、寄存器列表等
- 动态加载，无需重新编译即可适配新设备

---

## 4. 高性能工程实现

### 4.1 SPSC 无锁环形队列

**位置**：`src/swc/util/lockFreeQueue.hpp`

**是什么**：单生产者单消费者（SPSC）无锁队列，基于 `std::atomic` 实现

**为什么**：传统互斥锁在高频数据交换场景下存在上下文切换开销和锁竞争，成为性能瓶颈

**怎么设计**：
- 环形缓冲区，容量必须为 2 的幂（用 `static_assert` 约束）
- `head`/`tail` 使用 `alignas(64)` cache line 对齐，消除伪共享
- 用位运算 `(currentTail + 1) & (Capacity - 1)` 替代取模 `%`
- 生产者用 `memory_order_release`，消费者用 `memory_order_acquire`，建立 happens-before 关系

**解决什么**：
- 消除锁竞争导致的性能下降
- 避免伪共享导致的 cache line 失效
- 降低数据交换延迟

**效果**：
- 多线程数据交换无锁化
- cache 命中率提升
- 适合点云数据高吞吐场景

### 4.2 epoll 多路复用数据采集

**位置**：`src/swc/Drv/driver/input/unix/input_sock_epoll.hpp`

**是什么**：基于 Linux epoll 的非阻塞 socket 数据接收

**为什么**：激光雷达 MSOP/DIFOP 数据包高频到达，阻塞式 IO 无法同时处理多路数据流

**怎么设计**：
- `epoll_create` + `epoll_ctl(EPOLL_CTL_ADD)` 注册 MSOP/DIFOP 两个 fd
- `EPOLLIN` 水平触发模式
- `fcntl(F_SETFL, O_NONBLOCK)` 设置非阻塞
- 独立 `recv_thread_` 循环 `epoll_wait`，超时 1000ms

**解决什么**：
- 多路 socket 并发接收
- 避免单路阻塞影响全局
- 超时检测（MSOP 丢包告警）

### 4.3 CLI daemon 架构

**位置**：`src/cli/cli_main.cpp`

**是什么**：通过 `QLocalServer` (Unix socket) 提供 daemon 模式，支持多命令复用连接

**四种运行模式**：Standalone / Daemon / Script / Shell

**设计亮点**：
- 连接看门狗：每 5s 检查，断线自动重连
- 错误恢复：每条命令后自动清理 `bBusy`
- Script 批量模式支持自动化测试

---

## 5. 工程难点与问题复盘

### 难点 1：多型号雷达设备兼容适配

- **是什么**：需要支持 40+ 型号激光雷达，每款设备的协议、参数、寄存器都不同
- **为什么**：雷达产品线迭代快，每次新增型号都要适配，传统硬编码方式维护成本高
- **怎么设计**：
  - 工厂模式 + 模板方法：`DecoderFactory` 按 `LidarType` 枚举创建对应解码器
  - 配置驱动：网络参数、寄存器 Map、DID/RID 定义全部抽象为 xlsx 配置项
  - 反射机制 + 动态加载：一套代码支持多型号"零代码"适配
- **解决什么**：新增雷达型号无需修改代码，只需配置 xlsx
- **效果**：新设备接入效率提升 80%

### 难点 2：百万级点云实时渲染

- **是什么**：高端激光雷达单帧点云可达百万级，需要流畅渲染和交互
- **为什么**：传统逐点绘制方式无法满足实时性要求
- **怎么设计**：
  - OpenGL 3.3 Core + 着色器程序
  - VBO 批量提交顶点数据
  - 自定义着色器实现颜色映射
- **解决什么**：百万级点云流畅显示
- **效果**：支撑点云质量评估（遮挡检测、噪声分析）

### 难点 3：车载诊断通信跨平台兼容

- **是什么**：同一套 UDS/DoIP 代码需要运行在 Windows 调试工具、Linux 车载系统、嵌入式平台
- **为什么**：不同平台的 socket API、编译器、字节序处理存在差异
- **怎么设计**：
  - 条编译隔离平台差异（`#ifdef _WIN32`）
  - 抽象适配层屏蔽底层传输细节
  - 统一的 C++ API 接口
- **解决什么**：一套代码三平台运行
- **效果**：降低跨平台集成复杂度

---

## 6. AI / 感知方向关联

| 关联点 | 说明 |
| ---- | ---- |
| 点云数据流水线 | MSOP/DIFOP 解码 → 点云构建 → 可视化，是感知数据预处理的基础 |
| 数据质量分析 | 灰度图、强度直方图、遮挡检测，为感知训练数据集提供质控 |
| 多传感器数据采集 | epoll 多路复用可扩展为多传感器同步采集 |
| 高性能并发架构 | 无锁队列、epoll、内存池，是 AI 推理管线的基础设施 |
| 配置驱动框架 | 可扩展为感知模型的参数配置管理 |

---

## 7. 简历可用素材

**项目定位**：激光雷达点云数据预处理与可视化平台

**STAR bullet 要点**：
1. 设计并开发激光雷达端到端数据处理工具链，涵盖数据采集、协议解析、实时可视化、设备诊断，作为感知算法研发的数据质控底座
2. 基于 epoll 实现 MSOP/DIFOP 协议数据包非阻塞多路复用接收；通过工厂模式构建 40+ 型号雷达解码器框架，新设备接入效率提升 80%
3. 基于 OpenGL 3.3 Core + 自定义着色器开发百万级点云实时渲染引擎，集成灰度图、强度直方图等可视化组件，支撑数据质量评估
4. 设计实现 SPSC 无锁环形队列，采用 cache line 对齐消除伪共享，位运算优化替代取模，显著降低多线程锁竞争开销
5. 实现 AES-GCM 加密 OTA 升级模块、AUTOSAR UDS 诊断服务、自动化批量测试脚本引擎

---

## 8. 面试高频追问预判

1. **无锁队列**：`memory_order_acquire/release` 语义？为什么用 cache line 对齐？伪共享是什么？
2. **epoll**：LT 和 ET 模式区别？为什么选 LT？epoll 内部如何管理 fd？
3. **工厂模式**：如何扩展新型号？模板方法 vs 策略模式的取舍？
4. **OpenGL 渲染**：VBO 和 VAO 的关系？着色器如何编译链接？如何优化百万级点的渲染？
5. **DoIP 协议**：路由激活流程？Alive Check 机制？粘包如何处理？
6. **AES-GCM**：为什么选 GCM 而不是 CBC？tag 的作用是什么？HKDF 的用途？
7. **CLI daemon**：Unix socket vs TCP socket 的取舍？看门狗如何实现？
