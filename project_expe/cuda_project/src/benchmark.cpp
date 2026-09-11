// src/benchmark.cpp
#include "benchmark.h"
#include <iostream>
#include <iomanip>

float Benchmark::timeKernel(cudaStream_t stream, const std::function<void()>& kernelLaunch) {
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    cudaEventRecord(start, stream);
    kernelLaunch();
    cudaEventRecord(stop, stream);
    cudaEventSynchronize(stop);

    float ms = 0.0f;
    cudaEventElapsedTime(&ms, start, stop);
    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    return ms;
}

void Benchmark::printComparison(const std::vector<BenchResult>& results) {
    std::cout << "\n+---------------------------+------------+--------+\n";
    std::cout << "| " << std::left << std::setw(26) << "Method"
              << "| " << std::setw(10) << "Time(ms)"
              << "| " << std::setw(6) << "Speed" << "|\n";
    std::cout << "+---------------------------+------------+--------+\n";
    float baseMs = results.front().ms;
    for (const auto& r : results) {
        float speedup = (r.ms > 0) ? baseMs / r.ms : 0;
        std::cout << "| " << std::left << std::setw(26) << r.name
                  << "| " << std::setw(10) << std::fixed << std::setprecision(2) << r.ms
                  << "| " << std::setw(5) << std::fixed << std::setprecision(1) << speedup << "x|\n";
    }
    std::cout << "+---------------------------+------------+--------+\n";
    for (const auto& r : results) {
        if (!r.note.empty()) {
            std::cout << "  " << r.name << ": " << r.note << "\n";
        }
    }
    std::cout << "\n";
}
