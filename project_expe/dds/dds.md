
# 0.  



# DDS 机器人通信中间件通俗讲解

> 求职面试版：听得懂、说得出，能讲清楚DDS是干嘛的、解决什么痛点、市面上常用实现，面试可以直接复述。

## 打个生活化比喻

想象你有一个**机器人身体**：

- 眼睛（相机）、雷达（激光雷达）、底盘电机、导航模块、AI识别模块，相当于很多个**独立小员工**。
- 每个员工都要收发数据：雷达输出点云、相机输出图片、导航输出目标位置、电机接收转速指令。

### 老方案1：点对点直接打电话（Socket原生TCP/UDP）

雷达直接连导航，相机直接连AI。
缺点：

1. 设备一多，连线乱成蜘蛛网；A要发给B/C/D，就要写N份发送代码。
2. A挂掉，B容易跟着崩；新增加一个模块，所有相关代码都要改。
3. 自己手写处理丢包、重传、多播、数据过滤、时间同步，工作量巨大，bug巨多。

### DDS就是公司内部一套**广播消息系统**

不用A直接打电话给B。

> **发布-订阅(Publish‑Subscribe)模式，DDS的核心**

- **发布者Publisher**：员工只管把消息扔到公司消息系统，不管谁会看。比如激光雷达只管发布“点云数据”。
- **订阅者Subscriber**：谁需要这个数据，就订阅这个话题Topic。导航、避障模块想要点云，就订阅`/lidar_pointcloud`这个话题。
- Topic话题：相当于消息的“栏目名字”，比如`/camera_image`、`/cmd_vel底盘速度指令`。

👉 雷达只管发，不需要知道有多少模块在用它的数据；新增一个模块，只需要订阅话题，不用改雷达一行代码。模块掉线、上线热插拔，互不干扰。

> DDS = **数据分发服务(Data Distribution Service)**，它不是软件，是一套**工业标准协议**，专门用于分布式实时系统。
> 定位：**机器人/自动驾驶的分布式通信中间件**，负责一堆硬件/软件节点之间高速传数据。

## 关键特性（面试必懂，通俗版）

1. **发布订阅，解耦节点**
   发送方不知道接收方是谁。节点之间完全解耦，随便增删模块。
2. **QoS 服务质量（DDS灵魂，面试高频）**
   普通socket只有“发或者不发”；DDS可以给每个话题配置规则，就是QoS。
   举几个好懂例子：

- 雷达点云：追求低延迟，可以丢老数据，只保留最新一帧；
- 控制指令：绝对不能丢包，必须可靠送达；
- 日志消息：允许丢一点，追求速度。

**不用改业务代码，改QoS配置，就能改变这个话题的通信行为。**

> QoS是DDS最大优势，也是和普通消息队列（ROS1的TCPROS、MQTT）最大区别。

3. **零拷贝、高性能、实时**
   面向机器人、自动驾驶，毫秒级传输，支持大数据（点云、图像），可以共享内存，本机节点不走网卡，速度极快。
4. **自动发现（Discovery）**
   节点上电自动互相找到对方，不用手动填IP地址。新节点插上网络，自动发现话题，直接收发。

> 对比MQTT：MQTT必须要有一个中央MQTT代理（broker），所有消息都过这个中介。
> ✅DDS是**无中心化**，没有中心服务器。节点之间直接点对点通信。一个节点挂掉，整个系统不会瘫痪。

## 市面上最常用DDS实现（求职重点！你要知道这几个）

DDS只是协议标准，有很多开源/商业实现：

1. **Fast‑DDS（eProsima Fast‑DDS）【最最重要】**
   ROS2 默认底层DDS！！机器人行业用的最多，开源。绝大多数机器人开发者实际接触的就是它。面试必提。
2. **Cyclone DDS**
   开源，RTI开源基金会维护，稳定性强，工业机器人常用，ROS2也支持切换。
3. **RTI Connext DDS**
   商业闭源DDS，军工、自动驾驶大厂用，性能强、工具完善，收费。很多大厂项目在用，但普通开发者很少直接上手。

> 面试话术：项目里ROS2底层就是Fast‑DDS，实际用过DDS，理解发布订阅、话题、QoS策略、自动发现，知道可以切换不同DDS后端。

