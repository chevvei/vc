
# 名词辨析：分清：ROS2应用层 / rcl / DDS层

> 很多人混乱根源：**三套不同层级都有 Node、Publisher、Subscriber，但不是同一个东西！**

**rcl 全称**：**ROS Client Library**，ROS客户端库。

- `rcl`：C语言写的底层核心（ROS Client Library）
- `rclcpp`：C++封装，在rcl之上（cpp = C++）
- `rclpy`：Python封装，在rcl之上

> rcl 是ROS2的**统一底层C底座**，不管C++还是Python节点，最终都调用rcl的C接口；rcl再往下对接DDS抽象层，才走到Fast‑DDS。

---

# 层级由上到下（非常关键，分清归属）

1. **ROS2 应用层（你写业务代码）**
   类：`rclcpp::Node`、`rclcpp::Publisher`、`rclcpp::Subscriber`
   ✅归属：**rclcpp（ROS2 C++ SDK）**
2. **rcl C底层库（C接口）**
   C结构体：`rcl_node_t`、`rcl_publisher_t`、`rcl_subscriber_t`
   ✅归属：**rcl**
3. **DDS底层（Fast‑DDS原生API）**
   类：`DomainParticipant`、`Topic`、`Publisher`、`DataWriter`、`Subscriber`、`DataReader`
   ✅归属：**DDS（Fast‑DDS）**

> ⚠️大坑：名字长得几乎一样，但不属于同一层！
>
> - rclcpp的Publisher ≠ DDS的Publisher
>   rclcpp对象只是上层句柄；真正网络发送的是DDS的`DataWriter`。

## 一一对应关系表（通俗版）

| 层级          | 对象名字                    | 归属   | 作用                                                                                                                                                    |
| ------------- | --------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 应用层 rclcpp | `rclcpp::Node`            | rclcpp | ROS2业务节点，你写代码new出来；内部持有一个`rcl_node_t`                                                                                               |
| rcl C层       | `rcl_node_t`              | rcl    | C语言的节点句柄；rcl内部去操作DDS的DomainParticipant                                                                                                    |
| DDS层         | **DomainParticipant** | DDS    | ✅DDS最顶层对象！DDS域参与者。**一个进程内默认只创建1个DomainParticipant，该进程所有rclcpp::Node共用它**。负责自动发现、管理所有topic、类型注册。 |

| 层级   | 对象名字                              | 归属   | 作用                                   |
| ------ | ------------------------------------- | ------ | -------------------------------------- |
| rclcpp | `rclcpp::Publisher`                 | rclcpp | 上层发布句柄，你调用`pub->publish()` |
| rcl    | `rcl_publisher_t`                   | rcl    | C层发布句柄                            |
| DDS    | `eprosima::fastdds::dds::Publisher` | DDS    | DDS发布管理对象                        |
| DDS    | **DataWriter**                  | DDS    | **真正干活发数据的对象！**       |

| 层级   | 对象名字                               | 归属   | 作用                           |
| ------ | -------------------------------------- | ------ | ------------------------------ |
| rclcpp | `rclcpp::Subscriber`                 | rclcpp | 上层订阅句柄，注册回调         |
| rcl    | `rcl_subscriber_t`                   | rcl    | C层订阅句柄                    |
| DDS    | `eprosima::fastdds::dds::Subscriber` | DDS    | DDS订阅管理对象                |
| DDS    | **DataReader**                   | DDS    | **真正接收数据的对象！** |

> 重点记忆DDS两个容易混淆名字：
> DDS里面：
>
> - `Publisher`只是管理者；真正发送：**DataWriter**
> - `Subscriber`只是管理者；真正接收：**DataReader**

---

# DomainParticipant 通俗讲（DDS概念，不属于rcl，不属于ROS2）

> 比喻：整个DDS网络是一个大公司，**DomainParticipant就是公司里的一个员工工位**。
> 同一个`DomainID`就是同一个公司；只有同一个公司（DomainID相同）的工位之间，才能互相通信。

1. 归属：**纯DDS概念，ROS2/rclcpp没有这个类，rcl只是调用它**
2. 一个进程，默认只创建**1个DomainParticipant**。哪怕你代码创建5个`rclcpp::Node`，全部共用这一个DDS参与者。
3. 职责：
   - 执行DDS自动发现协议（UDP广播找网络上其他DomainParticipant）
   - 注册IDL消息数据类型
   - 创建DDS Topic、Publisher、Subscriber
4. DomainID不一样：就算在同一台机器，完全发现不到对方。

> 裸Fast‑DDS代码，你要手动new DomainParticipant；
> ROS2/rclcpp下，rcl底层帮你创建，业务代码看不到它。

