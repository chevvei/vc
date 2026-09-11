# udslib 项目总结

> 仓库路径：`/home/sti/project/udslib`
> 简历关联：速腾聚创 - 项目二（跨平台高可靠 AUTOSAR UDS 通信中间件）

---

## 1. 项目概述

udslib 是一个独立于 LidarAssistant 的跨平台 UDS（ISO 14229）/ DoIP（ISO 13400）诊断通信库，提供完整的车辆诊断协议栈，支持 ECU 刷写、DID 读写、安全访问、例程控制等服务，可集成到各类车载诊断工具和产线测试系统。

| 维度 | 说明 |
| ---- | ---- |
| 技术栈 | C++17、CMake、spdlog（日志）、nlohmann/json（配置）、OpenSSL（加密） |
| 平台 | Linux / Windows（跨平台 socket 抽象） |
| 依赖 | spdlog、nlohmann/json、libcurl（可选） |
| 项目类型 | 通信中间件（静态/动态库） |
| 版本演进 | v1.0.0 → v1.1.6（12 个版本迭代） |

### 版本演进精华（CHANGELOG 摘要）

| 版本 | 关键演进 |
| ---- | ---- |
| v1.0.0 | 初始版本：UDS/DoIP 基础服务 |
| v1.1.0 | 引入 JSON 配置驱动、密钥库动态加载 |
| v1.1.1 | 支持 OEM 自定义参数、Hex 解析器 |
| v1.1.2-1.1.3 | 强化错误恢复、超时重试 |
| v1.1.4 | CRC32 完整性校验、日期 BCD/ASCII 编码 |
| v1.1.5 | Seed-Key DLL/.so 动态加载机制 |
| v1.1.6 | 性能优化、粘包处理增强 |

---

## 2. 架构设计精华

### 2.1 分层架构

```
┌─────────────────────────────────────────────┐
│  应用层  demo / LidarAssistant / 产线工具     │
├─────────────────────────────────────────────┤
│  API 层  UdsClient / DoIPClient              │
├─────────────────────────────────────────────┤
│  协议层  udsImpl / doipImpl                  │
├─────────────────────────────────────────────┤
│  数据层  DatM（配置管理）                     │
├─────────────────────────────────────────────┤
│  工具层  hexParser / jsonParser / crc32      │
│          networkUtil / stringUtil / timeUtil │
├─────────────────────────────────────────────┤
│  日志层  rs_logger（封装 spdlog）             │
└─────────────────────────────────────────────┘
```

### 2.2 模块组织

```
src/
├── uds/
│   ├── udsImpl.h/cpp      # UDS 协议实现（核心）
│   └── udsClient.cpp      # 对外 API 封装
├── doip/
│   ├── doipImpl.h/cpp     # DoIP 协议实现
│   └── doipClient.cpp     # 对外 API 封装
├── datm/
│   └── datm.h/cpp         # 数据/配置管理
├── common/
│   ├── hexParser.*        # Hex 文件解析（OTA 固件）
│   ├── jsonParser.*       # JSON 配置解析
│   ├── rs_crc32.h         # CRC32 校验
│   └── rs_log.h           # 日志封装
├── util/
│   ├── networkUtil.h      # 网络工具
│   ├── stringUtil.h       # 字符串工具
│   ├── numberUtil.h       # 数值转换
│   ├── timeUtil.h         # 时间工具
│   ├── fileUtil.h         # 文件操作
│   └── tool.h             # 通用工具
└── macro/
    └── version.hpp        # 版本宏
```

---

## 3. 核心技术模块详解

### 3.1 UDS 协议实现（udsImpl）

**完整 UDS 服务支持**：
- `0x10` DiagnosticSessionControl（会话切换）
- `0x11` ECU Reset（复位）
- `0x22` ReadDataByIdentifier（读 DID）
- `0x27` SecurityAccess（安全访问 Seed-Key）
- `0x2E` WriteDataByIdentifier（写 DID）
- `0x31` RoutineControl（例程控制）
- `0x34` RequestDownload（请求下载）
- `0x36` TransferData（数据传输）
- `0x37` RequestTransferExit（退出传输）
- `0x3E` TesterPresent（保活）