## 容易混淆：ROS2 和 DDS是什么关系？

很多人搞混，面试很容易被问：

> ROS2 是机器人应用框架，**底层通信就是跑在DDS之上**。
> ROS2帮你封装了DDS复杂API，你写ros2 topic，底层本质就是调用Fast‑DDS。
> 你也可以脱离ROS2，直接裸写Fast‑DDS代码做通信。

ROS1没有DDS，ROS1是自己做的TCPROS，有中心化master，性能差，这就是为什么升级ROS2用DDS。

## 和其他中间件简单对比（面试心里有数）

1. MQTT：有broker，适合物联网设备，**不适合机器人大数据实时通信**。
2. ZeroMQ：消息库，没有标准化QoS、自动发现，需要自己实现很多逻辑。
3. DDS：面向分布式实时硬实时场景，机器人、自动驾驶、军工。

## 面试简短口述版本（可以直接背）

> DDS全称数据分发服务，是一套分布式实时通信的工业标准，属于通信中间件，核心采用发布订阅模型。
> 发送方发布话题，接收方订阅话题，节点之间解耦，不需要知道对方IP。最大特点是丰富的QoS策略，可以针对不同数据配置可靠度、延迟、历史缓存。DDS无中心，节点自动发现，支持高速大数据传输。
> 工程上最常用开源实现是Fast‑DDS，也是ROS2的默认底层；另外还有Cyclone DDS；RTI Connext是商用版本。
> ROS2本质就是封装DDS，我们写的ROS2话题通信底层就是DDS。

## 面试常见追问，帮你提前准备

1. QoS了解哪些？

> Reliability（可靠/尽力送达）、History（保留多少历史样本）、Durability（新节点上线能不能收到旧消息）。

2. DDS和MQTT区别？

> MQTT需要broker中心节点；DDS去中心化，节点直连；DDS原生强大QoS，更适合高带宽低延迟机器人场景。

3. Fast‑DDS的问题？

> 网络复杂场景自动发现容易出问题，需要调配置；跨主机通信需要设置好网络接口。

如果你需要，我可以再给你一份**简历项目描述**，把DDS写到简历上，或者给一段极简伪代码演示DDS发布订阅逻辑。

# 1. fast-dds 怎么用： dds是协议标准， 而fast-dds是实现



# Fast‑DDS 快速上手（裸Fast‑DDS，不依赖ROS2）

> 目标：安装 → IDL定义消息 → 生成C++代码 → 写发布者/订阅者 → 编译运行，跑通第一个demo。
> Fast‑DDS = eProsima Fast‑DDS，DDS标准的C++开源实现，ROS2默认底层。

## 1. 环境准备 Ubuntu22.04/24.04

两种方式：源码编译 / apt安装。apt最简单适合入门。

```bash
# 安装fast‑dds + fast‑dds‑gen（IDL代码生成工具）
sudo apt update
sudo apt install libfastdds-dev fastddsgen
```

验证版本

```bash
fastddsgen -version
```

> 关键点：**IDL是DDS消息定义文件**。DDS不直接传结构体，需要IDL描述数据结构，工具自动生成C++序列化/反序列化代码。类似protobuf。

## 2. 第一步：写IDL消息文件 `HelloMsg.idl`

新建文件 HelloMsg.idl

```idl
struct HelloMsg
{
    unsigned long index;
    string message;
};
```

这个就是我们要DDS传输的数据结构。

## 3. fastddsgen 根据idl生成C++源码

```bash
fastddsgen HelloMsg.idl
```

执行完会生成一堆文件：

- `HelloMsg.h`、`HelloMsg.cxx` 数据类型
- `HelloMsgPubSubTypes.h`、`HelloMsgPubSubTypes.cxx` DDS序列化、Topic类型注册代码

> 这一步等价protobuf的protoc编译。**不要手动修改生成出来的代码**。

## 4. 写发布者 publisher.cpp

