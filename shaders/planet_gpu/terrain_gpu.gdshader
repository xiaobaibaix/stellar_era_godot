// GPU 驱动行星(GpuPlanet)spatial shader。
//
// 【位移/法线/配色噪声块与 shaders/terrain.gdshader 逐位一致】(整段复制, 不用 #include ——
// 以免改动旧 terrain.gdshader, 违反"不删不改旧实现"硬约束)。这是 GPU 视觉与 CPU 碰撞
// (planet_walker 贴地)逐位一致的依据; 若改噪声, 必须同步 terrain.gdshader / terrain.gd。
//
// 与旧 terrain.gdshader 唯一区别: vertex 里方向 d 不再来自 CPU 预烘的理想球面 VERTEX,
// 而是来自 patch 纹理(per-instance 面角点 A/B/C) × patch-local (u,v) face-bary 插值:
//   dir = normalize(A·w + B·u + C·v),  w=1-u-v
// 其余(位移公式 / 有限差分法线 / 配色)完全照搬。
//
// Phase 1 = 固定全 LOD: 20 instance(每 icosahedron 根面一个), 无 compute/裁剪/焊接/裙边。
// patch 纹理由 GpuPlanet(CPU)填; 每个 instance 6 texel(设计文档 §8.3 终极布局):
//   texel0=(A.xyz, face)  texel1=(B.xyz, lod)  texel2=(C.xyz, _)
//   texel3=(ua,va,ub,vb)  texel4=(uc,vc,lodTransAB,lodTransBC)  texel5=(minH,maxH,_,_)
// Phase 1 只读 texel0..2 的 .xyz(A/B/C); bary/lodTrans/minmax 留给 Phase 2+(焊接/裁剪/烘焙路)。
// Phase 2 起: 同一 shader, patch 纹理改由 compute 写入(可变叶数), vertex 逻辑不变。
shader_type spatial;
// cull_front 而非 terrain.gdshader 的 cull_back: GpuPlanet 的 patch mesh 经 UV→sphere
// barycentric 映射后, Godot 视三角面为"背向"(经验结论, 与纸面 CCW 分析不一致 —— 推测
// ArrayMesh + spatial shader 管线某处对 patch-local Y 或索引 winding 有 convention 差异)。
// 用 cull_front 补, 视觉结果正确(正面外向法线可见)。terrain.gdshader 用 cull_back 是因为
// 它的网格是 CPU 烘的理想球面, winding 不同; 此处 cull 模式不参与"逐位一致"约束。
render_mode cull_front;

uniform sampler2D u_patchTex;          // 6×(MAX_PATCHES+1) RGBA32F: per-instance patch 数据 + 末行 count
const int META_ROW = 4096;             // patch 纹理末行(=MAX_PATCHES)存可见 patch 数, 供坍缩守卫读
uniform float u_radius = 100.0;
uniform float u_max_height = 8.0;
uniform float u_normal_eps = 0.001;    // 顶点法线有限差分步长(方向空间)

// ---- 地形参数(与 PlanetParams 对应; 同 terrain.gdshader) ----
uniform float u_sea = 0.0;
uniform float u_warp = 0.2;
uniform float u_warp_freq = 1.0;
uniform float u_cont_freq = 1.2;
uniform float u_cont_oct = 5.0;
uniform float u_cont_gain = 0.5;
uniform float u_cont_lac = 2.0;
uniform float u_mtn_freq = 3.0;
uniform float u_mtn_oct = 5.0;
uniform float u_mtn_strength = 0.6;
uniform float u_plate = 0.5;
uniform float u_plate_freq = 1.6;
uniform float u_moist_freq = 1.2;
uniform float u_alt_range = 1.0;
uniform float u_use_climate = 1.0;

