#include <metal_stdlib>
using namespace metal;

constant uint heads = 8;
constant uint headWidth = 128;
constant uint tileFrames = 128;
constant float hiddenScore = -1.0e20f;
#ifdef YUE2_M3_MAX
constant uint projectionRows = 8;
#else
constant uint projectionRows = 4;
#endif

// One simdgroup computes a weight row for both guidance branches.
kernel void project_q4(device const ushort *weights [[buffer(0)]],
                       device const half *scales [[buffer(1)]],
                       device const half4 *input [[buffer(2)]],
                       device half *output [[buffer(3)]],
                       constant uint2 &shape [[buffer(4)]],
                       uint group [[threadgroup_position_in_grid]],
                       ushort lane [[thread_index_in_simdgroup]],
                       ushort simd [[simdgroup_index_in_threadgroup]]) {
    uint row = group * projectionRows + simd;
    if (row >= shape.y) return;
    uint columns = shape.x / 4;
    const device ushort *packed = weights + row * columns;
    const device half *scale = scales + row * (columns / 8);
    float sum0 = 0, sum1 = 0;
#if defined(YUE2_PAIRED_LAYOUT) || defined(YUE2_M3_MAX)
    #pragma clang loop unroll_count(4)
#endif
    for (uint i = lane; i < columns; i += 32) {
        ushort word = packed[i];
        short4 n = short4(word & 15, (word >> 4) & 15, (word >> 8) & 15, word >> 12);
        float4 q = float4((n ^ 8) - 8);
        float s = float(scale[i / 8]);
        sum0 += s * dot(q, float4(input[i]));
        sum1 += s * dot(q, float4(input[columns + i]));
    }
    sum0 = simd_sum(sum0);
    sum1 = simd_sum(sum1);
    if (lane == 0) {
        output[row] = half(sum0);
        output[shape.y + row] = half(sum1);
    }
}