```cpp
#include "HelloMsgPubSubTypes.h"

#include <fastdds/dds/domain/DomainParticipant.hpp>
#include <fastdds/dds/domain/DomainParticipantFactory.hpp>
#include <fastdds/dds/publisher/Publisher.hpp>
#include <fastdds/dds/publisher/DataWriter.hpp>
#include <fastdds/dds/publisher/qos/DataWriterQos.hpp>
#include <fastdds/dds/topic/Topic.hpp>

#include <thread>
#include <iostream>

using namespace eprosima::fastdds::dds;

int main()
{
    // 1. 创建域参与者 DomainParticipant（DDS最顶层对象，所有节点在同一个domain才能互相发现）
    DomainParticipantQos participant_qos;
    DomainParticipant* participant = DomainParticipantFactory::get_instance()->create_participant(0, participant_qos);
    if (!participant) return -1;

    // 2. 注册消息类型
    HelloMsgPubSubType msg_type;
    participant->register_type(&msg_type);

    // 3. 创建Topic，话题名字 "/hello_topic"
    Topic* topic = participant->create_topic("/hello_topic", msg_type.getName(), TOPIC_QOS_DEFAULT);

    // 4. 创建Publisher、DataWriter（真正发数据的对象）
    Publisher* publisher = participant->create_publisher(PUBLISHER_QOS_DEFAULT);
    DataWriter* writer = publisher->create_datawriter(topic, DATAWRITER_QOS_DEFAULT);

    HelloMsg data;
    data.message("Hello FastDDS!");
    uint32_t idx = 0;

    // 循环发送
    while(true)
    {
        data.index(idx++);
        writer->write(&data);
        std::cout << "send: index=" << data.index() << ", msg=" << data.message() << std::endl;
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }

    return 0;
}
```

## 5. 写订阅者 subscriber.cpp

```cpp
#include "HelloMsgPubSubTypes.h"

#include <fastdds/dds/domain/DomainParticipant.hpp>
#include <fastdds/dds/domain/DomainParticipantFactory.hpp>
#include <fastdds/dds/subscriber/Subscriber.hpp>
#include <fastdds/dds/subscriber/DataReader.hpp>
#include <fastdds/dds/subscriber/qos/DataReaderQos.hpp>
#include <fastdds/dds/topic/Topic.hpp>
#include <fastdds/dds/subscriber/SampleInfo.hpp>

#include <iostream>

using namespace eprosima::fastdds::dds;

// 回调类，收到消息自动回调
class HelloListener : public DataReaderListener
{
public:
    void on_data_available(DataReader* reader) override
    {
        HelloMsg sample;
        SampleInfo info;
        if (RETCODE_OK == reader->take_next_sample(&sample, &info))
        {
            if (info.valid_data)
            {
                std::cout << "recv index:" << sample.index() << ", msg:" << sample.message() << std::endl;
            }
        }
    }
};

int main()
{
    DomainParticipant* participant = DomainParticipantFactory::get_instance()->create_participant(0, PARTICIPANT_QOS_DEFAULT);
    if (!participant) return -1;

    HelloMsgPubSubType msg_type;
    participant->register_type(&msg_type);

    Topic* topic = participant->create_topic("/hello_topic", msg_type.getName(), TOPIC_QOS_DEFAULT);

    Subscriber* subscriber = participant->create_subscriber(SUBSCRIBER_QOS_DEFAULT);
    HelloListener listener;
    DataReader* reader = subscriber->create_datareader(topic, DATAREADER_QOS_DEFAULT, &listener);

    std::cout << "subscriber running..." << std::endl;
    while(true)
    {
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }
    return 0;
}
```

## 6. CMakeLists.txt

```cmake
cmake_minimum_required(VERSION 3.16)
project(fastdds_demo)

set(CMAKE_CXX_STANDARD 17)

find_package(fastdds REQUIRED)

add_executable(publisher publisher.cpp HelloMsg.cxx HelloMsgPubSubTypes.cxx)
target_link_libraries(publisher fastdds)

add_executable(subscriber subscriber.cpp HelloMsg.cxx HelloMsgPubSubTypes.cxx)
target_link_libraries(subscriber fastdds)
```

## 7. 编译运行

```bash
mkdir build && cd build
cmake ..
make -j4

# 终端1：运行发布者
./publisher

# 终端2：运行订阅者
./subscriber
```

> 本机跑：默认会用**共享内存传输**，不走UDP socket。
> 跨机器跑：两台机器**DomainID必须一样（这里是0）**，同一局域网。

## 📌 Fast‑DDS核心对象记忆（面试必背）

