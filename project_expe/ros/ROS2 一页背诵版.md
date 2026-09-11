
# ROS2 面试一页背诵版（精简，可直接背）

## 一、名词分层速记（分清属于哪一层）

1. **rcl**：ROS Client Library，ROS客户端库，ROS2底层C库；结构体带`_t`后缀，代表句柄（钥匙）。
2. **rclcpp**：基于rcl的C++面向对象SDK，业务代码用。
3. **DDS(Fast‑DDS)**：底层通信，真正干活；`DomainParticipant`域参与者、`DataWriter`发、`DataReader`收。
4. **Executor**：rclcpp组件，调度回调，**不属于DDS**。

> 口诀：
> `_t` → rcl‑C层句柄；
> rclcpp::xxx → C++业务层；
> DomainParticipant/DataWriter → DDS底层。

---

# ROS2核心四大概念：Node、Topic、Publisher、Subscriber（通俗+面试标准答案）

## 1. Node 节点

> 通俗：**一个独立的功能单元，一个可执行程序就是一个或多个Node**。
> 比如：激光雷达节点、导航节点、图像识别节点。
> 所有话题发布、订阅、定时器、服务都挂载在Node上。

⚠️重要底层关系：

- `rclcpp::Node` 是**rclcpp上层对象**，不是DDS的DomainParticipant。
- **同一个进程中，多个Node共用同一个DDS DomainParticipant**。
- DomainParticipant是DDS对象，负责网络发现、消息类型注册，业务代码看不见它。

> 面试口述：
> Node是ROS2的功能单元，应用层的概念；一个进程可以创建多个Node，底层共享一份DDS DomainParticipant。

## 2. Topic 话题

> 通俗：**节点之间传递数据的“数据通道/管道”，用字符串命名，例如 `/scan`、`/cmd_vel`**。
> 是节点通信的媒介，**单向数据流**：发布者往管道发数据，订阅者从管道收数据。

匹配成功**4个全部满足才可以通信（高频）**

1. DomainID 相同
2. Topic名字完全一致
3. IDL消息数据类型完全一致（msg编译生成）
4. QoS策略兼容

> 坑：topic名字一样，QoS不兼容 / msg定义不一样，照样收不到。

> 面试口述：
> Topic是节点间单向通信的通道；仅仅名字相同不能通信，还要DomainID、消息IDL类型、QoS全部兼容。

## 3. Publisher 发布者

> 通俗：**往Topic管道里面发消息的“发送把手”**。
> 属于rclcpp层对象 `rclcpp::Publisher`。
> 调用`pub->publish(msg)`发送消息。

底层链路：
`rclcpp::Publisher` → rcl C层句柄 → DDS的**DataWriter**（真正完成网络发送）。

> 面试口述：
> Publisher是rclcpp提供的发布句柄，本身不做网络发送；底层最终调用DDS的DataWriter完成消息发送。

## 4. Subscriber 订阅者

> 通俗：**监听某个Topic管道，收到消息就执行你写的回调函数**。
> 属于rclcpp层对象 `rclcpp::Subscriber`。

底层链路：
DDS的**DataReader**收到网络数据 → rcl层 → **Executor执行器调度** → 执行用户回调。

> ⚠️关键点：**回调不会自动执行，必须靠Executor(spin/spin_some)驱动**；忘记spin，回调永远不跑。

> 面试口述：
> Subscriber用来订阅话题；DDS把消息收到队列，Executor负责取出消息执行回调；不调用spin，回调不会触发。

---

# Executor 极简背诵

1. Executor是rclcpp组件，**和DDS无关**。DDS只把消息放到队列，不会跑回调。
2. SingleThreadedExecutor 单线程：所有回调串行；一个回调阻塞，全部回调卡住。
3. MultiThreadedExecutor 多线程：回调可并行，要处理线程安全。
4. `rclcpp::spin(node)` 等价：自动创建单线程executor，把node加入，循环spin阻塞等待消息。
5. `spin_some()`：非阻塞，处理完当前已有的消息直接返回。

> 面试题：回调里面sleep会发生什么？
> 单线程执行器下，全部订阅、timer回调阻塞，消息堆积；解决方案：耗时逻辑放到自定义工作线程，回调只做简单拷贝。

---

# DDS关键背诵（压缩版）

1. DDS：Data Distribution Service，数据分发服务，工业分布式通信标准；Fast‑DDS是开源C++实现，ROS2默认。
2. DomainParticipant：DDS顶层对象，一个进程默认1个；负责自动发现、注册消息类型。DomainID不同无法通信。
3. IDL：接口定义语言，与语言无关；ROS2编译：`.msg → IDL → .h/.cpp`，DDS靠IDL做类型校验。
4. QoS服务质量，控制传输行为，生效在DDS层；rclcpp只是封装配置接口。
   - BEST_EFFORT：尽力投递，允许丢包，传感器；
   - RELIABLE：可靠，丢包重传，控制指令；
   - History(KEEP_LAST(n))：保留最近n帧；
   - Durability：晚启动订阅能否拿到历史数据。

> QoS不兼容：topic名字一样，但是完全收不到消息。

## ROS1 vs ROS2（一句话）

ROS1：中心化Master，TCPROS，没有QoS；
ROS2：底层DDS无中心化，支持QoS，本机共享内存零拷贝。

---

# 高频错题速看（避雷）

1. ❌ rclcpp::Node就是DomainParticipant
   ✅ Node是应用层；DomainParticipant是DDS底层，进程多个Node共享一个。
2. ❌ topic名字一样就可以通信
   ✅ DomainID、topic名、IDL类型、QoS全部兼容。
3. ❌ Subscriber收到消息自动跑回调
   ✅ 需要Executor(spin)调度。
4. ❌ rclcpp负责网络收发
   ✅ rclcpp只是封装，真正收发是DDS。
5. ❌ `_t`是C++的东西
   ✅ `_t`是rcl的C语言结构体（句柄type）。

## 简单代码片段辅助记忆

```cpp
//1.创建节点
auto node = std::make_shared<rclcpp::Node>("demo_node");
//2.发布者，第二个参数是QoS history深度
auto pub = node->create_publisher<std_msgs::msg::String>("/chatter",10);
//3.订阅者，绑定回调
auto sub = node->create_subscription<std_msgs::msg::String>("/chatter",10,
    [](std_msgs::msg::String::SharedPtr msg){
        //回调函数
    });
//4.驱动executor，调度回调
rclcpp::spin(node);
```

如果你要，我可以下一步带你过 Service / Action，或者模拟面试问答。
