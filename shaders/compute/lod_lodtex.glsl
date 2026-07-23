#[compute]

// Phase 4 LOD lookup texture 填充器。读 lod_traverse 写好的 trav_tex 叶节点, 把每个叶的 lod
// 写到 lodtex[face] 的对应 cell 网格(cell 中心在叶 face-bary 三角形内的所有 cell)。
//
// lodtex: 20 layer × 64×64 R8UI Texture2DArray。cell (i,j) center = ((i+0.5)/64, (j+0.5)/64)。
// 距离壳保证: 同 face 内叶 face-bary 三角形不相交 → 每 cell 唯一 owner → 无需原子。
//
// dispatch 模式(push constant mode):
//   mode = 0: rasterize —— per trav_tex slot(叶), 写叶三角形覆盖的所有 cell
//   mode = -1: reset —— 并行清零整个 lodtex(每线程一个 cell)
//
// reset 必须每帧 rasterize 前调一次: 上帧选中的叶若本帧被取消选择, 它的 cell 不会被覆盖,
// 留下陈旧 lod → cull shader sample 到错的 neighbor lod → 错误 lodDelta → 裂缝。
//
// 与 cull shader 的约定(R2): 边中点 query = midpoint + (1.0/64) * normalize(midpoint - 对角bary)
// 整 cell 宽外推。详见 cull_selftest.gd / lodtex_selftest.gd。

#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) readonly uniform image2D trav_tex;
layout(set = 1, binding = 0, r8ui) writeonly uniform uimage2DArray lodtex;

layout(push_constant, std430) uniform Push {
	int mode;        // 0 = rasterize, -1 = reset
	int _p0;
	int _p1;
	int _p2;
} pc;

const int MAX_PATCHES = 4096;
const int META_ROW = MAX_PATCHES;
const int LODTEX_RES = 64;
const int FACE_COUNT = 20;

// 2D cross product(z 分量), 用于 barycentric inside test。
float _cross2d(vec2 v1, vec2 v2) {
	return v1.x * v2.y - v1.y * v2.x;
}

// 点是否在三角形 (A, B, C) 内(winding-agnostic: 全 >=0 或全 <=0 都算内)。
bool _point_in_tri(vec2 p, vec2 a, vec2 b, vec2 c) {
	float c0 = _cross2d(b - a, p - a);
	float c1 = _cross2d(c - b, p - b);
	float c2 = _cross2d(a - c, p - c);
	bool all_nonneg = (c0 >= 0.0) && (c1 >= 0.0) && (c2 >= 0.0);
	bool all_nonpos = (c0 <= 0.0) && (c1 <= 0.0) && (c2 <= 0.0);
	return all_nonneg || all_nonpos;
}

void main() {
	uint t = gl_GlobalInvocationID.x;

	// ---- reset 模式: 每线程清零 1 个 cell。20*64*64 = 81920 cell / 64 = 1280 groups ----
	if (pc.mode == -1) {
		// t 编码: t = face * (LODTEX_RES * LODTEX_RES) + j * LODTEX_RES + i
		uint cells_per_face = uint(LODTEX_RES * LODTEX_RES);
		uint face = t / cells_per_face;
		uint rem = t - face * cells_per_face;
		uint j = rem / uint(LODTEX_RES);
		uint i = rem - j * uint(LODTEX_RES);
		if (face >= uint(FACE_COUNT)) return;
		imageStore(lodtex, ivec3(int(i), int(j), int(face)), uvec4(0u, 0u, 0u, 0u));
		return;
	}

	// ---- rasterize 模式: 每线程处理 1 个 trav_tex slot(叶) ----
	if (pc.mode != 0) return;

	// 读 count(末行 META_ROW)
	float cnt_f = imageLoad(trav_tex, ivec2(0, META_ROW)).x;
	int cnt = int(cnt_f);
	if (int(t) >= cnt) return;

	vec4 t0 = imageLoad(trav_tex, ivec2(0, int(t)));   // A.xyz, face
	vec4 t1 = imageLoad(trav_tex, ivec2(1, int(t)));   // B.xyz, level
	vec4 t3 = imageLoad(trav_tex, ivec2(3, int(t)));   // ua,va,ub,vb
	vec4 t4 = imageLoad(trav_tex, ivec2(4, int(t)));   // uc,vc,_,_
	int face = int(t0.w);
	int level = int(t1.w);
	vec2 A_bary = t3.xy;
	vec2 B_bary = t3.zw;
	vec2 C_bary = t4.xy;

	// AABB 加速: 只扫三角形外接 box 内的 cell。
	vec2 bmin = min(min(A_bary, B_bary), C_bary);
	vec2 bmax = max(max(A_bary, B_bary), C_bary);
	int i0 = max(0, int(floor(bmin.x * float(LODTEX_RES))));
	int i1 = min(LODTEX_RES - 1, int(ceil(bmax.x * float(LODTEX_RES))));
	int j0 = max(0, int(floor(bmin.y * float(LODTEX_RES))));
	int j1 = min(LODTEX_RES - 1, int(ceil(bmax.y * float(LODTEX_RES))));

	// 把 level 量化成 uint(R8UI 范围 0..255, level 最大 6 远小于 255, 安全)。
	uint lvl_u = uint(level);

	for (int j = j0; j <= j1; j++) {
		for (int i = i0; i <= i1; i++) {
			vec2 uv = (vec2(float(i), float(j)) + 0.5) / float(LODTEX_RES);
			if (_point_in_tri(uv, A_bary, B_bary, C_bary)) {
				imageStore(lodtex, ivec3(i, j, face), uvec4(lvl_u, 0u, 0u, 0u));
			}
		}
	}
}
