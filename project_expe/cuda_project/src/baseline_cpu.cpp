// src/baseline_cpu.cpp
#include "baseline_cpu.h"
#include <chrono>
#include <iostream>

std::vector<int> cpuBruteKnn(
    const std::vector<PointAoS>& cloud,
    const std::vector<PointAoS>& queries
) {
    std::vector<int> result(queries.size(), -1);
    for (size_t q = 0; q < queries.size(); ++q) {
        float bestDist = 1e30f;
        int bestIdx = -1;
        float qx = queries[q].x, qy = queries[q].y, qz = queries[q].z;
        for (size_t i = 0; i < cloud.size(); ++i) {
            float dx = cloud[i].x - qx;
            float dy = cloud[i].y - qy;
            float dz = cloud[i].z - qz;
            float d = dx*dx + dy*dy + dz*dz;
            if (d < bestDist) {
                bestDist = d;
                bestIdx = (int)i;
            }
        }
        result[q] = bestIdx;
    }
    return result;
}
