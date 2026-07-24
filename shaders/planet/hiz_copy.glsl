#[compute]

// Phase 5: Hi-Z 金字塔 mip0 拷贝。把场景深度缓冲(reverse-Z: near→1, far→0)逐像素拷进
// 自有的 R32F 金字塔 mip0。之后 hiz_reduce.glsl 逐级 2×2 取 min(reverse-Z 最远)归约。
//
// 深度按 SAMPLER_WITH_TEXTURE 绑(与 atmosphere_compositor 读深度同款), texelFetch 取原值。
// dst = 金字塔 mip0 的 slice view(STORAGE image, 与深度同尺寸)。
//
// 由 GpuHizCompositor 在 POST_OPAQUE 派发(此时不透明几何已写深度)。1 帧延迟: 本帧建、下帧
// LOD cull 读(见 gpu_lod_compositor.gd / 设计文档 §3.4、§7.4)。

#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_tex;
layout(set = 1, binding = 0, r32f) uniform writeonly image2D dst;

layout(push_constant, std430) uniform Push {
	int w;    // mip0 宽(= 深度宽)
	int h;    // mip0 高(= 深度高)
	int _p0;
	int _p1;
} pc;

void main() {
	ivec2 c = ivec2(gl_GlobalInvocationID.xy);
	if (c.x >= pc.w || c.y >= pc.h) {
		return;
	}
	float d = texelFetch(depth_tex, c, 0).r;   // reverse-Z 原值
	imageStore(dst, c, vec4(d, 0.0, 0.0, 0.0));
}