1. **DomainParticipant 域参与者**：最高对象，同一个DomainID下节点才能互相发现。相当于DDS的“域”。
2. **Topic 话题**：消息名字 + 消息类型。发布订阅必须Topic名称、类型完全一致。
3. **Publisher + DataWriter**：发布端；DataWriter真正发送数据，可以设置QoS。
4. **Subscriber + DataReader**：订阅端；DataReader接收数据，可以注册Listener回调。
5. IDL生成的PubSubType：消息类型注册，序列化反序列化。

## 常见踩坑

1. DomainID不一致 → 互相发现不到，收不到数据。
2. IDL生成代码没有编译进工程 → 崩溃。
3. 跨机器通信，防火墙拦截UDP；Fast‑DDS发现协议靠UDP。
4. QoS不匹配：发布者和订阅者QoS冲突，会出现匹配失败收不到数据。

> 最常见：Reliability一个RELIABLE，一个BEST_EFFORT，匹配失败。

## 和ROS2关系

ROS2的`rclcpp`把上面一整套Participant/Publisher/DataWriter全部封装，你写`create_publisher`底层就是调用Fast‑DDS这套API。

## 下一步可以练手

1. 修改QoS，把DataWriter设置BEST_EFFORT（尽力投递，适合点云）
2. 修改QoS设置RELIABLE（可靠传输，适合控制指令）
3. 写idl数组类型，模拟点云数据。

如果你需要，我可以给你一段极简QoS修改示例代码，或者讲怎么看fastdds的xml配置文件。



# 1 是什么是IDL



# IDL 通俗讲（DDS里的IDL）

**IDL = Interface Definition Language，接口定义语言**

> 它**不是C++，不是Python，是一门专门用来「描述数据长什么样」的描述语言**。

## 打个比方

你要通过DDS网络发送一个结构体：

```cpp
// C++结构体
struct HelloMsg{
    uint32_t index;
    std::string message;
};
```

直接把C++结构体丢网络是不行的：

1. C++结构体内存布局受编译器、操作系统、CPU架构影响，不同机器内存排布不一样。
2. 网络传输只能传二进制字节，你要自己写代码把结构体序列化成字节流，接收端再反序列化回来。
3. 如果同时有C++、Java语言写的DDS程序，两边怎么约定数据格式？

👉 **IDL就是中立的“数据契约”**
用一份独立的`.idl`文件，中立描述数据结构，**不绑定任何编程语言**。

```idl
struct HelloMsg
{
    unsigned long index;
    string message;
};
```

这份文件，和C++无关。
然后用工具 `fastddsgen` 读取这个idl文件，**自动帮你生成C++的结构体 + 序列化/反序列化全套代码**。

> 类比 protobuf 的 `.proto` 文件，逻辑几乎一模一样。

- Protobuf：`.proto` → protoc工具 →生成C++/Python代码
- Fast‑DDS：`.idl` → fastddsgen工具 →生成C++代码

## DDS为什么必须要IDL？

1. **跨语言**：同一份IDL，可以生成C++、C#、Python代码。C++写的发布者，可以给Python写的订阅者发消息。大家共用一份idl契约。
2. **序列化**：自动生成把结构体变成网络字节、字节还原结构体的代码，不用手写。
3. **类型匹配校验**：DDS发布订阅，不光topic名字要一样，idl定义的数据类型也必须一样，否则就算topic同名，也无法匹配通信。

> ⚠️坑：topic名字一样，但idl结构体字段不一样，收不到数据！DDS会识别类型不匹配。

## IDL能干什么（DDS‑IDL语法）

可以定义：

- struct 结构体（最常用）
- 基础类型：`int32`、`unsigned long`、`float`、`string`
- 数组、序列（动态数组，模拟点云点集合）
- 枚举enum

示例，带动态序列（模拟点云）

```idl
struct Point{
    float x;
    float y;
    float z;
};

struct LidarMsg{
    unsigned long stamp;
    sequence<Point> points; //动态数组，点云
};
```

## 和C++的关系

`.idl` 是源文件；
执行`fastddsgen xxx.idl`，输出`.h` `.cxx`，这才是真正C++代码，你项目编译要把这些生成文件编进去。
**不要手动修改生成出来的h/cxx，改idl文件，重新生成。**

