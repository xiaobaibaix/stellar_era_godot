shader_type spatial;
// 海洋(移植 effects.js createOcean)。海平面球: 菲涅尔 + Lambert + Blinn-Phong(仅向阳侧)。
// 不透明(写颜色+深度): 必须进 opaque 缓冲 → 大气壳的 screen_texture/depth_texture 才能读到海洋,
// 云才能正确合成在海洋之上(透明海洋不在 screen_texture 里, 会被大气壳的 ALPHA=1.0 替换或盖在云上)。
// 多太阳: 主太阳([0])走 u_sun_dir/u_sun_pos/u_sun_is_local; 额外 1..N 走 u_sun_dirs_add 等数组(对齐 planet.gd MAX_SUNS=4)。
render_mode cull_back;

uniform vec3 u_sun_dir = vec3(0.739, 0.443, 0.515);             // 主太阳方向(无穷远归一化)
uniform vec3 u_sun_pos = vec3(0.0);                             // 主太阳世界位置(近场用)
uniform float u_sun_is_local = 0.0;                             // 1=主太阳近场(用 pos 反推方向)
uniform float u_sun_range = 1e9;                                // 主太阳 omni_range(方向光=无穷大)
uniform float u_sun_atten = 0.0;                                // 主太阳 omni_attenuation
uniform int u_sun_count = 1;                                    // 有效太阳数(1..MAX_SUNS)
uniform vec3 u_sun_dirs_add[3];                                 // 额外太阳方向(槽位 1..3)
uniform vec3 u_sun_positions_add[3];                            // 额外太阳世界位置
uniform float u_sun_is_locals_add[3];                           // 额外太阳 is_local 标志
uniform float u_sun_ranges_add[3];                              // 额外太阳 omni_range
uniform float u_sun_attens_add[3];                              // 额外太阳 omni_attenuation
uniform vec3 u_deep = vec3(0.039, 0.118, 0.247);      // 0x0a1e3f
uniform vec3 u_shallow = vec3(0.180, 0.471, 0.659);   // 0x2e78a8
uniform float u_ambient = 0.2;                        // 夜侧基础亮度(0=全黑)
uniform float u_spec_power = 120.0;                   // 高光锐度(Blinn-Phong power)
uniform float u_spec_strength = 0.9;                  // 高光强度

varying vec3 v_world_normal;
varying vec3 v_world_pos;

void vertex() {
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// 片元指向"第 i 个太阳"的单位方向。i=0 走主槽, i>=1 走额外槽数组(数组索引 = i-1)。
// 近场(is_local>=0.5): 用 sun_pos - v_world_pos 反推; 无穷远: 用 sun_dir。
vec3 sun_dir_at_idx(int i) {
	if (i == 0) {
		if (u_sun_is_local >= 0.5) {
			return normalize(u_sun_pos - v_world_pos);
		}
		return normalize(u_sun_dir);
	}
	int j = i - 1;
	if (j >= 0 && j < 3) {
		if (u_sun_is_locals_add[j] >= 0.5) {
			return normalize(u_sun_positions_add[j] - v_world_pos);
		}
		return normalize(u_sun_dirs_add[j]);
	}
	return normalize(u_sun_dir);
}

// 第 i 个太阳在此片元的能量衰减(对齐 Godot OmniLight3D):
//   atten = pow(max(0, 1-(d/range)²), 1+attenuation)
// 方向光 / range<=0 → 1.0。逐像素算, 与 Godot Forward+ 对地形的衰减同步。
float sun_atten_at_idx(int i) {
	bool is_local = (i == 0) ? (u_sun_is_local >= 0.5) : (i - 1 < 3 && u_sun_is_locals_add[i - 1] >= 0.5);
	if (!is_local) return 1.0;
	float range = (i == 0) ? u_sun_range : (i - 1 < 3 ? u_sun_ranges_add[i - 1] : 1e9);
	float atten_param = (i == 0) ? u_sun_atten : (i - 1 < 3 ? u_sun_attens_add[i - 1] : 0.0);
	if (range < 1e-4) return 1.0;
	vec3 sp = (i == 0) ? u_sun_pos : (i - 1 < 3 ? u_sun_positions_add[i - 1] : vec3(0.0));
	float d = distance(sp, v_world_pos);
	float nd = d / range;
	if (nd >= 1.0) return 0.0;
	return pow(max(0.0, 1.0 - nd * nd), 1.0 + atten_param);
}

void fragment() {
	vec3 cam_pos = INV_VIEW_MATRIX[3].xyz;             // 相机世界位
	vec3 N = normalize(v_world_normal);
	vec3 V = normalize(cam_pos - v_world_pos);          // 片元→相机
	float fres = pow(1.0 - max(dot(N, V), 0.0), 3.0);

	// 多太阳累加 Lambert 漫反射 + Blinn-Phong 高光。每个太阳各算一次 (仅向阳侧)。
	// 点光源按 Godot omni 衰减公式逐像素衰减, 与 Forward+ 地形光照同步。
	float diff_sum = 0.0;
	float spec_sum = 0.0;
	int cnt = max(1, u_sun_count);
	for (int i = 0; i < 4; i++) {
		if (i >= cnt) break;
		float atten = sun_atten_at_idx(i);
		if (atten <= 1e-4) continue;   // 此片元在该太阳光照范围外
		vec3 L = sun_dir_at_idx(i);
		float diff_i = max(dot(N, L), 0.0) * atten;
		diff_sum += diff_i;
		vec3 H = normalize(L + V);
		// 仅向阳侧高光(diff>0 才有镜面反射)
		spec_sum += pow(max(dot(N, H), 0.0), u_spec_power) * step(0.0001, diff_i) * atten;
	}
	diff_sum = clamp(diff_sum, 0.0, 1.0);   // 多太阳叠加可能 > 1, 截到 1 避免过曝
	vec3 col = mix(u_deep, u_shallow, fres);
	col = col * (u_ambient + (1.0 - u_ambient) * diff_sum) + vec3(1.0, 0.96, 0.85) * spec_sum * u_spec_strength;
	ALBEDO = col;
}
