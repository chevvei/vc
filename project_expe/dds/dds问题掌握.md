
# DDS / Fast‑DDS / ROS2底层 面试高频考点

> 面向C++机器人、自动驾驶岗位；很多面试官不会考写代码，考**概念、原理、踩坑、对比**。
> 分为：必背基础、高频问答、坑点、容易答错的地方、口述标准答案。

## 一、基础必掌握（一定会问到）

1. DDS是什么，全称，定位
2. 发布‑订阅模型，Topic、DomainParticipant、DataWriter、DataReader、IDL分别干什么
3. QoS是什么；**4个核心QoS策略，以及它们的含义**
4. ROS2 和 DDS 的关系；rclcpp的角色
5. ROS2消息完整链路：`.msg → IDL → h/cxx → 二进制`
6. 市面上常用DDS实现：Fast‑DDS、Cyclone DDS、RTI Connext DDS，各自特点
7. DDS无中心化 vs MQTT有broker的区别

---

# 二、最高频面试题 + 标准口述答案

## 1、DDS是什么？解决什么问题？

> 答：DDS全称Data Distribution Service，数据分发服务，是OMG组织定义的**工业级分布式实时通信标准**，不是软件。专门解决多节点分布式系统的数据分发。
> 核心是发布订阅模型，节点解耦；支持自动发现，丰富QoS策略；底层可以UDP Socket或者共享内存。
> Fast‑DDS是它的C++开源实现，ROS2默认用它。

## 2、DDS发布订阅，什么条件下发布者和订阅者才能匹配成功？（超级高频）

**三个条件必须全部满足，缺一不可**

1. **DomainID 域ID相同**（同一个域内才能互相发现）
2. **Topic话题名称完全一致**
3. **消息IDL数据类型完全一致**
4. ✅附加条件：**QoS策略必须兼容**，不兼容就算上面全对，也匹配失败，收不到数据。

> 面试大坑：很多人只说名字一样，漏掉IDL类型、QoS兼容。

## 3、讲一讲DDS的QoS，你了解哪些？QoS不兼容会怎么样？

> QoS服务质量，控制单条话题的传输行为，在DDS中间件层生效，不需要改业务逻辑。
> 重点讲4个：

1. **Reliability可靠性**

- BEST_EFFORT尽力投递：不重传，允许丢包，延迟低，适合传感器：激光雷达、图像。
- RELIABLE可靠传输：丢包自动重传，保证送达，适合控制指令。

> ⚠️不兼容案例：发布BEST_EFFORT，订阅RELIABLE，直接匹配失败。

2. **History历史策略**
   KEEP_LAST(n)：只保留最新n份样本；KEEP_ALL全部缓存。rclcpp里面`QoS(10)`就是KEEP_LAST(10)。
3. **Durability持久化**
   VOLATILE：后启动的订阅者拿不到历史消息；
   TRANSIENT_LOCAL：DDS缓存历史数据，晚来的订阅者可以收到历史数据，常用于地图、参数。
4. **Deadline截止时间**：规定多久必须收到一帧数据，超时DDS上报事件。

> QoS不兼容后果：Topic名、类型都正确，但是**无法匹配，收不到任何数据，ROS2会打印QoS不匹配警告**。

## 4、IDL是干嘛的？ROS2 msg和IDL的关系？

> IDL接口定义语言，与语言无关，用来描述传输的数据结构。
> Fast‑DDS通过fastddsgen读取IDL，自动生成C++结构体、序列化反序列化代码。
> ROS2中，`.msg`会在编译阶段自动转换为DDS IDL，再生成C++代码；DDS真正做类型校验依靠IDL。裸Fast‑DDS开发直接手写IDL。

## 5、DDS和Socket是什么关系？DDS和MQTT区别？

> DDS底层传输可以使用UDP Socket，也支持本机共享内存；Socket只是操作系统原始字节接口，连接管理、发现、序列化、QoS全部需要自己写。DDS是Socket之上完整的通信协议栈。

DDS vs MQTT

1. MQTT：**有中心Broker代理**，所有消息过代理；Broker挂掉整个系统瘫痪。适合物联网。
2. DDS：**无中心化**，节点之间直接通信；节点掉线不影响整体。
3. DDS原生强大QoS；MQTT QoS能力弱。
4. DDS适合大数据、低延迟机器人自动驾驶场景；MQTT适合小报文物联网。

## 6、ROS2、rclcpp、Fast‑DDS三者关系（必问）

> Fast‑DDS：DDS标准C++实现，真正负责网络通信。
> rclcpp：ROS2的C++客户端库，**本身不做通信**，封装DDS底层复杂API（Participant/DataWriter），对外提供Node/Publisher/Subscriber接口；同时做抽象层，可以切换Fast‑DDS/CycloneDDS，上层业务代码不用修改。
> ROS2节点就是基于rclcpp写出来的应用。

整条链路：业务代码(rclcpp) → rclcpp → Fast‑DDS → Socket/共享内存。

## 7、Fast‑DDS有哪些常见问题、踩过什么坑？（非常高频，考察实战）

1. **DomainID不一致，节点互相发现不到，收不到数据。**
2. **跨机器通信UDP防火墙拦截；DDS自动发现协议走UDP。**
3. **QoS不兼容，topic名字一样但是收不到数据。**
4. IDL/msg结构体定义不一致，类型校验失败，无法匹配。
5. 大点云数据，UDP分片，网络差的时候容易丢包；需要调传输配置。
6. 自动发现机制在复杂多网卡环境容易错乱，需要指定网络接口。

## 8、Fast‑DDS、Cyclone‑DDS、RTI Connext DDS区别

1. **Fast‑DDS(eProsima)**：开源，ROS2默认DDS，机器人行业最常用。
2. **Cyclone DDS**：开源，RTI基金会维护，稳定性好，工业场景，ROS2可切换。
3. **RTI Connext DDS**：商业闭源DDS，军工、自动驾驶大厂，性能强工具完善，收费。

## 9、DDS为什么本机进程之间速度很快？

> 本机不同节点通信不走网卡Socket，使用**共享内存Zero‑Copy零拷贝**，直接进程内存映射，性能很高。跨机器才走UDP。

## 10、DDS的自动发现是什么？

> 节点启动后通过UDP互相广播自己的信息，自动发现网络里其他Participant，自动匹配发布订阅，**不需要手动填写IP和端口**。

## 11、ROS1和ROS2通信层面最大区别

> ROS1：自定义TCPROS，中心化Master；性能差，没有QoS。
> ROS2：底层DDS，无中心化，支持QoS，支持共享内存，分布式实时。

---

# 三、容易答错的坑（面试避雷）

❌错误：DDS就是socket。
✅正确：DDS底层可以使用socket，但是DDS是完整协议栈，实现发现、QoS、序列化等能力。

❌错误：topic名字一样就可以通信。
✅正确：DomainID、topic名称、IDL类型、QoS全部兼容。

❌错误：rclcpp负责网络收发。
✅正确：rclcpp只是封装，真正收发是DDS。

❌错误：IDL是C++语法。
✅正确：IDL是中立描述语言，工具生成C++代码。

# 四、简历怎么写（参考）

> 熟悉DDS通信原理，了解Fast‑DDS底层机制，掌握发布订阅模型、IDL消息定义、QoS服务质量策略；理解ROS2‑rclcpp对DDS的封装，熟悉`.msg‑IDL‑C++`完整编译链路，了解DDS自动发现、共享内存传输，实际踩过QoS不匹配、跨主机发现失败等问题。

如果你需要，我可以帮你模拟一遍面试官提问，你来口头回答。