// 种子偏移: 每个噪声 = vec3(seed)·(1,2,3); GpuPlanet 用 Terrain.off(*Seed) 推给 shader。
uniform vec3 u_off_warp = vec3(777.0, 1554.0, 2331.0);
uniform vec3 u_off_cont = vec3(1337.0, 2674.0, 4011.0);
uniform vec3 u_off_mtn = vec3(9001.0, 18002.0, 27003.0);
uniform vec3 u_off_plate = vec3(555.0, 1110.0, 1665.0);
uniform vec3 u_off_moist = vec3(333.0, 666.0, 999.0);

// 调色板(对应 terrain.gd COL_*)
uniform vec3 u_col_ocean_shallow = vec3(0.20, 0.45, 0.62);
uniform vec3 u_col_ocean_deep = vec3(0.03, 0.12, 0.30);
uniform vec3 u_col_beach = vec3(0.82, 0.78, 0.55);
uniform vec3 u_col_dry = vec3(0.78, 0.70, 0.42);
uniform vec3 u_col_wet = vec3(0.13, 0.45, 0.15);
uniform vec3 u_col_cold_dry = vec3(0.55, 0.53, 0.45);
uniform vec3 u_col_cold_wet = vec3(0.22, 0.38, 0.32);
uniform vec3 u_col_rock = vec3(0.50, 0.50, 0.52);
uniform vec3 u_col_snow = vec3(0.97, 0.97, 1.0);

// ===================== 共享整数哈希噪声(逐位复制自 terrain.gdshader 56-169) =====================
uint hash_u32(uint n) {
	n = (n << 13u) ^ n;
	n = n * (n * n * 15731u + 789221u) + 1376312589u;
	return n;
}
uint hash3(uvec3 p) {
	return hash_u32(p.x * 374761393u ^ p.y * 668265263u ^ p.z * 1274126177u);
}
const vec3 GRAD[12] = vec3[12](
	vec3(1.0, 1.0, 0.0), vec3(-1.0, 1.0, 0.0), vec3(1.0, -1.0, 0.0), vec3(-1.0, -1.0, 0.0),
	vec3(1.0, 0.0, 1.0), vec3(-1.0, 0.0, 1.0), vec3(1.0, 0.0, -1.0), vec3(-1.0, 0.0, -1.0),
	vec3(0.0, 1.0, 1.0), vec3(0.0, -1.0, 1.0), vec3(0.0, 1.0, -1.0), vec3(0.0, -1.0, -1.0)
);
float grad_dot(uint h, vec3 v) { return dot(GRAD[int(h % 12u)], v); }
float pfade(float t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }

float noise3(vec3 p) {
	ivec3 i = ivec3(floor(p));
	vec3 f = p - vec3(i);
	vec3 u = vec3(pfade(f.x), pfade(f.y), pfade(f.z));
	uvec3 b = uvec3(i);
	float c000 = grad_dot(hash3(b + uvec3(0u, 0u, 0u)), f - vec3(0.0, 0.0, 0.0));
	float c100 = grad_dot(hash3(b + uvec3(1u, 0u, 0u)), f - vec3(1.0, 0.0, 0.0));
	float c010 = grad_dot(hash3(b + uvec3(0u, 1u, 0u)), f - vec3(0.0, 1.0, 0.0));
	float c110 = grad_dot(hash3(b + uvec3(1u, 1u, 0u)), f - vec3(1.0, 1.0, 0.0));
	float c001 = grad_dot(hash3(b + uvec3(0u, 0u, 1u)), f - vec3(0.0, 0.0, 1.0));
	float c101 = grad_dot(hash3(b + uvec3(1u, 0u, 1u)), f - vec3(1.0, 0.0, 1.0));
	float c011 = grad_dot(hash3(b + uvec3(0u, 1u, 1u)), f - vec3(0.0, 1.0, 1.0));
	float c111 = grad_dot(hash3(b + uvec3(1u, 1u, 1u)), f - vec3(1.0, 1.0, 1.0));
	float x0 = mix(c000, c100, u.x);
	float x1 = mix(c010, c110, u.x);
	float x2 = mix(c001, c101, u.x);
	float x3 = mix(c011, c111, u.x);
	float y0 = mix(x0, x1, u.y);
	float y1 = mix(x2, x3, u.y);
	return mix(y0, y1, u.z);
}

