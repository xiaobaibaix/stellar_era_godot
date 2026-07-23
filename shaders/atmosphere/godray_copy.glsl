#[compute]

// God ray 前置拷贝: 把大气合成后的颜色缓冲复制到临时纹理 lit。
// God ray 是径向模糊(每像素沿"→太阳"方向采样很多邻域像素), 读写同一缓冲会竞态 →
// 先快照到 lit, godray pass 再读 lit 写回 color。两者都是 rgba16f storage image, 逐像素独立。

#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform readonly image2D src_image;   // color(大气合成结果)
layout(set = 1, binding = 0, rgba16f) uniform writeonly image2D dst_image;  // lit(快照)

layout(push_constant, std430) uniform Push {
	vec2 raster_size;
	vec2 _pad;
} pc;

void main() {
	ivec2 ip = ivec2(gl_GlobalInvocationID.xy);
	if (ip.x >= int(pc.raster_size.x) || ip.y >= int(pc.raster_size.y)) {
		return;
	}
	imageStore(dst_image, ip, imageLoad(src_image, ip));
}