**关键设计**：
- `SUPPRESS_POS_RSP_SUPPORTED_SIDS` 集合：支持抑制肯定响应的服务白名单
- `Command` 枚举：Delay / Connect / Disconnect / Load / SelectKeyLib / TransferData / JumpTo
- 会话超时：`SESSIOIN_TIMEOUT_SEC = 3`
- 接收超时：`UDS_RECV_TIMEOUT = 600000ms`
- 缓冲区：`R_BUFFER_MAX_SIZE = 64KB`，`TMP_BUF_SIZE = 2048`

### 3.2 Seed-Key 动态密钥库（安全访问核心）

**是什么**：通过运行时动态加载 DLL（Windows）/ .so（Linux）实现安全访问算法

**为什么**：不同 OEM / 不同 ECU 的 Seed-Key 算法不同且保密，不能硬编码

**怎么设计**：
- 函数指针类型 `CalKeyFromSeedInputFun` 定义算法接口
- 支持两种签名：基于 Seed、基于 Seed+DID
- 通过 `dlopen` / `LoadLibrary` 动态加载
- `SelectKeyLib` 命令运行时切换密钥库
- 密钥缓冲区 `SECURITY_KEY_SIZE = 512`

**解决什么**：同一套代码适配不同 OEM 的安全算法，无需重新编译

### 3.3 DoIP 协议实现（doipImpl）

**完整 DoIP payload type**：0x0001-0x8003

**关键参数**：
- `SOCKET_SEND_TIMEOUT = 2000ms`，`SOCKET_RECV_TIMEOUT = 2000ms`
- `DOIP_MAX_CONNECT_TRIES = 3`，`DOIP_RECONNECT_DELAY_TIME_MS = 3000ms`
- `DOIP_RECV_TIMEOUT = 5000ms`
- `BIN_BLOCK_SIZE = 0x20000`（128KB，OTA 数据块）

**缓冲区设计**（精妙）：
```
DOIP_BUFFER_SIZE = 2920 + BIN_BLOCK_SIZE + 1460
// 2920:  2×MTU 存储常规 DoIP 消息
// 128K:  BIN_BLOCK_SIZE 存储 36 服务 OTA 数据
// 1460:  存储粘包 DoIP 消息
```

**跨平台 socket 抽象**：
- Windows：`ws2tcpip.h`、`WS2_32.lib`
- Linux：`arpa/inet.h`、`sys/socket.h`、`fcntl.h`
- 统一 `ssize_t` 类型处理

### 3.4 Hex 文件解析（OTA 固件处理）

**位置**：`src/common/hexParser.h/cpp`

**功能**：解析 Intel Hex 格式固件文件，提取二进制数据用于 OTA 刷写

**支持**：
- Intel Hex 格式（:LLAAAATT[DD...]CC）
- 数据记录（00）、结束记录（01）、扩展线性地址（04）
- 地址拼接（基础地址 + 偏移）
- CRC32 完整性校验（`rs_crc32.h`）

### 3.5 JSON 配置驱动（datm）

**配置项前缀**：
- `JsnPa.`：JSON 参数
- `PrcPa.`：处理参数

**预定义参数键**：
- `maxNumberOfBlockLength`：OTA 分块大小
- `loadedImageSize` / `loadedImageAddress`：固件加载信息
- `DATE_BCD_YYYYMMDD` / `DATE_ASSICII_YYYYMMDD`：日期编码格式
- `DATE_BCD_YYMMDDHH` / `DATE_ASSICII_YYMMDDHH`：时间戳格式
- `CalKeyFromSeedInput`：密钥算法函数名

---

## 4. 高性能工程实现

### 4.1 OTA 数据分块传输

**是什么**：将大固件分块传输，每块 `BIN_BLOCK_SIZE = 128KB`

**为什么**：DoIP/TCP 单次传输有 MTU 限制，大固件需要分块

**怎么设计**：
- 分块大小 `0x20000`（128KB）
- `TransferData` 命令循环发送
- 块序号管理（1-255 循环）
- CRC32 校验完整性

### 4.2 粘包处理

**是什么**：TCP 流式传输可能产生粘包，需要正确拆分 DoIP 消息

**怎么设计**：
- 三段式缓冲区设计（常规 + OTA + 粘包）
- `DOIP_TCP_RECV_TEMP_SIZE = 4 * 1460`（4×MTU）
- 基于 DoIP 头部长度字段拆包

