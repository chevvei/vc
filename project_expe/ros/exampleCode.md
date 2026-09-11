
# ROS2 C++高频工程代码示例

> 环境：humble / jazzy；基于rclcpp；包含：Node、Publisher、Subscriber、Timer、Service Client/Server、Action简单示例。
> 注释写的通俗易懂，面试可以口述代码逻辑，面试很少手写完整代码，但要看得懂、讲得出内部流程。

> CMakeLists.txt、package.xml是工程必备，顺带给出最小模板。

## 1. 基础发布者 publisher（talker.cpp）

```cpp
#include "rclcpp/rclcpp.hpp"
#include "std_msgs/msg/string.hpp"

// 自定义节点类，继承 rclcpp::Node
class TalkerNode : public rclcpp::Node
{
public:
    // 构造函数，节点名字叫 "talker_node"
    TalkerNode() : Node("talker_node")
    {
        // 创建发布者：发布 /chatter 话题，消息类型std_msgs::msg::String，Qos历史深度10
        // rclcpp::QoS(10) 底层对应DDS QoS KEEP_LAST(10)
        publisher_ = this->create_publisher<std_msgs::msg::String>("/chatter", 10);

        // 创建定时器，500ms触发一次回调
        timer_ = this->create_wall_timer(
            std::chrono::milliseconds(500),
            std::bind(&TalkerNode::timer_callback, this)
        );
        RCLCPP_INFO(this->get_logger(), "talker节点启动");
    }

private:
    // 定时器回调：每500ms执行一次
    void timer_callback()
    {
        auto msg = std_msgs::msg::String();
        msg.data = "hello ros2 , count: " + std::to_string(count_++);

        // 发布消息；底层：rclcpp::Publisher → rcl层句柄 → DDS DataWriter真正发送
        publisher_->publish(msg);
        RCLCPP_INFO(this->get_logger(), "发布: [%s]", msg.data.c_str());
    }

    // 发布者对象，rclcpp层句柄，不直接网络发包
    rclcpp::Publisher<std_msgs::msg::String>::SharedPtr publisher_;
    // 定时器
    rclcpp::TimerBase::SharedPtr timer_;
    int count_ = 0;
};

int main(int argc, char ** argv)
{
    // 1.初始化rcl底层库
    rclcpp::init(argc, argv);

    // 2.创建节点智能指针对象
    auto node = std::make_shared<TalkerNode>();

    // 3.spin：启动单线程Executor执行器！！
    // executor负责调度timer回调、订阅回调；内部阻塞等待事件
    rclcpp::spin(node);

    // 4.退出，释放资源
    rclcpp::shutdown();
    return 0;
}
```

## 2. 基础订阅者 subscriber（listener.cpp）

```cpp
#include "rclcpp/rclcpp.hpp"
#include "std_msgs/msg/string.hpp"

class ListenerNode : public rclcpp::Node
{
public:
    ListenerNode() : Node("listener_node")
    {
        // 创建订阅者：订阅 /chatter话题，QoS 10；绑定回调函数
        subscription_ = this->create_subscription<std_msgs::msg::String>(
            "/chatter",
            10,
            std::bind(&ListenerNode::topic_callback, this, std::placeholders::_1)
        );
        RCLCPP_INFO(this->get_logger(), "listener节点启动，等待消息");
    }

private:
    // 收到话题消息后执行的回调
    // SharedPtr：消息共享指针，DDS DataReader收到数据往上抛，executor调度到此函数
    void topic_callback(const std_msgs::msg::String::SharedPtr msg) const
    {
        RCLCPP_INFO(this->get_logger(), "收到消息: [%s]", msg->data.c_str());
    }

    rclcpp::Subscription<std_msgs::msg::String>::SharedPtr subscription_;
};

int main(int argc, char ** argv)
{
    rclcpp::init(argc, argv);
    auto node = std::make_shared<ListenerNode>();

    // ⚠️重点：没有spin，回调永远不会执行！Executor驱动回调
    rclcpp::spin(node);

    rclcpp::shutdown();
    return 0;
}
```

> 面试重点：
>
> 1. spin内部启动SingleThreadedExecutor；
> 2. DDS收到消息放到队列，**不会自动调用回调**；spin里面executor去取消息执行回调。
> 3. 如果回调里面sleep，单线程executor所有任务全部卡住。

## 3. Service 服务端 server（加法服务 srv文件 TwoInts.srv）

```srv
# 请求
int64 a
int64 b
---
#响应
int64 sum
```

service_server.cpp

```cpp
#include "rclcpp/rclcpp.hpp"
#include "my_demo/srv/two_ints.hpp"

using namespace std::placeholders;

class AddServerNode : public rclcpp::Node
{
public:
    AddServerNode() : Node("add_server_node")
    {
        // 创建服务，服务名字 "add_two_num"，绑定回调
        service_ = this->create_service<my_demo::srv::TwoInts>(
            "add_two_num",
            std::bind(&AddServerNode::service_callback, this, _1, _2)
        );
        RCLCPP_INFO(this->get_logger(), "加法服务端启动");
    }

private:
    // 服务回调：收到客户端请求，计算，填充response返回
    void service_callback(
        const std::shared_ptr<my_demo::srv::TwoInts::Request> request,
        std::shared_ptr<my_demo::srv::TwoInts::Response> response)
    {
        // 拿到请求参数
        int64 a = request->a;
        int64 b = request->b;
        // 计算结果放到响应
        response->sum = a + b;
        RCLCPP_INFO(this->get_logger(), "收到请求 a=%ld b=%ld → sum=%ld", a,b,response->sum);
    }

    rclcpp::Service<my_demo::srv::TwoInts>::SharedPtr service_;
};

int main(int argc, char** argv)
{
    rclcpp::init(argc,argv);
    auto node = std::make_shared<AddServerNode>();
    rclcpp::spin(node);
    rclcpp::shutdown();
    return 0;
}
```

