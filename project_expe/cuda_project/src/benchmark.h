// src/benchmark.h
// CUDA Event 计时 + 对比表输出
#pragma once
#include <cuda_runtime.h>
#include <string>
#include <vector>
#include <functional>

struct BenchResult {
    std::string name;
    float ms;
    std::string note;
};

class Benchmark {
public:
    // CUDA event 计时一个 kernel（kernel 是个 lambda，里面 launch kernel）
    static float timeKernel(cudaStream_t stream, const std::function<void()>& kernelLaunch);

    // 输出对比表
    static void printComparison(const std::vector<BenchResult>& results);
};
