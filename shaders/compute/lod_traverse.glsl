#[compute]

// GPU LOD 四叉树遍历(Phase 2)。单遍距离壳测试 + 原子紧凑发射, 无 ping-pong(§5.3 ping-pong 是 Phase 6 优化项)。
//
// 每个 invocation = 一个候选节点 (face, level, idx)。寄存器内中点递推重建 3 角点(同 qnode._split 子序:
//   子0=[A,ab,ca] 子1=[ab,B,bc] 子2=[ca,bc,C] 子3=[ab,bc,ca]), 算节点中心到相机距离, 用【保守几何误差
//   g_err = maxHeight / 2^level】的 SSE 距离壳判定是否为选中叶:
//     level==0:              dist >= split_d(0)             → 叶(根不细分); 否则根细分, 往下找
//     level>0, <maxLevel:    split_d(L) <= dist < 2·split_d(L) → 叶(父细分了、自己不细分)
//     level==maxLevel:       dist < 2·split_d(L)            → 叶(最深, 父细分了)
//   其中 split_d(L) = C_const / 2^L, C_const = maxHeight·K/T, K=vp_h/(2·tan(fov/2)), T=sseThresholdPixels。
//   证明(单调): split_d 随 L 单调降 → dist<2·split_d(L)=split_d(L-1) 蕴含 dist<split_d(L-2)<...<split_d(0),
//   即所有祖先都细分 → 本节点存在; 再加 dist>=split_d(L) → 自己不细分 → 是叶。无需 ping-pong。
//
// 选中叶 → atomicAdd(counter) 取槽, imageStore 6 texel 到 patch 纹理(Phase2 只写 A/B/C; bary/lodTrans/minmax=0,
//   混合路 vertex shader 不读 bary; 焊接/裁剪/MinMax 留 Phase 4/5/6)。内容自适应(实际高差)也留 Phase 6。
//
// dispatch: 每帧 per-level 一次(group 数 = ceil(20·4^level / 64)), push constant 带 level。
//   level == -1: reset 模式(线程0 把 counter=0, 帧首调一次)。
//   level == -2: metadata 模式(遍历完后线程0 把 counter 写进 patch 纹理末行, 供 vertex shader 读 count 坍缩)。
//
// 面角点硬编码(黄金比 PHI, 与 gpu_ico.gd RAW_VERTS/FACES 逐位一致)——消除 uniform buffer, 简化绑定。
// 不依赖任何主线程数据; 相机/参数全走 push constant(每帧 GpuPlanet._process 推)。

#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D patch_tex;
layout(set = 1, binding = 0, std430) buffer CountBuf { uint count; } counter;

layout(push_constant, std430) uniform Push {
	vec4 cam_pos_pad;        // xyz = cam_pos(world), w = radius
	vec4 planet_center_pad;  // xyz = planet_center(world), w = maxHeight
	vec4 consts;             // x = C_const, y = maxLevel, z = level, w = MAX_PATCHES
} pc;

const float PHI = 1.6180339887498948482;   // (1+√5)/2, 与 gpu_ico.gd T 一致
const vec3 RAW[12] = vec3[12](
	vec3(-1.0, PHI, 0.0), vec3(1.0, PHI, 0.0), vec3(-1.0, -PHI, 0.0), vec3(1.0, -PHI, 0.0),
	vec3(0.0, -1.0, PHI), vec3(0.0, 1.0, PHI), vec3(0.0, -1.0, -PHI), vec3(0.0, 1.0, -PHI),
	vec3(PHI, 0.0, -1.0), vec3(PHI, 0.0, 1.0), vec3(-PHI, 0.0, -1.0), vec3(-PHI, 0.0, 1.0)
);
// 20 面 × 3 顶点索引(绕序与 gpu_ico.gd FACES 一致)。
const int FACES[60] = int[60](
	0, 11, 5,  0, 5, 1,  0, 1, 7,  0, 7, 10, 0, 10, 11,
	1, 5, 9,  5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
	3, 9, 4,  3, 4, 2,  3, 2, 6,  3, 6, 8,  3, 8, 9,
	4, 9, 5,  2, 4, 11, 6, 2, 10, 8, 6, 7,  9, 8, 1
);
const int MAX_PATCHES = 4096;
const int META_ROW = MAX_PATCHES;   // patch 纹理末行(第 4096 行)存 count, 供 vertex shader 坍缩