## 4. Service客户端 client（异步调用，面试优先异步，不推荐同步阻塞）

service_client.cpp

```cpp
#include "rclcpp/rclcpp.hpp"
#include "my_demo/srv/two_ints.hpp"

class AddClientNode : public rclcpp::Node
{
public:
    AddClientNode() : Node("add_client_node")
    {
        // 创建客户端，连接服务名字 "add_two_num"
        client_ = this->create_client<my_demo::srv::TwoInts>("add_two_num");
    }

    // 发送请求函数
    void send_request(int64 a, int64 b)
    {
        // 1.等待服务端上线，1秒超时
        if(!client_->wait_for_service(std::chrono::seconds(1))){
            RCLCPP_ERROR(this->get_logger(), "服务不可用！");
            return;
        }
        // 2.构造请求数据
        auto request = std::make_shared<my_demo::srv::TwoInts::Request>();
        request->a = a;
        request->b = b;

        // 3.异步发送请求；服务返回后执行回调
        auto future_result = client_->async_send_request(
            request,
            std::bind(&AddClientNode::response_callback, this, std::placeholders::_1)
        );
    }

private:
    // 收到服务端应答回调
    void response_callback(rclcpp::Client<my_demo::srv::TwoInts>::SharedFuture future)
    {
        auto response = future.get();
        RCLCPP_INFO(this->get_logger(), "收到服务返回 sum = %ld", response->sum);
    }

    rclcpp::Client<my_demo::srv::TwoInts>::SharedPtr client_;
};

int main(int argc, char** argv)
{
    rclcpp::init(argc,argv);
    auto node = std::make_shared<AddClientNode>();

    node->send_request(11,22);

    rclcpp::spin(node);
    rclcpp::shutdown();
    return 0;
}
```

> ⚠️面试重点：Service底层是两套隐藏DDS topic；**不要用同步阻塞调用，会卡死线程；优先异步async_send_request**。耗时任务不要用Service，要用Action。

## 5. package.xml最小模板

```xml
<?xml version="1.0"?>
<?xml-model href="http://download.ros.org/schema/package_format3.xsd" schematypens="http://www.w3.org/2001/XMLSchema"?>
<package format="3">
  <name>my_demo</name>
  <version>0.0.0</version>
  <description>ROS2 code demo</description>
  <maintainer email="xxx@xxx.com">xxx</maintainer>
  <license>Apache-2.0</license>

  <buildtool_depend>ament_cmake</buildtool_depend>
  <depend>rclcpp</depend>
  <depend>std_msgs</depend>

  <buildtool_depend>rosidl_default_generators</buildtool_depend>
  <exec_depend>rosidl_default_runtime</exec_depend>
  <member_of_group>rosidl_interface_packages</member_of_group>

  <test_depend>ament_lint_auto</test_depend>
  <test_depend>ament_lint_common</test_depend>

  <export>
    <build_type>ament_cmake</build_type>
  </export>
</package>
```

## 6. CMakeLists.txt最小模板

```cmake
cmake_minimum_required(VERSION 3.8)
project(my_demo)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(std_msgs REQUIRED)
find_package(rosidl_default_generators REQUIRED)

# 编译srv接口文件
rosidl_generate_interfaces(${PROJECT_NAME}
  "srv/TwoInts.srv"
)

# 编译talker
add_executable(talker src/talker.cpp)
ament_target_dependencies(talker rclcpp std_msgs)

# 编译listener
add_executable(listener src/listener.cpp)
ament_target_dependencies(listener rclcpp std_msgs)

# 编译service server client
add_executable(service_server src/service_server.cpp)
ament_target_dependencies(service_server rclcpp)

add_executable(service_client src/service_client.cpp)
ament_target_dependencies(service_client rclcpp)

rosidl_get_typesupport_target(cpp_typesupport_target ${PROJECT_NAME} "rosidl_typesupport_cpp")
target_link_libraries(service_server "${cpp_typesupport_target}")
target_link_libraries(service_client "${cpp_typesupport_target}")

# 安装可执行文件
install(TARGETS
  talker
  listener
  service_server
  service_client
  DESTINATION lib/${PROJECT_NAME}
)

ament_package()
```

# 面试高频代码相关问题（背）

1. `rclcpp::spin(node)`做了什么？

> 内部创建SingleThreadedExecutor，把node加入执行器；阻塞循环，等待DDS事件；收到消息后调度timer、订阅、service回调。不spin，回调不会跑。

2. 回调函数里面sleep会发生什么？

> SingleThreadedExecutor单线程：整个执行器线程阻塞，所有timer、订阅全部不执行，消息堆积。解决：耗时逻辑放到自己新建std::thread，回调只做拷贝。

3. 为什么推荐异步service客户端？

> 同步调用会阻塞当前executor线程，整个节点卡死；异步不阻塞。

4. SharedPtr是什么？

> rclcpp大量使用智能指针管理Node/Pub/Sub生命周期，自动释放资源。

5. 消息编译链路：`.msg/.srv` → IDL → c++头文件。修改接口文件必须重新编译colcon build。

## Action简要说明

Action代码篇幅很长，面试一般不会手写完整action代码。
**记住关键点即可：**

1. Action 5个核心：Goal、Feedback、Cancel、Result、Status；
2. 底层封装多组DDS topic；适合长耗时任务，可以取消、获取进度；
3. 分为ActionServer、ActionClient。

> 如果面试问到Action，你口述业务逻辑即可，不用默写完整代码。

如果你需要，我可以给你提炼：面试常问代码坑点总结。