## 面试一句话总结

> IDL是接口定义语言，DDS用IDL文件中立描述要传输的数据结构，不依赖编程语言；通过fastddsgen工具，从idl自动生成C++结构体以及序列化反序列化代码，实现跨语言、跨平台的数据传输，同时DDS会做类型校验，只有topic名称和IDL类型全部匹配，发布订阅者才能通信。

## 补充：ROS2里面的idl

ROS2的`.msg`、`.srv`，底层会被转换成DDS IDL。
你写ros2的msg文件，底层工具会转成idl，再生成C++代码。ROS2把idl对用户隐藏了。

如果你需要，我可以对比 proto 和 idl 的简单对照表。




# 2. 调用链条


# ✅整条链路梳理（ROS2完整流水线，你总结的基本正确，把细节补齐）

```
ROS2 .msg 文件  → 自动生成 DDS‑IDL → fastddsgen生成 .h/.cpp → CMake编译 → 二进制可执行程序
```

> ROS1没有这套链路，ROS1用的是自定义msg，没有DDS、没有IDL。下面全部讲**ROS2**。

## 完整分步拆解

1. **开发者写 `xxx.msg`**（你平时写的ROS2消息）

```msg
# Hello.msg
uint32 index
string message
```

这是ROS2友好的消息格式，给人看的。

2. **ROS2工具链(rosidl_generator_dds_idl)：把 .msg ➜ 生成DDS标准`.idl`文件**

> 这一步**对你透明，你看不见idl文件，在build目录下生成**。
> 把msg翻译成OMG DDS标准IDL描述，这是DDS协议能看懂的契约。

3. **再调用fastddsgen，拿idl ➜ 生成C++的 `.h` / `.cpp`（PubSubTypes等）**
   这就是DDS需要的：结构体定义 + 序列化/反序列化代码。
4. CMake把这些生成出来的h/cxx 和你的业务代码一起编译、链接Fast‑DDS库 → 最终二进制程序。

运行时，你的ROS2节点内部，直接操作这些生成出来的DDS类型，调用Fast‑DDS底层API完成网络收发。

---

## 关键重点（面试很容易问到）

1. **`.msg`只是ROS2上层语法糖，真正跨节点通信的契约是IDL**
   两个ROS2节点互通，底层本质是DDS拿IDL做类型校验。

> Topic名字一样，但msg定义不一样 → 转出来的IDL不一样 → DDS判定类型不匹配，收不到数据。

2. 如果你**裸用Fast‑DDS（不使用ROS2）**：
   没有.msg，你直接手写`.idl`，再fastddsgen产出h/cxx，跳过msg那一步。

```
手写IDL → fastddsgen → h/cxx → 编译二进制
```

3. 为什么要搞两层（msg→idl），不直接写idl？

- `.msg`语法简单，对机器人开发者友好；
- IDL是OMG工业标准，是给DDS中间件用的；
- ROS2支持切换不同DDS后端（Fast‑DDS / Cyclone DDS），不管底层DDS换成哪个，统一先生成标准IDL。

## 画两条链路对比，一目了然

### 链路A：裸Fast‑DDS（无ROS2）

`手写.idl` → fastddsgen → `.h` `.cxx` → 编译链接fastdds库 → 二进制

### 链路B：ROS2（封装Fast‑DDS）

`手写.msg` → ROS工具链生成`.idl` → fastddsgen生成`.h` `.cxx` → 和rclcpp+fastdds库链接 → ROS2节点二进制

## 面试口述简短版本

> ROS2的msg不会直接网络传输。构建阶段，msg文件会先转换成DDS标准IDL，再由fastddsgen生成对应的C++头文件和源文件，再参与编译链接得到可执行程序。DDS真正做类型校验、序列化靠的是IDL。裸Fast‑DDS开发就直接手写IDL，跳过msg这一层。

## 一个小坑

build文件夹下全部是自动产物，**不要手动修改build里面生成的idl/h/cpp**。要改数据结构，改源文件：要么改`.msg`，裸DDS就改`.idl`，重新编译，工具会全部重生成。

> 补充：rclcpp再做一层封装，把DDS原生的DomainParticipant/DataWriter这些底层对象包装成 `Node、Publisher`，业务代码看不到DDS原生API。

