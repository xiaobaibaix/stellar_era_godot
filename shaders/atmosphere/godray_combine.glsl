#[compute]

// God ray 合并 pass(全分辨率): color += 双线性上采样(低分辨率 glow)。
// godray_compute.glsl 在低分辨率算出仅含光束的 glow 场; 本 pass 逐全分辨率像素采样上采样后叠加到场景色。
// base(场景色)始终全分辨率不动 → 只有柔和的光束辉光随比例变软(体积光本就是低频, 无感)。

#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform image2D color_image;   // 全分辨率(读+写, 叠加)
layout(set = 1, binding = 0) uniform sampler2D glow_tex;             // 低分辨率 glow(线性上采样)

layout(push_constant, std430) uniform Push {
	vec2 raster_size;   // 全分辨率尺寸
	vec2 _pad;
} pc;

void main() {
	ivec2 ip = ivec2(gl_GlobalInvocationID.xy);
	if (ip.x >= int(pc.raster_size.x) || ip.y >= int(pc.raster_size.y)) {
		return;
	}
	vec2 uv = (vec2(ip) + 0.5) / pc.raster_size;
	vec4 c = imageLoad(color_image, ip);
	vec3 glow = texture(glow_tex, uv).rgb;
	imageStore(color_image, ip, vec4(c.rgb + glow, c.a));
}