---

# ROS2中最重要的几个概念通俗讲解，分清归属

## 1. Node 节点

- **rclcpp::Node（rclcpp/ROS2应用层）**

> 通俗：你的程序单元，所有发布、订阅、定时器都挂在Node上。
> 它不是DDS的DomainParticipant！Node是ROS2的概念；DomainParticipant是DDS底层对象，进程内多个Node共享同一个DomainParticipant。

> 误区：很多人以为一个Node对应一个DomainParticipant，错！一个进程不管多少Node，默认1个DomainParticipant。

## 2. Publisher（rclcpp）

> ROS2上层的“发布把手”。你调用`pub->publish(msg)`。
> 它本身不发包，向下调用rcl，rcl再调用DDS的DataWriter做真正发送。

## 3. Subscriber（rclcpp）

> ROS2上层的“订阅把手”，注册回调函数。
> 底层DDS的DataReader收到数据，数据向上传递，最终执行你的回调。

## 4. Executor 执行器（rclcpp概念）

> 非常重要！很多人漏。
> 比喻：消息的“调度工人”。DDS底层收到数据只是放在队列，**不会自动调用你的回调**。
> `spin()`就是让executor工人不停干活：去DDS层拿收到的数据，调用订阅回调、timer回调。
> 不spin，回调永远不跑。

## 5. Topic 话题

> 跨层概念：
>
> - rclcpp层面：字符串名字，如`/lidar_points`
> - DDS层面：DDS有原生Topic对象，包含名字+IDL数据类型。
>   必须：DomainID相同 + Topic名字相同 + IDL类型匹配 + QoS兼容，才能通信。

## 6. QoS

> 配置规则：**真正生效在DDS层**；rclcpp只是提供API把配置传给DDS。

## 7. IDL

> **纯DDS标准概念**。ROS2的msg编译时转换为IDL。

## 8. msg消息文件

> **ROS2上层概念**，只是给开发者写的语法糖，编译转IDL。

## 9. rcl

> ROS2底层C库，承上启下：承接rclcpp，向下抽象封装DDS，隔离不同DDS实现（Fast‑DDS/Cyclone）。
> rcl把DDS的细节屏蔽，rcl不需要关心底层是哪一款DDS。

---

# 完整数据流走一遍，把所有名词串起来

```
你的业务代码
auto pub = node->create_publisher<Msg>("/chatter",10);
        ↓ rclcpp层：rclcpp::Publisher
        ↓ 调用 rcl C接口 rcl_publisher_init()
        ↓ rcl库内部，操作DDS
DomainParticipant(DDS) 拿出 DataWriter(DDS)
        ↓
publish() → DataWriter.write() → IDL序列化 → UDP/共享内存传输
————————网络————————
对端机器：DomainParticipant(DDS) → DataReader(DDS)收到数据
        ↓向上抛给rcl
        ↓rclcpp Executor执行器调度
触发你写的订阅回调函数
```

# 面试高频坑（容易混淆的提问）

### Q：rclcpp的Node就是DDS的DomainParticipant吗？

❌不是。

> DomainParticipant是DDS对象，一个进程一份；一个进程可以有多个rclcpp::Node，全部共享同一个DomainParticipant。Node是ROS2应用层概念。

### Q：rclcpp的Publisher是DDS的DataWriter？

❌不是。

> rclcpp::Publisher是上层句柄；内部底层持有DDS DataWriter，DataWriter才是真正发送数据。

### Q：rcl是什么？rclcpp和rcl关系？

> rcl全称ROS Client Library，ROS客户端库，C语言实现的ROS2底层；rclcpp是基于rcl做的C++面向对象封装。rcl做DDS抽象，上层业务不用关心底层DDS是Fast‑DDS还是Cyclone。

### Q：Topic名字一样就能通信吗？

> 不行。DomainID相同、Topic名称、IDL数据类型、QoS策略全部兼容，DDS的DataWriter和DataReader才会匹配成功。

### Q：Executor是DDS的东西吗？

> ❌不是，Executor是rclcpp的概念，DDS只管把数据收到队列；回调调度由rclcpp executor/spin完成。

# 极简记忆口诀

1. **DomainParticipant = DDS独有，进程1份，管发现和类型注册**
2. **DDS：DataWriter发，DataReader收；Publisher/Subscriber只是管理者**
3. **rcl：C底层底座；rclcpp：C++面向对象外壳**
4. **rclcpp的Node/Pub/Sub 都是上层把手，不直接网络收发**
5. **Executor(rclcpp)负责跑回调，不spin就没有回调**

如果你需要，我可以整理一张一页纸面试速记小抄。
