
# rclcpp 【ROS Client Library】深度通俗讲解（面试版）

> 栈回顾：
> 业务代码 ← **rclcpp** ← rcl（C底层） ← DDS(Fast‑DDS) ← Socket/共享内存

> 一句话定位：
> **rclcpp 是 ROS2 的C++高层SDK，它本身不做网络通信，它是一层“包装翻译器”，把复杂DDS底层API包装成简单好用的Node/Publisher/Subscriber。**

## 生活化比喻

DDS(Fast‑DDS) = 原始邮政系统。
寄一封信，你要手动：申请邮局席位、注册信件格式、申请栏目、创建寄件人、创建写信器、配置投递规则(QoS)、资源销毁。API极其繁琐，样板代码巨多。

**rclcpp = 邮政代办前台**
你不需要了解邮政内部几十套流程。你只跟前台说三句话：

1. 给我开一个节点（我这个应用）
2. 帮我发布话题`/lidar_points`
3. 收到消息调用我的回调函数

前台内部，偷偷调用DDS那一大堆底层接口，创建`DomainParticipant、Topic、DataWriter、DataReader`，设置QoS，管理生命周期。

> 你业务代码几乎看不到任何DDS原生对象。

## rclcpp 内部两层结构

1. **rcl**：纯C实现，ROS2最底层C接口，对DDS做抽象封装。
2. **rclcpp**：基于rcl，做C++面向对象封装，就是我们写代码用的库。

> rcl是骨架，rclcpp是给C++开发者用的外壳。

## rclcpp核心对象，对应到底层DDS

| rclcpp对象         | 底层对应DDS对象                     | 作用                                     |
| ------------------ | ----------------------------------- | ---------------------------------------- |
| rclcpp::Node       | DomainParticipant（进程内共用一个） | 节点，所有发布订阅都挂在Node上           |
| rclcpp::Publisher  | Publisher + DataWriter              | 发布消息，真正发送数据的底层是DataWriter |
| rclcpp::Subscriber | Subscriber + DataReader             | 订阅消息，接收数据底层是DataReader       |
| rclcpp::QoS        | DDS原生QoS结构体                    | rclcpp做一层封装，翻译成DDS的QoS策略     |

> ⚠️重要：**一个进程里面多个Node，默认共享同一个DDS DomainParticipant，不会重复创建多个参与者。**

## 举代码，看内部发生了什么

### 你写的rclcpp代码

```cpp
auto node = std::make_shared<rclcpp::Node>("demo_node");
auto pub = node->create_publisher<std_msgs::msg::String>("/chatter", 10);
```

这一行`create_publisher`，rclcpp内部默默完成：

1. 获取Node绑定的DomainParticipant；
2. 找到编译阶段由msg→IDL生成好的消息类型；
3. 在DDS中注册该IDL消息类型；
4. 创建DDS Topic（名字`/chatter`）；
5. 把rclcpp的QoS(10)翻译成DDS原生QoS：`KEEP_LAST(10)`；
6. 创建DDS Publisher、DataWriter，并把QoS配置给DataWriter；
7. 把DataWriter封装到rclcpp::Publisher对象对外暴露。

当你调用 `pub->publish(msg)`：
rclcpp把你的消息对象，交给底层DDS的DataWriter->write()，真正执行网络发送。

## rclcpp的两大核心能力

### 1. DDS抽象层（非常关键面试点）

rclcpp**不绑定某一款DDS**。
上层写的`Node、create_publisher`代码完全不变。
通过修改ROS2配置文件，底层可以切换：

- Fast‑DDS
- Cyclone DDS

> 业务代码一行不改，底层DDS实现换掉。rclcpp屏蔽了不同DDS库API的差异。

### 2. 除通信以外的附加能力

rclcpp不只有收发消息，还封装：

- 参数服务器；
- 回调执行器 Executor（重要！消息回调是由executor驱动）；
- 生命周期节点；
- 日志系统RCLCPP_INFO；
- Service、Action服务接口；
- 时间管理（仿真时间/系统时间）。

> 重点：**Executor执行器**。Subscriber的回调不会自动跑，要靠`spin()/spin_some()`执行器去驱动底层DDS，去读取DDS收到的数据，调用你的回调函数。
> 很多新手踩坑：写了订阅，忘记spin，回调永远不触发。

## rclcpp 不是什么（面试避坑）

❌ rclcpp不是通信库，**不会真正收发网络数据包**，数据包全部由DDS完成。
❌ rclcpp不是DDS，它只是DDS的上层封装。
❌ rclcpp不做序列化；序列化是IDL生成的代码由DDS完成。

## 整条完整数据流，从头到尾

```cpp
//你的业务
pub->publish(my_msg);
        ↓
//rclcpp层
rclcpp::Publisher → rcl C接口
        ↓
//DDS层
DataWriter->write() → IDL序列化 → Fast‑DDS传输（共享内存/UDP‑socket）
        ↓
网络传输
        ↓
对端Fast‑DDS接收 →反序列化 → DataReader
        ↓
rclcpp Executor读到样本，调用用户注册的回调函数
```

# 面试高频rclcpp问题

## Q1：rclcpp和DDS的关系？

> rclcpp是ROS2的C++客户端库，基于底层rcl C库实现。它对上层提供Node/Publisher/Subscriber友好API；对下层做DDS抽象，屏蔽不同DDS实现差异。rclcpp本身不做通信，真正网络收发由底层DDS(Fast‑DDS)完成。

## Q2：executor执行器是干嘛的？spin()做了什么？

> executor负责调度所有回调函数（订阅回调、timer回调）。spin()内部会阻塞，底层调用DDS接口去等待接收样本，收到数据后触发注册的回调。不调用spin，订阅回调永远不会执行。

## Q3：一个进程多个Node，底层会创建多个DomainParticipant吗？

> 默认不会，同一个进程的多个Node共享同一个DomainParticipant，节省资源。

## Q4：切换DDS后端，上层rclcpp代码需要改吗？

> 不需要修改业务代码，只修改配置文件，rclcpp抽象层适配不同DDS实现。

## Q5 rclcpp和rcl的区别

> rcl是纯C编写的底层接口，直接对接DDS抽象层；rclcpp是基于rcl实现的C++面向对象封装，给应用开发者使用。

## Q6：ROS1和ROS2 API层面区别

> ROS1：roscpp，依赖master；ROS2 rclcpp，底层DDS无中心，支持QoS，Executor模型。

## Q7 create_publisher第二个参数，数字10代表什么

> 是rclcpp的QoS，代表history深度KEEP_LAST(10)，底层DDS只保留最近10份样本。

## 踩坑点（简历可以写）

1. 忘记spin/spin_some，订阅回调不触发；
2. QoS设置错误，rclcpp层打印警告，但是topic名字正确，收不到数据；
3. 多节点共享Participant，注意进程内通信走共享内存；
4. 不同DDS后端切换，部分xml配置不兼容。

## 简短口述版（面试直接背）

> rclcpp是ROS2的C++客户端库，基于C的rcl库实现。它封装了底层DDS的复杂对象，对外提供Node、Publisher、Subscriber接口，同时做了DDS抽象层，可以无缝切换Fast‑DDS、Cyclone‑DDS。rclcpp本身不做网络通信，真实的数据收发交给底层DDS。executor执行器负责调度订阅、定时器回调，需要spin驱动。

如果你需要，我可以给一小段极简代码演示executor的作用，或者梳理一套完整模拟面试提问。