// Reuse each input load for both Q4 projections and write the activated gate.
kernel void project_q4_gate_up(
    device const ushort *gate_weights [[buffer(0)]],
    device const half *gate_scales [[buffer(1)]],
    device const ushort *up_weights [[buffer(2)]],
    device const half *up_scales [[buffer(3)]],
    device const half4 *input [[buffer(4)]],
    device half *output [[buffer(5)]],
    constant uint2 &shape [[buffer(6)]],
    uint group [[threadgroup_position_in_grid]],
    ushort lane [[thread_index_in_simdgroup]],
    ushort simd [[simdgroup_index_in_threadgroup]]) {
    uint row = group * projectionRows + simd;
    if (row >= shape.y) return;
    uint columns = shape.x / 4;
    const device ushort *gate = gate_weights + row * columns;
    const device ushort *up = up_weights + row * columns;
    const device half *gs = gate_scales + row * (columns / 8);
    const device half *us = up_scales + row * (columns / 8);
    float gate0 = 0, gate1 = 0, up0 = 0, up1 = 0;
#ifdef YUE2_M3_MAX
    #pragma clang loop unroll_count(4)
#endif
    for (uint i = lane; i < columns; i += 32) {
        ushort g = gate[i], u = up[i];
        short4 qg = short4(g & 15, (g >> 4) & 15, (g >> 8) & 15, g >> 12);
        short4 qu = short4(u & 15, (u >> 4) & 15, (u >> 8) & 15, u >> 12);
        float4 x0 = float4(input[i]), x1 = float4(input[columns + i]);
        gate0 += float(gs[i / 8]) * dot(float4((qg ^ 8) - 8), x0);
        gate1 += float(gs[i / 8]) * dot(float4((qg ^ 8) - 8), x1);
        up0 += float(us[i / 8]) * dot(float4((qu ^ 8) - 8), x0);
        up1 += float(us[i / 8]) * dot(float4((qu ^ 8) - 8), x1);
    }
    gate0 = simd_sum(gate0);
    gate1 = simd_sum(gate1);
    up0 = simd_sum(up0);
    up1 = simd_sum(up1);
    if (lane == 0) {
        // Preserve the FP16 stores between the separate projection and activation kernels.
        thread volatile half g0 = half(gate0), g1 = half(gate1);
        thread volatile half u0 = half(up0), u1 = half(up1);
        float a = float(g0), b = float(g1);
        thread volatile half act0 = half(a / (1.0f + exp(-a)));
        thread volatile half act1 = half(b / (1.0f + exp(-b)));
        output[row] = half(float(act0) * float(u0));
        output[shape.y + row] = half(float(act1) * float(u1));
    }
}
// Two songs share each weight read, keeping each guidance branch's reduction order.
kernel void project_q4_four(device const ushort *weights [[buffer(0)]],
                       device const half *scales [[buffer(1)]],
                       device const half4 *input [[buffer(2)]],
                       device half *output [[buffer(3)]],
                       constant uint2 &shape [[buffer(4)]],
                       uint group [[threadgroup_position_in_grid]],
                       ushort lane [[thread_index_in_simdgroup]],
                       ushort simd [[simdgroup_index_in_threadgroup]]) {
    uint row = group * projectionRows + simd;
    if (row >= shape.y) return;
    uint columns = shape.x / 4;
    const device ushort *packed = weights + row * columns;
    const device half *scale = scales + row * (columns / 8);
    float sum0 = 0, sum1 = 0, sum2 = 0, sum3 = 0;
#if defined(YUE2_PAIRED_LAYOUT) || defined(YUE2_M3_MAX)
    #pragma clang loop unroll_count(4)
#endif
    for (uint i = lane; i < columns; i += 32) {
        ushort word = packed[i];
        short4 n = short4(word & 15, (word >> 4) & 15, (word >> 8) & 15, word >> 12);
        float4 q = float4((n ^ 8) - 8);
        float s = float(scale[i / 8]);
        sum0 += s * dot(q, float4(input[i]));
        sum1 += s * dot(q, float4(input[columns + i]));
        sum2 += s * dot(q, float4(input[2 * columns + i]));
        sum3 += s * dot(q, float4(input[3 * columns + i]));
    }
    sum0 = simd_sum(sum0);
    sum1 = simd_sum(sum1);
    sum2 = simd_sum(sum2);
    sum3 = simd_sum(sum3);
    if (lane == 0) {
        output[row] = half(sum0);
        output[shape.y + row] = half(sum1);
        output[2 * shape.y + row] = half(sum2);
        output[3 * shape.y + row] = half(sum3);
    }
}

// Matching channels of two consecutive dot products share a byte
// through low and high nibbles; each lane fetches eight bytes at a time.
kernel void project_q4_paired(device const uint2 *weights [[buffer(0)]],
                       device const half4 *scales [[buffer(1)]],
                       device const half4 *input [[buffer(2)]],
                       device half *output [[buffer(3)]],
                       constant uint2 &shape [[buffer(4)]],
                       uint group [[threadgroup_position_in_grid]],
                       ushort lane [[thread_index_in_simdgroup]],
                       ushort simd [[simdgroup_index_in_threadgroup]]) {
    uint row = group * 4 + simd;
    if (row >= shape.y) return;
    uint columns = shape.x / 4;
    device const uint2 *packed = weights + row * (columns / 4);
    device const half4 *scale = scales + row * (columns / 32);
    float sum0 = 0, sum1 = 0;
    for (uint tile = 0; tile < columns / 128; ++tile) {
        uint2 words = packed[tile * 32 + lane];
        half4 factors = scale[tile * 4 + lane / 8];
        #pragma clang loop unroll(full)
        for (uint j = 0; j < 4; ++j) {
            uint i = tile * 128 + j * 32 + lane;
            uchar4 bytes = as_type<uchar4>(words[j / 2]);
            // Sign extend each two's-complement nibble in the integer domain.
            short4 shifted = as_type<short4>(ushort4(bytes) << (12 - (j & 1) * 4));
            float4 q = float4(shifted >> 12);
            float s = float(factors[j]);
            sum0 += s * dot(q, float4(input[i]));
            sum1 += s * dot(q, float4(input[columns + i]));
        }
    }
    sum0 = simd_sum(sum0);
    sum1 = simd_sum(sum1);
    if (lane == 0) {
        output[row] = half(sum0);
        output[shape.y + row] = half(sum1);
    }
}