float fbm(vec3 p, float oct, float gain, float lac) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 8; i++) {
		if (float(i) < oct) {
			s += a * noise3(p);
		}
		p *= lac;
		a *= gain;
	}
	return s;
}
float ridged(vec3 p, float oct, float gain, float lac) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 8; i++) {
		if (float(i) < oct) {
			float n = 1.0 - abs(noise3(p));
			s += a * n * n;
		}
		p *= lac;
		a *= gain;
	}
	return s;
}
vec3 hash_to_point(uint h) {
	float rx = float(h & 0xFFFFu) / 65535.0;
	float ry = float((h >> 16u) & 0xFFFFu) / 65535.0;
	float rz = float(hash_u32(h) & 0xFFFFu) / 65535.0;
	return vec3(rx, ry, rz);
}
float worley_f2f1(vec3 p) {
	ivec3 c = ivec3(floor(p));
	float f1 = 1.0e9;
	float f2 = 1.0e9;
	for (int dx = -1; dx <= 1; dx++) {
		for (int dy = -1; dy <= 1; dy++) {
			for (int dz = -1; dz <= 1; dz++) {
				ivec3 cc = c + ivec3(dx, dy, dz);
				vec3 rp = vec3(cc) + hash_to_point(hash3(uvec3(cc)));
				float d = distance(rp, p);
				if (d < f1) { f2 = f1; f1 = d; }
				else if (d < f2) { f2 = d; }
			}
		}
	}
	return f2 - f1;
}