### 4.3 重连与错误恢复

- 最大连接重试 `DOIP_MAX_CONNECT_TRIES = 3`
- 重连延迟 `DOIP_RECONNECT_DELAY_TIME_MS = 3000ms`
- 接收超时 `DOIP_RECV_TIMEOUT = 5000ms`
- `NRC_BusyRepeatRequest = 0x78` 忙碌重试

---

## 5. 工程难点与问题复盘

### 难点 1：跨平台 socket 兼容

- **是什么**：Windows Winsock 和 Linux POSIX socket API 存在差异
- **为什么**：需要一套代码同时支持两个平台
- **怎么设计**：
  - `#ifdef _WIN32` 条件编译
  - 统一 `ssize_t` 类型（Windows 用 `using ssize_t = int`）
  - `WIN32_LEAN_AND_MEAN` 减少 Windows 头文件污染
  - 统一的错误码处理
- **解决什么**：一套代码两平台运行
- **效果**：降低维护成本，方便嵌入式移植

### 难点 2：OTA 刷写可靠性

- **是什么**：固件刷写过程中断线、超时、数据错误需要可靠恢复
- **为什么**：刷写失败可能导致设备变砖
- **怎么设计**：
  - 分块传输 + 块序号管理
  - CRC32 完整性校验
  - 重连机制（3 次重试，3s 延迟）
  - 会话超时检测
  - 完整的 UDS 36/37 服务序列
- **解决什么**：保证刷写成功率
- **效果**：支持产线批量刷写

### 难点 3：OEM 密钥算法适配

- **是什么**：不同 OEM 的安全访问算法不同且保密
- **为什么**：不能硬编码，需要灵活适配
- **怎么设计**：
  - 动态库加载（DLL/.so）
  - 函数指针类型定义统一接口
  - 运行时 `SelectKeyLib` 切换
  - 支持两种签名（Seed / Seed+DID）
- **解决什么**：一套代码适配多 OEM
- **效果**：提升复用性

---

## 6. AI / 感知方向关联

| 关联点 | 说明 |
| ---- | ---- |
| OTA 模型部署 | UDS 36 服务可扩展为 AI 模型权重刷写 |
| 传感器配置管理 | DID 读写可管理感知传感器参数（外参、内参） |
| 数据完整性 | CRC32 + AES-GCM 可用于模型文件校验 |
| 嵌入式部署 | 跨平台设计适合边缘设备集成 |
| 高可靠通信 | 重连/重试机制可用于感知数据链路保活 |

---

## 7. 简历可用素材

**项目定位**：跨平台高可靠 AUTOSAR UDS 通信中间件

**STAR bullet 要点**：
1. 独立设计开发跨平台 UDS（ISO 14229）/ DoIP（ISO 13400）诊断通信库，完整实现 10+ UDS 服务，支持 ECU 刷写、DID 读写、安全访问、例程控制
2. 设计 Seed-Key 动态密钥库加载机制，通过运行时加载 DLL/.so 适配不同 OEM 的安全算法，实现一套代码多厂商复用
3. 实现 OTA 固件分块传输（128KB/块）+ CRC32 完整性校验 + 三段式粘包处理缓冲区，保证刷写可靠性
4. 跨平台 socket 抽象层（Windows Winsock / Linux POSIX），一套代码支持两个平台，降低维护成本
5. 基于 spdlog 封装异步日志系统，12 个版本持续迭代（v1.0.0 → v1.1.6），支持 JSON 配置驱动

---

## 8. 面试高频追问预判

1. **UDS 27 服务**：Seed-Key 流程？为什么要动态加载？函数指针如何定义？
2. **DoIP 协议**：路由激活流程？Alive Check 机制？payload type 有哪些？
3. **OTA 刷写**：34/36/37 服务序列？块序号如何管理？刷写失败如何恢复？
4. **粘包处理**：三段式缓冲区如何设计？为什么是 2920+128K+1460？
5. **CRC32**：如何实现？为什么选 CRC32 而不是 CRC16？
6. **跨平台**：Winsock 和 POSIX 的主要差异？如何抽象？
7. **动态库加载**：dlopen/dlsym 的使用？如何处理符号找不到？
8. **会话管理**：会话超时如何检测？保活 3E 服务的实现？
