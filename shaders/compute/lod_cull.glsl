#[compute]

// GPU LOD 视锥裁剪(Phase 3 v2)。读 lod_traverse 写好的候选 patch, 用 MinMax 纹理构径向 AABB,
// 做 6-平面视锥裁剪, 通过的原子紧凑发射到 cull_tex(供下一帧 vertex shader 读)。
//
// 输入: trav_tex(lod_traverse 写好的 patch 纹理, 含末行 META_ROW count)
// 输出: cull_tex(同布局, 仅含通过裁剪的 patch), 末行 META_ROW 由 metadata 模式写
// MinMax: per-face Texture2DArray 层, R32G32_SFLOAT = (min, max) 径向位移(世界单位)
//
// 每个 invocation 处理一个候选 slot(thread_id ≥ count 直接 return)。
// 流程:
//   1. 读 trav_tex[slot] → A/B/C/face/level + bary
//   2. bary_center = (ua+ub+uc)/3, (va+vb+vc)/3
//   3. mip_k = bake_res_log2 - level(clamp [0, bake_res_log2])
//   4. textureLod(minmax_tex, vec3(bary_center, face), mip_k) → (minH, maxH)
//   5. 构 6 点 AABB: 3 角点 × {minH, maxH} 径向位移
//   6. 6-plane 视锥测试(Godot 约定: normal 内向; AABB P-vertex 任一平面 < 0 → 全外 → cull)
//   7. 通过 → atomicAdd(cull_counter) 取槽, 复制 5 texel 到 cull_tex, texel5 写 (minH, maxH, 0, 0)
//
// push constant 与 lod_traverse 同基底(48B), frustum 走 UBO 避免超 128B 限制。

#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform readonly image2D trav_tex;
layout(set = 1, binding = 0, rgba32f) uniform writeonly image2D cull_tex;
layout(set = 2, binding = 0) uniform sampler2DArray minmax_tex;
layout(set = 3, binding = 0, std430) buffer CountBuf { uint count; } cull_counter;
layout(set = 4, binding = 0, std140) uniform FrameData {
	vec4 frustum[6];            // 6 视锥平面方程 = (nx,ny,nz,d), normal 内向, dot(n,p)+d>=0 表示内侧
	vec4 cam_pos_pad;           // xyz=cam_pos(world), w=radius
	vec4 planet_center_pad;     // xyz=planet_center(world), w=maxHeight
	vec4 consts;                // x=bake_res_log2, y=maxLevel, z=_, w=MAX_PATCHES
} fd;
// Phase 4: LOD lookup texture, 20 face × 64×64 R8UI。每 cell 存覆盖它的叶的 level。
// 边 query 点 = mid + (1/64) * normalize(mid - 对角 bary) 外推 1 cell(详见 lodtex_selftest.gd)。
layout(set = 5, binding = 0, r8ui) readonly uniform uimage2DArray lodtex;

layout(push_constant, std430) uniform Push {
	int mode;        // 0 = cull, -1 = reset counter, -2 = metadata(count → META_ROW)
	int _p0;
	int _p1;
	int _p2;
} pc;

const int MAX_PATCHES = 4096;
const int META_ROW = MAX_PATCHES;

// Phase 4: lodtex 安全采样。OOB(u<0 || v<0 || u+v>1) → 返回 0(面外无邻居, Phase 4.5 跨面处理)。
// 否则 cell (floor(u*64), floor(v*64)) clamp [0, 63] → lodtex[face, j, i]。
int _sample_lodtex_safe(int face, vec2 uv) {
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x + uv.y > 1.0) return 0;
	int ci = clamp(int(floor(uv.x * 64.0)), 0, 63);
	int cj = clamp(int(floor(uv.y * 64.0)), 0, 63);
	return int(imageLoad(lodtex, ivec3(ci, cj, face)).x);
}

