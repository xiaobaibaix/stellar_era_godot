#[compute]

// Phase 5: Hi-Z 金字塔逐级归约。dst(mip k) = src(mip k-1) 覆盖 texel 的 min。
// reverse-Z(near→1, far→0)下 min = "该区域内最远的最近面" → 遮挡测试保守(不误剔)。
//
// 奇数维处理: dst texel 覆盖的 src 区域是 2×2, 但当 src 维为奇数时边缘要多覆盖 1 行/列, 否则
// 漏掉的 texel 可能更远(min 更小), 我们的 dst 会偏大 → 误判为近 → 过剔。这里对奇数维统一多采
// 一行/列(多采 = 扩大覆盖 = min 更小 = 更保守/欠剔, 安全)。clamp 采样避免越界。
//
// 由 GpuHizCompositor per-mip 派发一次(src/dst 为对应 mip 的 slice view, STORAGE image)。

#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, r32f) uniform readonly image2D src;
layout(set = 1, binding = 0, r32f) uniform writeonly image2D dst;

layout(push_constant, std430) uniform Push {
	int dw;   // dst 宽
	int dh;   // dst 高
	int sw;   // src 宽
	int sh;   // src 高
} pc;

float load_s(ivec2 p) {
	p = clamp(p, ivec2(0), ivec2(pc.sw - 1, pc.sh - 1));
	return imageLoad(src, p).r;
}

void main() {
	ivec2 c = ivec2(gl_GlobalInvocationID.xy);
	if (c.x >= pc.dw || c.y >= pc.dh) {
		return;
	}
	ivec2 s = c * 2;
	float m = load_s(s);
	m = min(m, load_s(s + ivec2(1, 0)));
	m = min(m, load_s(s + ivec2(0, 1)));
	m = min(m, load_s(s + ivec2(1, 1)));
	if ((pc.sw & 1) != 0) {
		m = min(m, load_s(s + ivec2(2, 0)));
		m = min(m, load_s(s + ivec2(2, 1)));
	}
	if ((pc.sh & 1) != 0) {
		m = min(m, load_s(s + ivec2(0, 2)));
		m = min(m, load_s(s + ivec2(1, 2)));
	}
	if (((pc.sw & 1) != 0) && ((pc.sh & 1) != 0)) {
		m = min(m, load_s(s + ivec2(2, 2)));
	}
	imageStore(dst, c, vec4(m, 0.0, 0.0, 0.0));
}
