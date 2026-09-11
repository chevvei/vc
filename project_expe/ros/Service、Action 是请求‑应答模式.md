
# ROS2 Service 与 Action（背诵版）

> 先对比 Topic：**Topic是单向流式发布订阅，源源不断发数据**。
> Service、Action 是**请求‑应答模式**：客户端发请求，服务端处理，返回结果。

| 通信方式 | 模式                               | 适用场景                                       |
| -------- | ---------------------------------- | ---------------------------------------------- |
| Topic    | 单向数据流，发布‑订阅             | 持续输出数据：激光点云、图像、速度指令         |
| Service  | 同步请求‑应答，一次请求一次返回   | 短时间就能完成的任务：查询状态、开关设备       |
| Action   | 异步请求‑应答 + 过程反馈 + 可取消 | 耗时较长任务：机械臂运动、导航、移动机器人巡迹 |

> 底层本质：Service、Action **底层依然跑在DDS的Topic之上**，不是DDS新增协议，是rclcpp做的上层封装。

---

## 1、Service（服务）

### 通俗理解

类似调用一个函数。

- **Client（客户端）**：我发一个请求，等待服务端给我返回结果。
- **Server（服务端）**：收到请求，执行逻辑，返回响应。

> 特点：

1. **一问一答，一次请求对应一次响应**。
2. 默认**阻塞等待返回**（也可以异步调用）。
3. **不支持过程反馈；任务一旦开始，不能中途取消**。
4. 适合快速完成的操作，几毫秒~几百毫秒就结束。

### 例子

- 查询机器人当前电池电压
- 打开/关闭某个传感器
- 获取某个参数

### srv 文件（Service消息）

`.srv` 文件，分为请求部分 `---` 分割响应部分

```srv
# 请求
int32 a
int32 b
---
#响应
int32 sum
```

编译阶段：`.srv → IDL → h/cxx`，和msg链路一样。底层还是DDS topic。

#### 底层怎么实现的（面试可以说）

Service内部会创建**两套隐藏topic**：

1. 请求topic：client发请求
2. 应答topic：server返回结果

> ⚠️Service短板：如果服务端处理耗时很久，client会卡住；不能拿到任务进度，也不能取消任务。**长时间任务不要用Service，要用Action。**

> 面试口述：
> Service是ROS2的请求应答通信，Client发请求，Server处理返回响应；适合短时任务，无法获取进度、不能取消。底层封装DDS话题。

---

## 2、Action（动作）

> 通俗类比：外卖下单

1. Client（用户）发送目标请求：帮我把外卖送到A点（发送goal目标）
2. Server（外卖骑手）开始干活
3. **持续反馈中间进度**：已经到XX路口（feedback反馈）
4. 可以中途取消：不要送了（cancel）
5. 任务完成返回最终结果：送达，完成（result最终结果）

### Action五大要素（必记）

1. **Goal**：客户端下发目标
2. **Feedback**：任务执行中，持续返回过程进度（流式反馈）
3. **Cancel**：客户端可以随时取消正在运行的任务
4. **Result**：任务结束之后返回最终结果（成功/失败）
5. Status：任务状态（执行中、取消、成功、失败）

适用场景：**耗时较长任务**

- 机械臂运动到目标点位
- 机器人导航到目标点
- 抓取物体

### action文件 `.action`

三段式，用`---`分割：

```action
# Goal 目标
float64 target_x
float64 target_y
---
# Feedback 过程反馈
float64 current_x
float64 current_y
float32 progress
---
# Result 最终结果
bool success
string message
```

编译：`.action → IDL → h/cxx`，底层也是DDS话题封装。

> Action内部会自动创建多组隐藏topic：goal、cancel、feedback、status、result。全部跑DDS。

> 面试口述：
> Action用于耗时较长任务；支持下发目标、中途持续进度反馈、支持取消任务、最后返回最终结果。底层封装DDS话题。Service只适合短时一问一答，没有进度、不能取消。

---

# Service vs Action 高频面试题

### Q1：什么时候用Service，什么时候用Action？

> Service：任务执行快，不需要进度反馈，不需要取消，一次请求一次返回，例如查询状态、开关设备。
> Action：任务耗时久，需要实时看到执行进度，需要支持中途取消，例如导航、机械臂运动。

### Q2：Service、Action底层是DDS吗？

> 是的。Service、Action是rclcpp上层封装，底层复用DDS Topic，走msg/srv/action→IDL编译链路。并不是DDS原生的能力，是ROS2封装出来的。

### Q3：Service可以做耗时任务吗？会有什么问题？

> 不建议。如果server处理时间很长，同步调用的client会阻塞等待；并且没有进度反馈，也无法取消。耗时任务优先Action。

### Q4：Topic、Service、Action三者对比（背诵）

1. **Topic**：发布‑订阅，单向流式，持续数据；传感器数据、控制指令。
2. **Service**：Client‑Server，请求应答，一次请求一次回复；短时任务，无进度，不可取消。
3. **Action**：Goal‑Feedback‑Result，支持进度反馈、任务取消；长耗时任务。

---

# 容易踩坑点

1. Service同步调用会阻塞当前线程；大量场景用异步回调调用。
2. Action的feedback是持续上报，result只有任务结束才返回。
3. Service/Action同样受DDS QoS、DomainID、IDL类型约束，和topic一样，条件不满足通信失败。

## 快速记忆口诀

- Topic：不停广播数据流。
- Service：调用函数，一问一答，干完就结束，不能取消。
- Action：干长活，看进度，随时可以叫停。

> 到此ROS2基础通信就全部闭环：Topic / Service / Action，全部基于DDS，经过`xxx→IDL→h/cxx`编译，由rclcpp封装，Executor调度回调。

如果你需要，下一步我可以整理一份**完整的ROS2面试总速记小抄**，把node/topic/pub/sub/executor/service/action/DDS/rcl/rclcpp全部浓缩一页。