void main() {
	// ---- 特殊模式: reset / metadata(单线程, 与 lod_traverse 同模式) ----
	if (pc.mode < 0) {
		if (gl_GlobalInvocationID.x == 0u) {
			if (pc.mode == -1) {
				cull_counter.count = 0u;
			} else if (pc.mode == -2) {
				float c = float(cull_counter.count);
				imageStore(cull_tex, ivec2(0, META_ROW), vec4(c, 0.0, 0.0, 0.0));
			}
		}
		return;
	}

	uint slot = gl_GlobalInvocationID.x;
	if (slot >= uint(MAX_PATCHES)) {
		return;
	}
	// 读候选数(末行 META_ROW)。读一次, 跨过 count 后的线程全部早退。
	float patch_cnt_f = imageLoad(trav_tex, ivec2(0, META_ROW)).x;
	int patch_cnt = int(patch_cnt_f);
	if (int(slot) >= patch_cnt) {
		return;
	}

	vec4 t0 = imageLoad(trav_tex, ivec2(0, int(slot)));
	vec4 t1 = imageLoad(trav_tex, ivec2(1, int(slot)));
	vec4 t2 = imageLoad(trav_tex, ivec2(2, int(slot)));
	vec4 t3 = imageLoad(trav_tex, ivec2(3, int(slot)));
	vec4 t4 = imageLoad(trav_tex, ivec2(4, int(slot)));

	vec3 A = t0.xyz;
	vec3 B = t1.xyz;
	vec3 C = t2.xyz;
	int face = int(t0.w);
	int level = int(t1.w);
	vec2 A_bary = t3.xy;
	vec2 B_bary = t3.zw;
	vec2 C_bary = t4.xy;
	vec2 bary_center = (A_bary + B_bary + C_bary) * (1.0 / 3.0);

	// ---- 采样 MinMax: mip = bake_res_log2 - level(size-matched) ----
	int bake_res_log2 = int(fd.consts.x);
	int mip = clamp(bake_res_log2 - level, 0, bake_res_log2);
	vec2 minmax = textureLod(minmax_tex, vec3(bary_center, float(face)), float(mip)).rg;
	float minH = minmax.x;
	float maxH = minmax.y;
	// 哨兵(三角形外的 cell, 不应发生但守卫): 不裁剪这一槽, 视为通过(让 vertex 处理)
	bool sentinel = (minH > 1.0e20) || (maxH < -1.0e20);

	// ---- 6 点 AABB: 3 角点 × {minH, maxH} 径向位移 ----
	vec3 center = fd.planet_center_pad.xyz;
	float radius = fd.cam_pos_pad.w;
	vec3 A_min = center + A * (radius + minH);
	vec3 A_max = center + A * (radius + maxH);
	vec3 B_min = center + B * (radius + minH);
	vec3 B_max = center + B * (radius + maxH);
	vec3 C_min = center + C * (radius + minH);
	vec3 C_max = center + C * (radius + maxH);
	vec3 box_min = min(min(A_min, A_max), min(min(B_min, B_max), min(C_min, C_max)));
	vec3 box_max = max(max(A_min, A_max), max(max(B_min, B_max), max(C_min, C_max)));

	// ---- 6-plane 视锥测试(Godot 法线内向: dot(n,P-vertex)+d<0 任一平面 → 全外 → cull) ----
	bool culled = false;
	if (!sentinel) {
		for (int i = 0; i < 6; i++) {
			vec4 plane = fd.frustum[i];
			vec3 p_vert;
			p_vert.x = plane.x > 0.0 ? box_max.x : box_min.x;
			p_vert.y = plane.y > 0.0 ? box_max.y : box_min.y;
			p_vert.z = plane.z > 0.0 ? box_max.z : box_min.z;
			if (dot(plane.xyz, p_vert) + plane.w < 0.0) {
				culled = true;
				break;
			}
		}
	}
	if (culled) {
		return;
	}

	// ---- Phase 4: 算 3 边的 lodDelta(自己 - 邻居, max(0, ...)) ----
	// 边端点 bary(已经在 t3 / t4 里):
	//   AB: A=t3.xy, B=t3.zw;   BC: B=t3.zw, C=t4.xy;   CA: C=t4.xy, A=t3.xy
	// 对角(用来定 outward 方向): AB→C, BC→A, CA→B
	float lod_self = float(level);
	float eps_uv = 1.0 / 64.0;   // 整 cell 宽外推(lodtex_selftest (B) 验证)
	// AB 边
	vec2 mid_ab = (A_bary + B_bary) * 0.5;
	vec2 out_ab = mid_ab - C_bary;
	float n_lod_ab = float(_sample_lodtex_safe(face, mid_ab + eps_uv * normalize(out_ab + vec2(1e-8))));
	float lod_d_ab = max(0.0, lod_self - n_lod_ab);
	// BC 边
	vec2 mid_bc = (B_bary + C_bary) * 0.5;
	vec2 out_bc = mid_bc - A_bary;
	float n_lod_bc = float(_sample_lodtex_safe(face, mid_bc + eps_uv * normalize(out_bc + vec2(1e-8))));
	float lod_d_bc = max(0.0, lod_self - n_lod_bc);
	// CA 边
	vec2 mid_ca = (C_bary + A_bary) * 0.5;
	vec2 out_ca = mid_ca - B_bary;
	float n_lod_ca = float(_sample_lodtex_safe(face, mid_ca + eps_uv * normalize(out_ca + vec2(1e-8))));
	float lod_d_ca = max(0.0, lod_self - n_lod_ca);

	// ---- 通过 → 原子发射到 cull_tex ----
	uint out_slot = atomicAdd(cull_counter.count, 1u);
	if (out_slot >= uint(MAX_PATCHES)) {
		return;
	}
	// texel2.w = lodDelta_CA; texel4.zw = (lodDelta_AB, lodDelta_BC)。其余字段不变。
	imageStore(cull_tex, ivec2(0, int(out_slot)), t0);
	imageStore(cull_tex, ivec2(1, int(out_slot)), t1);
	imageStore(cull_tex, ivec2(2, int(out_slot)), vec4(C.xyz, lod_d_ca));
	imageStore(cull_tex, ivec2(3, int(out_slot)), t3);
	imageStore(cull_tex, ivec2(4, int(out_slot)), vec4(C_bary.x, C_bary.y, lod_d_ab, lod_d_bc));
	imageStore(cull_tex, ivec2(5, int(out_slot)), vec4(minH, maxH, 0.0, 0.0));
}