kernel void rms_hidden(device const half *source [[buffer(0)]],
                       device const half *weights [[buffer(1)]],
                       device half *target [[buffer(2)]],
                       constant uint &width [[buffer(3)]],
                       uint batch [[threadgroup_position_in_grid]],
                       ushort t [[thread_index_in_threadgroup]],
                       ushort lane [[thread_index_in_simdgroup]],
                       ushort simd [[simdgroup_index_in_threadgroup]]) {
    threadgroup float sums[4];
    float sum = 0;
    for (uint i = t; i < width; i += 128) {
        float v = float(source[batch * width + i]);
        sum += v * v;
    }
    sum = simd_sum(sum);
    if (lane == 0) sums[simd] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = rsqrt((sums[0] + sums[1] + sums[2] + sums[3]) / float(width) + 1.0e-6f);
    for (uint i = t; i < width; i += 128) {
        target[batch * width + i] = half(float(source[batch * width + i]) * inv * float(weights[i]));
    }
}

// Store only the current row. Future steps read the same Metal buffers.
kernel void rotate_and_append(device half *query [[buffer(0)]],
                              device const half *key [[buffer(1)]],
                              device const half *value [[buffer(2)]],
                              device half *keys [[buffer(3)]],
                              device half *values [[buffer(4)]],
                              device const half *qNorm [[buffer(5)]],
                              device const half *kNorm [[buffer(6)]],
                              device const half *rope [[buffer(7)]],
                              constant uint4 &context [[buffer(8)]],
                              uint2 group [[threadgroup_position_in_grid]],
                              ushort lane [[thread_index_in_simdgroup]]) {
    uint batch = group.y;
    bool isQuery = group.x < 16;
    uint head = isQuery ? group.x : group.x - 16;
    uint source = (batch * (isQuery ? 16 : heads) + head) * headWidth;
    const device half *x = (isQuery ? query : key) + source;
    const device half *weights = isQuery ? qNorm : kNorm;
    uint cursor = context[batch];
    uint offset = ((batch * heads + head) * context.z + cursor) * headWidth;
    float4 row = float4(x[lane], x[lane+32], x[lane+64], x[lane+96]);
    float inv = rsqrt(simd_sum(dot(row, row)) / 128.0f + 1.0e-6f);
    for (uint d = lane; d < 64; d += 32) {
        uint high = d + 64;
        float left = float(x[d]) * inv * float(weights[d]);
        float right = float(x[high]) * inv * float(weights[high]);
        float s = float(rope[cursor * 128 + d]);
        float c = float(rope[cursor * 128 + high]);
        if (isQuery) {
            query[source + d] = half(left * c - right * s);
            query[source + high] = half(right * c + left * s);
        } else {
            keys[offset + d] = half(left * c - right * s);
            keys[offset + high] = half(right * c + left * s);
            values[offset + d] = value[source + d];
            values[offset + high] = value[source + high];
        }
    }
}

