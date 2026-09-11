
先理清楚：
`service_client.cpp` 是 **Service（服务）** 的客户端，**完全和Action无关**。
Service 和 Action 是两套独立上层组件，只是底层都封装DDS‑topic。

---

## 1. 区分文件职责

1. `service_server.cpp` / `service_client.cpp` → **Service**（一问一答，不能取消、没有进度反馈）
2. Action 需要单独写两套文件：`action_server.cpp`、`action_client.cpp`，我前面只讲了概念，**没有贴Action代码**。

> 面试：Action代码很长，一般不让手写，会口述逻辑即可。

### Service 通信流程（回顾）

```
Client发送请求 → [DDS请求topic] → Server处理 → [DDS应答topic] → Client拿到结果
特点：一次请求，一次回复。任务跑起来之后，没有办法中途叫停，拿不到中间进度。
```

### Action通信流程（5个要素）

```
Client发Goal目标 → Server接收开始执行
↓
Server持续反馈Feedback（进度）
↓
Client随时可以发Cancel取消任务
↓
任务结束，返回最终Result结果
```

Action底层自动生成**5套隐藏的DDS topic**：
goal、cancel、feedback、status、result。

---

## 2. 极简 Action 伪代码（看懂即可，面试口述）

`.action` 文件

```action
# Goal
int32 target_num
---
# Feedback
int32 current_progress
---
# Result
bool success
```

action_client.cpp（伪代码，关键片段）

```cpp
// Action客户端头文件
#include "my_demo/action/count.action.hpp"
#include "rclcpp_action/rclcpp_action.hpp"

// Action客户端对象
auto client = rclcpp_action::create_client<my_demo::action::Count>(node, "count_action");

// 1.发送目标goal
auto goal_msg = my_demo::action::Count::Goal();
goal_msg.target_num = 100;

// 发送goal，同时注册3种回调：
// ①goal响应回调  ②feedback进度回调  ③result最终结果回调
client->async_send_goal(goal_msg,
    // 收到goal接受/拒绝
    [](auto){},
    // ✅【重点】每一次收到进度反馈，会反复调用这个回调，Service没有这个！
    [](auto feedback){
        RCLCPP_INFO(get_logger(), "当前进度：%d", feedback->feedback->current_progress);
    },
    // 任务结束，拿到最终结果
    [](auto){}
);

// 随时可以调用：client->async_cancel_all_goals(); // 中途取消任务，Service做不到！
```

> ✨**Action独有的两个能力，Service完全没有：**

1. **Feedback回调：持续收到中间进度**
2. **支持cancel：任务跑起来之后，可以中途取消**

Service只有：发请求 → 等一次返回，没有这两个。

---

## 3. 回到你的疑问：`service_client.cpp`里面看不到Action，为什么？

1. service_client 是 Service 的示例，**不属于Action**。
2. Service用头文件：`#include "xxx/srv/xxx.hpp"`
3. Action用头文件：`#include "xxx/action/xxx.action.hpp"`，并且使用专门的 `rclcpp_action` 库。

### 一张表分清API不一样

|            | Service                        | Action                                                   |
| ---------- | ------------------------------ | -------------------------------------------------------- |
| 头文件     | `xxx/srv/xxx.hpp`            | `xxx/action/xxx.action.hpp`                            |
| 创建客户端 | `this->create_client<srv>()` | `rclcpp_action::create_client<action>()`               |
| 发送       | `async_send_request()`       | `async_send_goal()`                                    |
| 特有回调   | 只有response一次回调           | goal响应 + feedback持续回调 + result结束回调，支持cancel |

> 面试话术：
> Service只做简单请求应答；如果任务耗时久，需要看进度、可以随时取消，就要选用Action。
> Service、Action底层都是封装DDS的topic，不是DDS原生功能，是rclcpp上层封装。

---

## 4.面试高频提问

> Q：Service能不能实现中途取消？
> A：原生Service做不到。service发出去请求之后，没有接口去终止服务端逻辑；只能服务端自己加业务逻辑标记。长耗时任务必须用Action。

> Q：Action底层是什么？
> A：底层自动创建多组DDS话题，goal、cancel、feedback、status、result，全部走DDS通信。

> 小结：

- `service_client.cpp` → **Service**，没有Action任何代码。
- Action有自己独立的一套API，需要引入`rclcpp_action`。
- 核心区分特征：**Feedback持续反馈 + Cancel取消任务**，这两点是Service不具备的。

如果你需要，我可以贴一份精简可编译的action最小示例代码。