void main() {
	int level = int(pc.consts.z);
	uint t = gl_GlobalInvocationID.x;

	// ---- 特殊模式: reset / metadata(单线程, 帧首/帧末各一次) ----
	if (level < 0) {
		if (t == 0u) {
			if (level == -1) {
				counter.count = 0u;
			} else if (level == -2) {
				float c = float(counter.count);
				imageStore(patch_tex, ivec2(0, META_ROW), vec4(c, 0.0, 0.0, 0.0));
			}
		}
		return;
	}

	// ---- 解码 (face, idx): t = face·4^level + idx ----
	int nodesPerFace = 1;
	for (int i = 0; i < level; i++) { nodesPerFace *= 4; }
	int totalNodes = 20 * nodesPerFace;
	if (int(t) >= totalNodes) {
		return;
	}
	int face = int(t) / nodesPerFace;
	int idx = int(t) - face * nodesPerFace;

	// ---- 重建 3 角点(中点递推, MSB 先: b=level-1 是第一层细分选择) ----
	vec3 A = normalize(RAW[FACES[face * 3]]);
	vec3 B = normalize(RAW[FACES[face * 3 + 1]]);
	vec3 C = normalize(RAW[FACES[face * 3 + 2]]);
	for (int b = level - 1; b >= 0; b--) {
		int digit = (idx >> (2 * b)) & 3;
		vec3 ab = normalize(A + B);
		vec3 bc = normalize(B + C);
		vec3 ca = normalize(C + A);
		if (digit == 0) { vec3 oA = A; B = ab; C = ca; A = oA; }   // 子0=[A,ab,ca]
		else if (digit == 1) { vec3 oB = B; A = ab; C = bc; B = oB; } // 子1=[ab,B,bc]
		else if (digit == 2) { vec3 oC = C; A = ca; B = bc; C = oC; } // 子2=[ca,bc,C]
		else { A = ab; B = bc; C = ca; }                            // 子3=[ab,bc,ca]
	}

	// ---- SSE 距离壳判定(保守 g_err = maxHeight/2^level) ----
	int maxLevel = int(pc.consts.y);
	vec3 center_dir = normalize(A + B + C);
	vec3 center_world = pc.planet_center_pad.xyz + center_dir * pc.cam_pos_pad.w;   // radius
	float dist = distance(pc.cam_pos_pad.xyz, center_world);
	float sd_l = pc.consts.x / exp2(float(level));   // split_d(level) = C_const / 2^level
	bool self_no_split = (level >= maxLevel) || (dist >= sd_l);
	bool parent_split = (level == 0) || (dist < sd_l * 2.0);
	if (!(self_no_split && parent_split)) {
		return;
	}

	// ---- 选中叶 → 原子发射(槽超 MAX_PATCHES 则丢弃, 防越界) ----
	uint slot = atomicAdd(counter.count, 1u);
	if (slot >= uint(MAX_PATCHES)) {
		return;
	}
	imageStore(patch_tex, ivec2(0, int(slot)), vec4(A, float(face)));
	imageStore(patch_tex, ivec2(1, int(slot)), vec4(B, float(level)));
	imageStore(patch_tex, ivec2(2, int(slot)), vec4(C, 0.0));
	imageStore(patch_tex, ivec2(3, int(slot)), vec4(0.0));   // bary(Phase2 不用)
	imageStore(patch_tex, ivec2(4, int(slot)), vec4(0.0));   // lodTrans(Phase4)
	imageStore(patch_tex, ivec2(5, int(slot)), vec4(0.0));   // minmax(Phase3/6)
}