float smoothstep_(float a, float b, float x) {
	float t = clamp((x - a) / (b - a), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

// 高度场(与 terrain.gd height_at 逐位一致)。d = 单位方向。
float terrain_height(vec3 d) {
	vec3 pw = d;
	if (u_warp > 0.0) {
		vec3 wp = d * u_warp_freq + u_off_warp;
		float q0 = noise3(wp);
		float q1 = noise3(wp + vec3(31.4, 12.7, 5.2));
		float q2 = noise3(wp + vec3(7.7, 41.3, 19.1));
		pw = d + vec3(q0, q1, q2) * u_warp;
	}
	float cont = fbm(pw * u_cont_freq + u_off_cont, u_cont_oct, u_cont_gain, u_cont_lac);
	float land = smoothstep_(-0.06, 0.10, cont);
	float mtn = clamp(ridged(pw * u_mtn_freq + u_off_mtn, u_mtn_oct, 0.5, 2.0), 0.0, 1.0);
	float belt = 0.0;
	if (u_plate > 0.0) {
		float f2f1 = worley_f2f1(pw * u_plate_freq + u_off_plate);
		belt = pow(1.0 - clamp(f2f1, 0.0, 1.0), 6.0);
	}
	float mountains = (mtn + belt * u_plate) * land;
	return cont + mountains * u_mtn_strength;
}

// ===================== 顶点/片元 =====================
varying vec3 v_world_pos;
varying vec3 v_world_dir;
varying vec3 v_world_normal;
varying float v_h;
// moisture 噪声原始值(-1..1): vertex() 算一次, fragment() 直接用, 省掉每像素一次 noise3。
varying float v_moist_raw;

void vertex() {
	int id = int(INSTANCE_ID);
	// 坍缩守卫(方案 A 零回读): 超出可见 patch 数的 instance → 退化三角形, 光栅器丢弃。
	// Godot vertex 处理器禁止 return(同 fragment) → 用 if/else 包裹。
	float patch_cnt = texelFetch(u_patchTex, ivec2(0, META_ROW), 0).x;
	if (id < int(patch_cnt)) {
		// 每 instance 的面角点(单位球方向)从 patch 纹理取。
		vec3 A = texelFetch(u_patchTex, ivec2(0, id), 0).xyz;
		vec3 B = texelFetch(u_patchTex, ivec2(1, id), 0).xyz;
		vec3 C = texelFetch(u_patchTex, ivec2(2, id), 0).xyz;
		float u = UV.x;
		float v = UV.y;
		float w = 1.0 - u - v;
		vec3 d = normalize(A * w + B * u + C * v);   // 与 heightmap_baker.dir_from_bary 同式
		float h = terrain_height(d);
		vec3 displaced = d * (u_radius + h * u_max_height);
		VERTEX = displaced;                          // 对象空间(GpuPlanet 原点 = 行星中心)
		v_h = h;
		v_world_dir = normalize((MODEL_MATRIX * vec4(d, 0.0)).xyz);
		v_world_pos = (MODEL_MATRIX * vec4(displaced, 1.0)).xyz;

		// moisture(生物群系配色): 顶点处算一次, varying 插值给 fragment。
		v_moist_raw = noise3(v_world_dir * u_moist_freq + u_off_moist);

		// 解析有限差分法线(与 terrain.gdshader 一致 → 跨 instance 平滑、轮廓无棱)。
		vec3 up_n = abs(d.x) <= 0.9 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
		vec3 t1 = normalize(cross(d, up_n));
		vec3 t2 = normalize(cross(d, t1));
		float neps = u_normal_eps;
		vec3 d1 = normalize(d + t1 * neps);
		vec3 d2 = normalize(d + t2 * neps);
		vec3 p1 = d1 * (u_radius + terrain_height(d1) * u_max_height);
		vec3 p2 = d2 * (u_radius + terrain_height(d2) * u_max_height);
		vec3 n = normalize(cross(p1 - displaced, p2 - displaced));
		if (dot(n, d) < 0.0) n = -n;   // 与 terrain.gdshader 逐位一致: 强制法线外向(dot(n,d)>0)
		// cull_front 下引擎会自动翻 NORMAL 做双面 shading, 这里先翻一次让它翻回来 → 外向法线参与光照。
		NORMAL = -n;
		v_world_normal = normalize((MODEL_MATRIX * vec4(n, 0.0)).xyz);   // 自用 varying 不翻, 保持外向
	} else {
		VERTEX = vec3(0.0);   // 坍缩: 退化三角形, 光栅器丢弃
	}
}

// 配色(逐位复制自 terrain.gdshader 213-239)。
vec3 terrain_color(float h, vec3 d) {
	if (h < u_sea) {
		float t = clamp((u_sea - h) / 0.3, 0.0, 1.0);
		return mix(u_col_ocean_shallow, u_col_ocean_deep, t);
	}
	if (u_use_climate < 0.5) {
		float t = clamp(h, 0.0, 1.0);
		if (t < 0.05) return u_col_beach;
		if (t < 0.4) return u_col_wet;
		if (t < 0.7) return u_col_rock;
		return u_col_snow;
	}
	if (h - u_sea < 0.02) return u_col_beach;
	float alt = clamp(h / u_alt_range, 0.0, 1.0);
	float lat = abs(d.y);
	float temp = clamp((1.0 - alt) * (1.0 - lat), 0.0, 1.0);
	float moist = v_moist_raw * 0.5 + 0.5;
	moist = clamp(moist * (1.0 - alt * 0.4), 0.0, 1.0);
	if (alt > 0.72 || temp < 0.12) {
		float s = clamp((max(alt, 1.0 - temp) - 0.6) / 0.4, 0.0, 1.0);
		return mix(u_col_rock, u_col_snow, s);
	}
	vec3 cold = mix(u_col_cold_dry, u_col_cold_wet, moist);
	vec3 warm = mix(u_col_dry, u_col_wet, moist);
	return mix(cold, warm, temp);
}

void fragment() {
	ALBEDO = terrain_color(v_h, v_world_dir);
}
