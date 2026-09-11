
# Executor 完整学习路线（面试必考点）

> 很多人写ROS2只会写`rclcpp::spin(node)`，不知道Executor底层，面试很容易被问住。
> 先记住核心结论：
> **Executor 是 rclcpp 的概念，和DDS无关。DDS只管把收到的数据放到内部队列；不会自动调用你的回调。Executor负责把队列的数据拿出来，调度执行订阅回调、Timer回调、Service回调。**

## 通俗比喻

DDS就像快递驿站：收到包裹（网络消息），放到驿站货架（DDS内部队列）。
**Executor就是快递分拣员。**

- 分拣员不去干活，包裹就一直堆在货架，你永远拿不到货（回调永远不执行）。
- `spin()` 就是叫分拣员上岗干活，循环不停取包裹，调用你写的回调。

> 坑：写了订阅，忘记spin，回调不触发，新手高频踩坑。

## 1、Executor 有哪几种（面试要分得清）

1. **SingleThreadedExecutor 单线程执行器（最常用，默认）**
   所有回调（订阅、timer、service）全部在**同一个线程串行执行**。

- 如果某一个回调阻塞/sleep，其他回调全部卡住，得不到执行。

2. **MultiThreadedExecutor 多线程执行器**
   内部开多个线程池，回调可以并行跑。

- 注意：多线程就会出现**线程安全问题**，共享变量要加锁。

3. StaticSingleThreadedExecutor：静态单线程，性能略高，节点不能动态增删。

> 90%业务开发用 SingleThreadedExecutor。

## 2、spin() / spin_some() 到底干了什么

```cpp
rclcpp::spin(node);
```

等价于：

```cpp
auto exec = std::make_shared<rclcpp::SingleThreadedExecutor>();
exec->add_node(node);
exec->spin();
```

`rclcpp::spin(node)`只是一个简易封装函数，内部自动创建单线程executor，把node加进去，然后spin。

- `exec->spin()`：**阻塞循环**。等待DDS有新数据，来了就执行回调；没有消息就休眠，不耗CPU。
- `spin_some()`：**非阻塞，只处理当前已经到达的消息，处理完立刻返回，不会阻塞等待新消息**。适合自己写主循环。

> 重点：一个node必须加到executor里面，回调才会被调度。

## 3、高频面试问题：单线程executor回调阻塞会发生什么？

> SingleThreadedExecutor所有回调跑在同一个线程。
> 如果某个订阅回调里面写了`sleep(5)`，或者做耗时大计算，**这5秒内，其他所有订阅、timer全部不会触发，消息堆积**。

✅解决方案：

1. 耗时逻辑不要放在回调内部；把数据丢到自己的工作线程，回调只做拷贝。
2. 使用MultiThreadedExecutor（代价：要处理线程安全，加互斥锁）。

## 4、一个executor可以加多个node

同一个执行器，可以add_node多个rclcpp::Node，全部共用一套线程调度。

## 5、Executor 和 DDS 的边界（面试必区分）

- DDS(DataReader)：接收网络数据包，放到内部队列。**不执行回调！**
- Executor(rclcpp)：去读取DDS队列，调用用户注册的回调函数。
  👉 DDS只管收数据；Executor负责跑业务回调。Executor不属于DDS。

---

# ROS2面试必学必会清单（C++方向，机器人/自动驾驶岗位）

> 分为：通信底层、rclcpp编程、核心概念、踩坑实战、代码。
> 很多面试官不考手写代码，考原理、分层、踩坑。

## 第一部分：通信底层（重中之重，DDS/Fast‑DDS）

1. DDS全称、定位；DDS是标准，Fast‑DDS是C++开源实现。
2. DDS核心对象：DomainParticipant、Topic、Publisher/DataWriter、Subscriber/DataReader。分清管理者和真正干活对象。
3. DomainParticipant：一个进程默认1份，多个rclcpp::Node共用；DomainID作用。
4. 发布订阅匹配4个条件：DomainID、Topic名字、IDL类型、QoS兼容。
5. IDL是什么；ROS2 msg → IDL → h/cxx完整编译链路。
6. QoS四大核心：Reliability(BEST_EFFORT / RELIABLE)、History、Durability、Deadline；QoS不兼容现象。
7. DDS无中心化；对比MQTT(broker)；DDS底层UDP+共享内存零拷贝。
8. Fast‑DDS / Cyclone‑DDS / RTI Connext区别。
9. 常见坑：DomainID不一致、跨机器UDP防火墙、QoS不匹配、IDL类型不一致。

## 第二部分：分层名词辨析（超级容易混淆，必考）

1. rcl全称 ROS Client Library；rcl(C底层，带`_t`句柄结构体)；rclcpp是C++面向对象封装。
2. 分清三层对象：
   - rclcpp::Node / Publisher / Subscriber（上层应用）
   - rcl_node_t / rcl_publisher_t（C层句柄，`_t`）
   - DDS DomainParticipant / DataWriter / DataReader（底层通信）
3. 句柄含义；`_t`后缀含义。
4. rclcpp本身不做网络通信；真正收发是DDS。
5. Executor执行器：作用、几种类型、spin/spin_some、回调阻塞问题。

## 第三部分 rclcpp编程必掌握

1. Node、Publisher、Subscriber、Timer、Service、Action基础用法。
2. QoS设置；`SensorDataQoS()`底层映射BEST_EFFORT，传感器场景。
3. Executor单线程/多线程的优缺点、线程安全。
4. 参数服务器；日志RCLCPP_INFO。
5. 生命周期节点（了解即可）。
6. 时间：系统时间 /仿真时间。

## 第四部分 高频面试题（必背口述）

1. ROS1与ROS2通信最大区别：ROS1中心化Master(TCPROS)；ROS2底层DDS无中心，QoS，共享内存。
2. rclcpp::Node是不是DomainParticipant？**不是，进程多个Node共用一个DomainParticipant**。
3. spin做了什么？不spin会怎么样？
4. QoS不兼容会发生什么？topic名字一样为什么收不到消息？
5. 为什么同一个进程内节点通信速度快？共享内存零拷贝，不走UDP socket。
6. 切换DDS后端，业务代码需要改吗？（rcl的抽象层，不需要）
7. 回调里面做耗时计算会有什么后果，如何解决？

## 第五部分：踩坑（简历可以写，面试官最爱听实战）

1. 忘记spin，回调不触发。
2. QoS设置错误，topic同名收不到数据。
3. DomainID不一致，节点无法互相发现。
4. 单线程executor回调阻塞，timer/订阅卡顿。
5. 跨机器通信，防火墙阻止UDP，DDS发现失败。
6. msg修改后没有重新编译，IDL类型不匹配。

## 第六部分：需要了解，不需要深挖

1. 自定义IDL消息；
2. Fast‑DDS XML配置；
3. Zero‑Copy；

> 面试问了能说个大概，不问不用死磕。

# 极简区分记忆

1. DDS：管网络收发、自动发现、IDL序列化、QoS执行。
2. rcl：C底层句柄，DDS抽象层。
3. rclcpp：C++封装，Node/Pub/Sub，Executor调度回调。
4. Executor：只负责调度回调，和网络收发无关。

如果你需要，我可以整理一份极简一页面试背诵版。
