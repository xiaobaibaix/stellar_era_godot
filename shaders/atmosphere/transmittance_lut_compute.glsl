#[compute]

// 透射率 LUT 预烘(M3, 移植自 web effects.js createTransmittanceLUT)。
// 大气球对称 → 某点沿太阳方向的光学深度只取决于(该点半径 r, 太阳天顶余弦 mu)。
// 烘成 256(mu)×64(r) 表: rgb = (瑞利, 米氏, 臭氧)光学深度。运行时大气 pass 查表替代每采样点的"向太阳 march"。
// 局部坐标系(行星中心=原点): origin=(0,r,0), dir=(sqrt(1-mu^2), mu, 0)。撞地面则只积到地表(有限值),
// 硬遮挡由大气 pass 的 planetShadow() 平滑处理。参数(rground/ratmo/densityFalloff/mieFalloff)变化时重烘一次。

#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D lut_image;

layout(push_constant, std430) uniform Push {
	vec4 params;   // x=rground, y=ratmo, z=densityFalloff, w=mieFalloff
} pc;

// 局部坐标系密度(行星中心=原点); 与 atmosphere_compute.glsl 的 densityAt 同式。
vec3 densityAtLocal(vec3 p) {
	float t = clamp((length(p) - pc.params.x) / max(pc.params.y - pc.params.x, 1e-4), 0.0, 1.0);
	float edge = 1.0 - t;
	float dR = exp(-t * pc.params.z) * edge;            // densityFalloff
	float dM = exp(-t * pc.params.w) * edge;            // mieFalloff
	float dO = max(0.0, 1.0 - abs(t - 0.35) / 0.35);    // 臭氧帐篷(峰 h≈0.35)
	return vec3(dR, dM, dO);
}

vec2 raySphereOrigin(vec3 ro, vec3 rd, float r) {
	float b = dot(ro, rd);
	float c = dot(ro, ro) - r * r;
	float d = b * b - c;
	if (d < 0.0) return vec2(1e20, -1e20);
	float s = sqrt(d);
	return vec2(-b - s, -b + s);
}

void main() {
	ivec2 ip = ivec2(gl_GlobalInvocationID.xy);
	ivec2 sz = imageSize(lut_image);
	if (ip.x >= sz.x || ip.y >= sz.y) {
		return;
	}
	vec2 uv = (vec2(ip) + 0.5) / vec2(sz);
	float mu = uv.x * 2.0 - 1.0;                          // 天顶余弦 [-1,1]
	float r = mix(pc.params.x, pc.params.y, uv.y);        // 半径 [rground, ratmo]
	vec3 origin = vec3(0.0, r, 0.0);
	vec3 dir = vec3(sqrt(max(1.0 - mu * mu, 0.0)), mu, 0.0);

	// 积到大气顶, 撞地面则只到地表
	vec2 top = raySphereOrigin(origin, dir, pc.params.y);
	float far = max(top.y, 0.0);
	vec2 gnd = raySphereOrigin(origin, dir, pc.params.x);
	if (gnd.x > 0.0 && gnd.y > gnd.x) {
		far = min(far, gnd.x);
	}

	const int N = 40;
	float st = far / float(N);
	vec3 od = vec3(0.0);
	vec3 p = origin + dir * (st * 0.5);
	for (int i = 0; i < N; i++) {
		od += densityAtLocal(p) * st;
		p += dir * st;
	}
	imageStore(lut_image, ip, vec4(od, 1.0));
}