如果你想，我可以再讲：QoS在这条链路上是怎么传递的。


# 3 rclcpp + QoS 通俗拆解

先回顾整条栈，从上到下：

> 业务应用代码(rclcpp) → rclcpp层封装 → DDS(Fast‑DDS) → Socket/共享内存

- **DDS(Fast‑DDS)**：底层通信库，负责网络收发、自动发现、序列化、QoS执行。API非常啰嗦，一堆`DomainParticipant、DataWriter、Topic`。
- **rclcpp**：ROS2的C++客户端库。**一层厚厚的包装壳，把DDS复杂API全部藏起来**。

## 生活化比喻

继续沿用之前公司消息系统的例子：

> DDS = 公司完整内部消息邮政系统。
> 但是这套邮政系统操作手册极其复杂，寄一封信要填十几张表单：创建参与者、注册类型、创建topic、创建publisher、创建datawriter、配置QoS……一大堆底层对象。普通人直接用DDS写业务，大量重复样板代码。

> **rclcpp = 前台秘书**
> 秘书把复杂邮政流程全部封装。你只需要告诉秘书：

1. 我要创建一个节点（我是哪个员工）
2. 我要发布一个话题叫`/cmd_vel`
3. 或者订阅某个话题，消息来了调用我的回调函数

秘书内部偷偷去调用DDS那一大套接口，所有底层DDS对象(`DomainParticipant/DataWriter/DataReader`)全部由rclcpp帮你创建、管理、销毁。
👉 你写业务代码，几乎看不见DDS原生API。

### 裸Fast‑DDS（不使用rclcpp）你要手动干的活

1. 创建`DomainParticipant`
2. 注册IDL消息类型
3. 创建Topic
4. 创建Publisher
5. 创建DataWriter，设置QoS
6. 管理资源释放，出错处理

### rclcpp帮你做掉上面全部工作

```cpp
// rclcpp业务代码，你只写这几行
auto node = std::make_shared<rclcpp::Node>("my_node");
auto pub = node->create_publisher<std_msgs::msg::String>("/chatter", 10);
```

**就这一行`create_publisher`，内部偷偷完成：**

- 内部维护DomainParticipant（一个进程默认共用一个participant）
- 拿到msg编译生成的IDL类型，完成类型注册
- 创建DDS Topic
- 创建DDS Publisher、DataWriter
- 把你传入的QoS参数，转成DDS原生QoS结构体设置给DataWriter

> ⚠️关键点：**rclcpp本身不做网络通信！它只是翻译转发，真正发数据包还是底层DDS。**

### rclcpp定位总结

1. rclcpp不是通信中间件，**是ROS2的C++应用层SDK**。
2. 对上：给开发者提供简洁友好的API：`Node/Publisher/Subscriber/Service`。
3. 对下：适配不同DDS后端（Fast‑DDS / Cyclone DDS）。rclcpp对外接口不变，底层切换DDS实现，上层业务代码不用改。
4. 附带：时间管理、参数服务器、生命周期节点、日志、异常处理。

> 类比：
>
> - DDS = 底层声卡驱动
> - rclcpp = 播放器软件，你调用播放器播放音乐，播放器内部调用声卡驱动。播放器本身不能发声。

---

# QoS 完整通俗讲解（DDS → rclcpp，面试重点）

> QoS：Quality of Service，服务质量。
> 打个邮政比喻：
> 同样是寄邮件，你可以选择不同服务规则：

1. 普通快递：尽力送，丢件不赔，速度快（适合摄像头图像、点云，旧帧丢了无所谓，只要最新）
2. 挂号信：必须送达，丢了重发，保证对方一定收到（底盘控制指令，不能丢）
3. 报纸订阅：新加入的订阅者，能不能拿到过去几天的旧报纸？
4. 缓存最多存多少封邮件？老邮件要不要直接扔掉？

**QoS就是一套配置规则，规定这条话题的数据怎么传输。**

> ❗重要：QoS不是应用层逻辑，是DDS中间件层执行。

## DDS原生QoS（底层）

Fast‑DDS里，DataWriter、DataReader可以配置几十种QoS策略。几个最核心4个：

1. **Reliability 可靠性**

