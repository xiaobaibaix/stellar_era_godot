#[compute]

// 大气/体积云 全分辨率合成 pass。
// atmosphere_compute.glsl 在(可能的)半分辨率下算出内散射 L、逐通道透射率 T、地面云影 cshadow,
// 分别写进 scat_tex(rgb=L, a=cshadow) / trans_tex(rgb=T)。本 pass 在【全分辨率】逐像素:
//   1. 读全分辨率场景色 color_image(保持地形/物体边缘清晰);
//   2. 双线性采样低分辨率 L/T/cshadow 场(平滑, 上采样代价低);
//   3. final = (scene·cshadow·T + L)·exposure, 写回 color_image。
// 场景色不经过上采样 → 只有云/大气这类低频场变软, 几何边缘不糊。

#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform image2D color_image;   // 全分辨率场景色(读+写)
layout(set = 1, binding = 0) uniform sampler2D scat_tex;             // rgb=L(内散射), a=cshadow(地面云影)
layout(set = 2, binding = 0) uniform sampler2D trans_tex;            // rgb=T(逐通道透射率)

layout(push_constant, std430) uniform Push {
	vec2 raster_size;   // 全分辨率尺寸
	float exposure;     // 曝光倍率(线性 HDR, 交 WorldEnvironment AgX)
	float _pad;
} pc;

void main() {
	ivec2 ip = ivec2(gl_GlobalInvocationID.xy);
	if (ip.x >= int(pc.raster_size.x) || ip.y >= int(pc.raster_size.y)) {
		return;
	}
	vec2 uv = (vec2(ip) + 0.5) / pc.raster_size;

	vec4 scene = imageLoad(color_image, ip);
	vec4 s = texture(scat_tex, uv);
	vec3 L = s.rgb;
	float cshadow = s.a;
	vec3 T = texture(trans_tex, uv).rgb;

	vec3 finalColor = (scene.rgb * cshadow * T + L) * pc.exposure;
	imageStore(color_image, ip, vec4(finalColor, scene.a));
}