// Each key/value head is shared by two query heads. Read its tile once.
kernel void attend_tiles(device const half *query [[buffer(0)]],
                         device const half *keys [[buffer(1)]],
                         device const half *values [[buffer(2)]],
                         device float *summary [[buffer(3)]],
                         constant uint4 &context [[buffer(4)]],
                         uint2 group [[threadgroup_position_in_grid]],
                         ushort t [[thread_index_in_threadgroup]],
                         ushort lane [[thread_index_in_simdgroup]],
                         ushort simd [[simdgroup_index_in_threadgroup]]) {
    uint batch = group.x / heads;
    uint start = group.y * tileFrames;
    uint localCount = uint(clamp(int(context[batch] + 1) - int(start), 0, int(tileFrames)));
    uint offset = group.x * context.z * headWidth;
    uint q = (group.x * 2) * headWidth + lane;
    float4 q0 = float4(query[q], query[q + 32], query[q + 64], query[q + 96]);
    q += headWidth;
    float4 q1 = float4(query[q], query[q + 32], query[q + 64], query[q + 96]);
    threadgroup float2 scores[tileFrames];
    threadgroup float2 parts[4];
#if defined(YUE2_PAIRED_LAYOUT) || defined(YUE2_M3_MAX)
    #pragma clang loop unroll_count(4)
#endif
    for (uint frame = simd; frame < tileFrames; frame += 4) {
        float2 score = float2(hiddenScore);
        if (frame < localCount) {
            uint k = offset + (start + frame) * headWidth + lane;
            float4 ki = float4(keys[k], keys[k + 32], keys[k + 64], keys[k + 96]);
            score = simd_sum(float2(dot(q0, ki), dot(q1, ki))) * 0.08838834765f;
        }
        if (lane == 0) scores[frame] = score;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float2 maximum = simd_max(scores[t]);
    if (lane == 0) parts[simd] = maximum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    maximum = max(max(parts[0], parts[1]), max(parts[2], parts[3]));
    float2 weight = t < localCount ? exp(scores[t] - maximum) : float2(0);
    scores[t] = weight;
    float2 sum = simd_sum(weight);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lane == 0) parts[simd] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float2 result = float2(0);
#if defined(YUE2_PAIRED_LAYOUT) || defined(YUE2_M3_MAX)
    #pragma clang loop unroll_count(8)
#endif
    for (uint frame = 0; frame < localCount; ++frame) {
        result += scores[frame] * float(values[offset + (start + frame) * headWidth + t]);
    }
    uint dest0 = (group.x * 2 * context.w + group.y) * 130;
    uint dest1 = dest0 + context.w * 130;
    summary[dest0 + t] = result.x;
    summary[dest1 + t] = result.y;
    if (t == 0) {
        float2 sums = parts[0] + parts[1] + parts[2] + parts[3];
        summary[dest0 + 128] = maximum.x;
        summary[dest1 + 128] = maximum.y;
        summary[dest0 + 129] = sums.x;
        summary[dest1 + 129] = sums.y;
    }
}

kernel void finish_attention(device const float *summary [[buffer(0)]],
                              device half *output [[buffer(1)]],
                              constant uint &tiles [[buffer(2)]],
                              uint head [[threadgroup_position_in_grid]],
                              ushort t [[thread_index_in_threadgroup]]) {
    uint start = head * tiles * 130;
    float maximum = hiddenScore;
    for (uint tile = 0; tile < tiles; ++tile) {
        maximum = max(maximum, summary[start + tile * 130 + 128]);
    }
    float numerator = 0, denominator = 0;
    for (uint tile = 0; tile < tiles; ++tile) {
        uint i = start + tile * 130;
        float weight = exp(summary[i + 128] - maximum);
        numerator += summary[i + t] * weight;
        denominator += summary[i + 129] * weight;
    }
    output[head * headWidth + t] = half(numerator / denominator);
}

kernel void residual(device half *main [[buffer(0)]], device const half *update [[buffer(1)]],
                     uint i [[thread_position_in_grid]]) {
    main[i] += update[i];
}

kernel void activate_gate(device half *gate [[buffer(0)]], device const half *up [[buffer(1)]],
                          uint i [[thread_position_in_grid]]) {
    float x = float(gate[i]);
    gate[i] = half(float(half(x / (1.0f + exp(-x)))) * float(up[i]));
}