- `BEST_EFFORT`尽力投递：只管发，丢包不重传。延迟低。适合点云、图像。
- `RELIABLE`可靠传输：丢包自动重传，保证送达。适合控制指令。

> ⚠️匹配规则：发布者和订阅者QoS必须兼容，否则两边匹配不上，收不到任何数据。
> 例：发布BEST_EFFORT，订阅RELIABLE → **不匹配，收不到数据**。

2. **History 历史策略**

- KEEP_LAST(n)：只保留最新n个样本，旧样本直接丢弃（最常用）
- KEEP_ALL：全部缓存所有历史样本。

3. **Durability 持久性**

> 场景：发布者先发消息，订阅者晚一点才上线。晚来的订阅者能不能收到以前发过的数据？

- VOLATILE：晚来的订阅拿不到旧消息；
- TRANSIENT_LOCAL：DDS会缓存历史消息，新订阅上线可以拿到历史数据。比如导航地图。

4. **Deadline 截止时间**
   规定：必须多久间隔内收到一次数据；超时没收到，DDS直接通知上层。

> 以上全部是DDS原生的QoS策略。

## rclcpp中的QoS

rclcpp不新增QoS逻辑，**只是把DDS原生QoS做一层封装、别名**。
我们写ROS2代码看到的：

```cpp
// rclcpp内置预设QoS配置
create_publisher<MsgType>("/topic_name", rclcpp::QoS(10));
// 还有：SensorData、ServicesDefault、SystemDefault
```

- `rclcpp::QoS(10)`：10代表History深度KEEP_LAST(10)。
- `rclcpp::QoS(rclcpp::SensorDataQoS())`：专门给传感器用，内部映射到底层DDS：`BEST_EFFORT + KEEP_LAST`。

rclcpp做的事情：

1. 提供一套简化的QoS API，不用去操作DDS底层QoS结构体。
2. 当你调用`create_publisher`传入rclcpp QoS配置，rclcpp内部把它翻译成DDS原生QoS，赋值给底层DDS的DataWriter/DataReader。
3. 如果QoS不兼容，rclcpp会打印警告日志。

## 整条链路QoS传递

```
rclcpp代码设置QoS配置 → rclcpp翻译成DDS原生QoS → 赋值给DDS DataWriter/DataReader → Fast‑DDS中间件执行这套传输策略，控制网络收发行为。
```

## 面试口述版本

> rclcpp是ROS2的C++客户端库，它本身不做通信，它封装底层DDS，把DDS复杂的DomainParticipant、DataWriter等底层对象屏蔽，对外提供Node、Publisher、Subscriber简洁接口。同时做了DDS抽象层，上层业务代码不用修改，就可以切换Fast‑DDS、CycloneDDS不同DDS实现。

> QoS是服务质量策略，定义话题数据的传输行为，比如是否丢包重传、缓存多少帧、晚启动的订阅者能否接收历史数据。QoS真正生效是在DDS层；rclcpp只是封装了QoS的配置接口，把上层设置翻译成DDS原生QoS参数。发布者和订阅者QoS必须兼容，否则会匹配失败收不到消息。

## 一张栈图帮你记牢

```
你的业务代码
      ↓
rclcpp(Node/Publisher/Subscriber + rclcpp QoS封装)
      ↓
DDS(Fast‑DDS)：DomainParticipant / DataWriter /原生DDS QoS /IDL序列化 /自动发现
      ↓
操作系统：Socket(UDP) / 共享内存
      ↓
网卡
```

## 高频面试追问

1. QoS不兼容会发生什么？

> 话题名字一样，消息类型IDL也对，但是QoS不兼容，DDS判定发布订阅双方不匹配，完全收不到数据，ros2会输出警告。

2. SensorDataQoS是什么？

> rclcpp预定义的QoS配置，底层映射DDS BEST_EFFORT，用于相机激光雷达这类传感器，允许丢旧帧，追求低延迟。

3. rclcpp和rcl的区别？

> rcl是C写的ROS2底层C接口；rclcpp是基于rcl封装的C++面向对象接口，我们写C++节点用rclcpp。

如果你需要，我可以写一小段示例代码：rclcpp自定义QoS，对比裸Fast‑DDS原生QoS，直观看到映射关系。
