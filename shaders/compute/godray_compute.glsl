#[compute]

// 体积光 God rays(屏幕空间径向光束)。移植自 web src/effects.js createGodrayPass。
// 以太阳的屏幕位置(sun_uv)为中心, 每像素沿"当前像素→太阳"方向对已合成图像(lit 快照)径向采样,
// 只取较亮处(smoothstep 阈值)作为光源, 逐步 decay 衰减累加 → 云/山缝隙间透出的光束。
// out = base + accum * strength * sun_vis; 写回 color(线性 HDR, 交 WorldEnvironment 的 AgX)。
// sun_uv/sun_vis 由 AtmosphereCompositor 主线程按相机矩阵算好经 push constant 传入。

#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform image2D color_image;          // 写回(dst)
layout(set = 1, binding = 0, rgba16f) uniform readonly image2D lit_image;   // 读(src, = color 快照)

layout(push_constant, std430) uniform Push {
	vec2 raster_size;
	vec2 sun_uv;          // 太阳屏幕 uv([0,1])
	vec4 p0;              // sunVis, strength, density, decay
	vec4 p1;              // weight, threshold, samples, _pad
} pc;

void main() {
	ivec2 ip = ivec2(gl_GlobalInvocationID.xy);
	if (ip.x >= int(pc.raster_size.x) || ip.y >= int(pc.raster_size.y)) {
		return;
	}
	vec3 base = imageLoad(lit_image, ip).rgb;
	float sun_vis = pc.p0.x;
	if (sun_vis <= 0.001) {
		imageStore(color_image, ip, vec4(base, 1.0));   // 太阳不在视野 → 直通
		return;
	}
	float strength = pc.p0.y;
	float density = pc.p0.z;
	float decay = pc.p0.w;
	float weight = pc.p1.x;
	float threshold = pc.p1.y;
	int samples = int(pc.p1.z);

	vec2 uv = (vec2(ip) + 0.5) / pc.raster_size;
	vec2 delta = (uv - pc.sun_uv) * (density / float(max(samples, 1)));
	vec2 coord = uv;
	float illum = 1.0;
	vec3 accum = vec3(0.0);
	for (int i = 0; i < 128; i++) {
		if (i >= samples) break;
		coord -= delta;
		ivec2 sp = ivec2(clamp(coord * pc.raster_size, vec2(0.0), pc.raster_size - vec2(1.0)));
		vec3 s = imageLoad(lit_image, sp).rgb;
		float lum = dot(s, vec3(0.299, 0.587, 0.114));
		s *= smoothstep(threshold, threshold + 0.35, lum);   // 只取较亮处(天空/太阳)作光源
		accum += s * illum * weight;
		illum *= decay;
	}
	accum /= float(max(samples, 1));
	vec3 outc = base + accum * strength * sun_vis;
	imageStore(color_image, ip, vec4(outc, 1.0));
}
