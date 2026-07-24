#[compute]

// 大气 + 体积云 全屏后处理(compute)。移植自原 spatial 大气球壳 shader 的 raymarch,
// 改为 compute: 读场景 color(全分辨率) + depth → 重建视线 → raymarch 瑞利/米氏/臭氧 + 体积云 →
// front-to-back 合成 → 精确 color = scene·T(rgb) + L(逐通道透射, 比 web 半分辨率标量 T 更准) → 写回 color。
// 输出线性 HDR(不 tonemap), 交给 WorldEnvironment 的 AgX 做全帧统一色调映射。
//
// 深度约定: Godot reverse-Z(depth 1=near, 0=far=天空)。depth>0.0001 视为命中实体(地形/海洋)。
// 相机在壳外(太空)/壳内(地表)走同一条路径(raySphere 算 tNear/tFar, 相机在内 tNear=0)。
//
// M2: 全分辨率单 pass(融合 atmo + composite); M3 会加透射率 LUT; M6 会拆半分辨率 atmo + 全分辨率 composite。

#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

const int MAX_SUNS = 4;

layout(set = 0, binding = 0, std140) uniform FrameData {
	mat4 inv_proj;             // 投影逆矩阵(NDC → 相机本地/视图空间)
	mat4 cam_xform;            // 相机世界变换(视图空间 → 世界)
	vec4 cam_pos_time;         // xyz=相机世界位, w=时间(云飘动)
	vec4 sun_dirs[MAX_SUNS];   // 每个太阳: xyz=方向(无穷远平行光, 归一化), w=is_local(1=近场点光源)
	vec4 sun_poss[MAX_SUNS];   // 每个太阳: xyz=世界位置(近场有效), w=is_active(1=本槽位有太阳)
	vec4 sun_range_atten[MAX_SUNS];   // 每个太阳: x=omni_range(<=0 视为不衰减), y=omni_attenuation(Godot 公式 1+a), zw 备用
	vec4 sun_metas;            // x=有效太阳数 sun_count, y/z/w 备用
	vec4 planet_center;        // xyz=行星中心(世界)
	vec4 radii;                // rground, ratmo, cbottom, ctop
	vec4 scatter_r_m;          // rgb=瑞利散射系数, a=米氏散射系数
	vec4 ozone_dither;         // rgb=臭氧吸收, a=去 banding 抖动强度
	vec4 mie_params;           // mieG, densityFalloff, mieFalloff, shadowSoftness
	vec4 sun_exp_twilight;     // sunIntensity, exposure, twilight, steps(转 int)
	vec4 counts;               // cloudSteps, lightSteps, cloudLightSteps, clouds_on
	vec4 cloud_a;              // coverage, cdensity, cfreq(已按半径归一), cwarp
	vec4 cloud_b;              // cwindspeed, absorb, silver, powder
	vec4 cloud_c;              // cshadow, cterminator, 0, 0
} fd;

// 半分辨率输出: 不再就地合成到场景色, 而是把内散射 L + 逐通道透射率 T + 地面云影因子分离写出,
// 交给全分辨率 composite pass 上采样后合成(scene 保持全分辨率清晰)。
layout(set = 1, binding = 0, rgba16f) uniform image2D scat_image;    // rgb = 内散射 L, a = 地面云影 cshadowFac
layout(set = 1, binding = 1, rgba16f) uniform image2D trans_image;   // rgb = 逐通道透射率 T
layout(set = 2, binding = 0) uniform sampler2D depth_tex;
layout(set = 3, binding = 0) uniform sampler2D lut_tex;   // 透射率 LUT(rgb=向太阳光学深度); lut_on=1 时用

layout(push_constant, std430) uniform Push {
	vec2 raster_size;
	float lut_on;     // 1=查透射率 LUT, 0=实时向太阳 march(回退)
	float _pad1;
} pc;

const float PI = 3.14159265359;

float hash12(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 raySphere(vec3 ro, vec3 rd, vec3 ce, float r) {
	vec3 oc = ro - ce;
	float b = dot(oc, rd);
	float c = dot(oc, oc) - r * r;
	float disc = b * b - c;
	if (disc < 0.0) return vec2(1e20, -1e20);
	float s = sqrt(disc);
	return vec2(-b - s, -b + s);
}

float heightFrac(vec3 p) {
	float r = length(p - fd.planet_center.xyz);
	return clamp((r - fd.radii.x) / max(fd.radii.y - fd.radii.x, 1e-4), 0.0, 1.0);
}

// 返回 (Rayleigh, Mie, Ozone) 密度
vec3 densityAt(vec3 p) {
	float t = heightFrac(p);
	float edge = 1.0 - t;
	float dR = exp(-t * fd.mie_params.y) * edge;            // densityFalloff
	float dM = exp(-t * fd.mie_params.z) * edge;            // mieFalloff
	float dO = max(0.0, 1.0 - abs(t - 0.35) / 0.35);        // ozone 帐篷(峰值 h≈0.35)
	return vec3(dR, dM, dO);
}

// 第 i 个太阳是否有效(槽位 is_active 且索引 < sun_count)。
bool sun_active(int i) {
	return i < int(fd.sun_metas.x) && fd.sun_poss[i].w >= 0.5;
}

// 点 p 处第 i 个太阳的能量衰减(对齐 Godot OmniLight3D):
//   atten = pow(max(0, 1-(d/range)²), 1+attenuation)
// 方向光(is_local<0.5)/range<=0 → 不衰减返回 1。逐像素计算 → 边缘自然渐暗。
// 上一版的"光照范围外仍然亮" bug 就是因为缺这个, 大气永远满强度; 地形这边 Godot 自动按公式衰减。
float sun_atten_for(vec3 p, int i) {
	if (fd.sun_dirs[i].w < 0.5) return 1.0;   // 方向光
	float range = fd.sun_range_atten[i].x;
	if (range < 1e-4) return 1.0;             // range=0 视为不衰减(防御)
	float d = length(fd.sun_poss[i].xyz - p);
	float nd = d / range;
	if (nd >= 1.0) return 0.0;
	float a = fd.sun_range_atten[i].y;
	return pow(max(0.0, 1.0 - nd * nd), 1.0 + a);
}

// 点 p 处指向第 i 个太阳的单位方向。
// 无穷远平行光(is_local<0.5): 用 sun_dirs[i], 整个星球方向恒定 → 晨昏线是大圆(半个球)。
// 近场点光源(is_local>=0.5): 用 normalize(sun_poss[i] - p), 方向随 p 变 →
// 晨昏线缩成球冠(从光到星球的切线决定), 光越近球冠越小。物理正确, 视觉与地形实照亮范围一致。
vec3 sun_dir_for(vec3 p, int i) {
	if (fd.sun_dirs[i].w >= 0.5) {
		return normalize(fd.sun_poss[i].xyz - p);
	}
	return normalize(fd.sun_dirs[i].xyz);
}

// 向阳方向光学深度(realtime; M3 会换成 LUT)。被行星挡住则提前停。
vec3 opticalDepthToSun(vec3 p, int i) {
	vec3 dir = sun_dir_for(p, i);   // 近场点光源: 方向随 p 变(光走直线, 单次 march 内 dir 恒定)
	vec2 h = raySphere(p, dir, fd.planet_center.xyz, fd.radii.y);
	float tMax = max(h.y, 0.0);
	float dt = tMax / max(int(fd.sun_exp_twilight.w), 1);   // steps(太阳方向)
	vec3 sum = vec3(0.0);
	for (int k = 0; k < 64; k++) {
		if (k >= int(fd.sun_exp_twilight.w)) break;
		vec3 sp = p + dir * (dt * (float(k) + 0.5));
		vec2 g = raySphere(sp, dir, fd.planet_center.xyz, fd.radii.x);
		if (g.x > 0.0 && g.y > g.x) break;                  // 太阳被行星遮蔽
		sum += densityAt(sp) * dt;
	}
	return sum;
}

// 软行星遮挡(带 twilight 几何下陷 → 暮光从地平线下渗出)。第 i 个太阳的遮挡。
float planetShadow(vec3 p, int i) {
	vec3 q = p - fd.planet_center.xyz;
	float r = max(length(q), 1e-4);
	float sinElev = dot(q / r, sun_dir_for(p, i));          // 近场: p 处真实太阳方向
	float dip = sqrt(max(1.0 - (fd.radii.x * fd.radii.x) / (r * r), 0.0)) * fd.sun_exp_twilight.z;
	float soft = max(fd.mie_params.w * 0.25, 1e-3);         // shadowSoftness
	return smoothstep(-soft, soft, sinElev + dip);
}

// ===== 体积云辅助(与大气在同一 raymarch 内积分)=====
float hg(float mu, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * mu, 1e-4), 1.5));
}
float cloudPhase(float mu) {
	return mix(hg(mu, 0.8), hg(mu, -0.5), 0.5);
}

float hash3(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
float vnoise(vec3 x) {
	vec3 i = floor(x); vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash3(i + vec3(0.0, 0.0, 0.0)), hash3(i + vec3(1.0, 0.0, 0.0)), f.x),
	               mix(hash3(i + vec3(0.0, 1.0, 0.0)), hash3(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
	           mix(mix(hash3(i + vec3(0.0, 0.0, 1.0)), hash3(i + vec3(1.0, 0.0, 1.0)), f.x),
	               mix(hash3(i + vec3(0.0, 1.0, 1.0)), hash3(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}
float fbm(vec3 p, int oct) {
	float s = 0.0, a = 0.5;
	for (int i = 0; i < 5; i++) {
		if (i >= oct) break;
		s += a * vnoise(p);
		p *= 2.02;
		a *= 0.5;
	}
	return s;
}

// 云密度: 高度梯度 × 覆盖阈值化 fbm。hi=视线采样(域扭曲+4oct), false=光照采样(便宜)
float cloudDensity(vec3 pos, bool hi) {
	float r = length(pos - fd.planet_center.xyz);
	float thick = max(fd.radii.w - fd.radii.z, 1e-4);        // ctop - cbottom
	float h = (r - fd.radii.z) / thick;
	if (h < -1.3 || h > 1.2) return 0.0;
	float heightGrad = smoothstep(-1.2, 0.6, h) * (1.0 - smoothstep(0.6, 1.2, h));
	vec3 sp = (pos - fd.planet_center.xyz) * fd.cloud_a.z   // cfreq(已归一)
	        + vec3(1.0, 0.0, 0.3) * (fd.cam_pos_time.w * fd.cloud_b.x);  // 风(用时间)
	float base;
	if (hi) {
		vec3 w = vec3(fbm(sp * 0.5 + 11.5, 2), fbm(sp * 0.5 + 47.2, 2), fbm(sp * 0.5 + 83.1, 2)) - 0.5;
		base = fbm(sp + fd.cloud_a.w * w, 4);                // cwarp
	} else {
		base = fbm(sp, 3);
	}
	float thr = 1.0 - fd.cloud_a.x;                          // coverage
	return smoothstep(thr, thr + 0.4, base * heightGrad);
}

// 云向第 i 个太阳的自阴影(Beer)
float lightMarch(vec3 pos, int i) {
	float st = (fd.radii.w - fd.radii.z) / max(int(fd.counts.z), 1);  // cloudLightSteps
	float sum = 0.0;
	vec3 q = pos;
	vec3 sdir = sun_dir_for(pos, i);   // 光走直线, 整条 march 方向恒定
	for (int k = 0; k < 12; k++) {
		if (k >= int(fd.counts.z)) break;
		q += sdir * st;
		sum += cloudDensity(q, false) * st;
	}
	return exp(-sum * fd.cloud_a.y * fd.cloud_b.y);         // cdensity * absorb
}

float dayFactor(vec3 pos, int i) {
	vec3 up = normalize(pos - fd.planet_center.xyz);
	return smoothstep(-0.12, 0.12, dot(up, sun_dir_for(pos, i)));
}

// 地面点 gp 对第 i 个太阳的云影
float cloudShadow(vec3 gp, int i) {
	vec3 sd = sun_dir_for(gp, i);
	vec2 o = raySphere(gp, sd, fd.planet_center.xyz, fd.radii.w);
	vec2 inr = raySphere(gp, sd, fd.planet_center.xyz, fd.radii.z);
	float s0 = max(inr.y, 0.0);
	float s1 = o.y;
	if (s1 <= s0) return 1.0;
	int N = max(int(fd.counts.z), 1);
	float st = (s1 - s0) / float(N);
	float sum = 0.0;
	vec3 q = gp + sd * (s0 + st * 0.5);
	for (int k = 0; k < 12; k++) {
		if (k >= N) break;
		sum += cloudDensity(q, false) * st;
		q += sd * st;
	}
	return exp(-sum * fd.cloud_a.y * fd.cloud_b.y);
}

void main() {
	ivec2 ipix = ivec2(gl_GlobalInvocationID.xy);
	if (ipix.x >= int(pc.raster_size.x) || ipix.y >= int(pc.raster_size.y)) {
		return;
	}
	vec2 uv = (vec2(ipix) + 0.5) / pc.raster_size;
	vec2 ndc = uv * 2.0 - 1.0;

	vec3 ro = fd.cam_pos_time.xyz;
	// 视线方向: inv_proj(NDC, far plane) → 视图空间 → cam_xform → 世界; ro→该点归一化得 rd。
	// Godot reverse-Z: NDC z∈[0,1], near=1 / far=0 → far plane 取 z=0。
	// (曾误用 z=-1: 在[0,1]外, inv_proj 外推到比远平面更远的点 → rd 方向系统偏差, 相机转动时视差偏移。)
	vec4 fview = fd.inv_proj * vec4(ndc.xy, 0.0, 1.0);
	vec3 farW = (fd.cam_xform * vec4(fview.xyz / fview.w, 1.0)).xyz;
	vec3 rd = normalize(farW - ro);

	// 场景深度 → 命中点 + 距离(reverse-Z: depth≈0=天空/远平面)
	float depth = texture(depth_tex, uv).r;
	float sceneDist = 1e20;
	vec3 hitPos = ro;
	bool hitGround = false;
	if (depth > 0.0001) {
		// depth 直接 = reverse-Z NDC z([0,1], near=1/far=0)。曾误用 depth*2-1(当[-1,1]) → hitPos 偏远、地面停止点错位。
		vec4 hview = fd.inv_proj * vec4(ndc.xy, depth, 1.0);
		hitPos = (fd.cam_xform * vec4(hview.xyz / hview.w, 1.0)).xyz;
		sceneDist = distance(hitPos, ro);
		hitGround = true;
	}

	// 视线在大气壳内的区间
	vec2 atmo = raySphere(ro, rd, fd.planet_center.xyz, fd.radii.y);
	float tNear = max(atmo.x, 0.0);
	float tFar = atmo.y;
	bool valid = tFar > tNear;
	if (valid) {
		// 积分终止: 解析地面球为主; 场景深度落在合理区间才采纳(地形峰高于海平面时在真实地表停)
		vec2 gnd = raySphere(ro, rd, fd.planet_center.xyz, fd.radii.x);
		float tGround = (gnd.x > 0.0 && gnd.y > gnd.x) ? gnd.x : tFar;
		float tStop = tGround;
		if (hitGround && sceneDist > tNear && sceneDist < tGround) tStop = sceneDist;
		tFar = min(tFar, tStop);
		valid = tFar > tNear;
	}

	vec3 T = vec3(1.0);       // 逐通道透射率(合成 scene·T 用)
	vec3 L = vec3(0.0);       // 累计内散射
	float cshadowFac = 1.0;   // 自身地面云影因子
	if (valid) {
		bool clouds = fd.counts.w > 0.5;

		// 命中自身地表 + 云开 → 白天侧云影, 压暗背景(自身地形)。多太阳: 按 dayFactor × 距离衰减 加权平均云影。
		if (clouds && fd.cloud_c.x > 0.0 && hitGround && length(hitPos - fd.planet_center.xyz) < fd.radii.w) {
			float shSum = 0.0;
			float wSum = 0.0;
			for (int s = 0; s < MAX_SUNS; s++) {
				if (!sun_active(s)) break;
				float atten = sun_atten_for(hitPos, s);
				if (atten <= 1e-4) continue;
				float day = dayFactor(hitPos, s) * atten;
				if (day > 0.01) {
					shSum += day * cloudShadow(hitPos, s);
					wSum += day;
				}
			}
			if (wSum > 0.01) {
				float avgSh = shSum / wSum;
				cshadowFac = mix(1.0, avgSh, fd.cloud_c.x * clamp(wSum, 0.0, 1.0));
			}
		}

		float span = tFar - tNear;
		// 大气用粗步长(整壳均匀); 云壳用细步长(仅 [tCloudIn,tCloudOut] 区间, 无论远近都给 ~cloudSteps 个采样)。
		// 这样: 近地(整条视线都在云里)把云采样封顶到 cloudSteps → 省算; 远观薄云壳仍拿满采样 → 不再稀疏闪烁。
		int atmoN = max(int(fd.sun_exp_twilight.w), 1);              // atmoSteps
		float atmoStepU = span / float(atmoN);
		float cloudStepU = atmoStepU;
		float tCloudIn = 1e20;
		float tCloudOut = -1e20;
		if (clouds) {
			// 云密度支撑区: h=(r-cbottom)/thick ∈ [-1.3,1.2] → 上界 r ≈ cbottom + 1.2*thick(略高于 ctop)。
			// 用这个外球求视线∩云壳区间(单区间近似; 掠射穿壳中间的空洞会被细采样, 但空洞处 cloudDensity=0 只走廉价判空)。
			float thickB = max(fd.radii.w - fd.radii.z, 1e-4);
			float rHi = fd.radii.z + 1.2 * thickB;
			vec2 hHi = raySphere(ro, rd, fd.planet_center.xyz, rHi);
			tCloudIn = clamp(max(hHi.x, tNear), tNear, tFar);
			tCloudOut = clamp(min(hHi.y, tFar), tNear, tFar);
			int cloudN = max(int(fd.counts.x), 1);                  // cloudSteps
			cloudStepU = max((tCloudOut - tCloudIn) / float(cloudN), 1e-4);
		}
		float jitter = mix(0.5, hash12(uv * vec2(1920.0, 1080.0) + fract(fd.cam_pos_time.w)), fd.ozone_dither.w);
		float t = tNear + atmoStepU * jitter;

		float g2 = fd.mie_params.x;                                   // mieG (循环不变, 提前算)

		for (int i = 0; i < 512; i++) {
			if (t >= tFar) break;
			// 自适应步长: 云壳内走细步, 壳外走粗步; 粗步不得跨过云壳入口(否则整片云被跳过), 细步不得跨过出口。
			bool inBand = clouds && (t >= tCloudIn - 1e-4 && t < tCloudOut);
			float ds = inBand ? cloudStepU : atmoStepU;
			if (clouds && !inBand && t < tCloudIn) ds = min(ds, tCloudIn - t);
			if (inBand) ds = min(ds, tCloudOut - t);
			ds = clamp(ds, 1e-4, tFar - t);
			float jit = (hash12(uv * vec2(1920.0, 1080.0) + vec2(float(i) * 7.31, float(i) * 3.17)) - 0.5) * ds * 0.25 * fd.ozone_dither.w;
			vec3 p = ro + rd * (t + jit);

			// 大气: 密度×ds → 消光 sigA (per-pixel, 与太阳数无关)
			vec3 dens = densityAt(p) * ds;
			vec3 sigA = fd.scatter_r_m.xyz * dens.x + fd.ozone_dither.xyz * dens.z + vec3(fd.scatter_r_m.w * 1.1 * dens.y);
			// 无太阳时把消光去色: 否则瑞利逐通道差 (蓝>绿>红) 让 T.b<T.g<T.r, 暗部偏暖,
			// 加上 AgX tonemap 把暗部推紫 → 大气壳呈一条怪紫色环。去色后大气只剩"中性灰暗化"。
			if (int(fd.sun_metas.x) <= 0) {
				float s = (sigA.r + sigA.g + sigA.b) / 3.0;
				sigA = vec3(s);
			}

			// 云消光 (per-pixel; 与太阳数无关, 内散射源 srcC 在太阳循环里累加)
			float sigC = 0.0;
			float dcl = 0.0;
			if (clouds) {
				dcl = cloudDensity(p, true);
				if (dcl > 0.0) {
					sigC = dcl * fd.cloud_a.y * ds;
				}
			}

			// 多太阳累加内散射源 src (= 大气 srcA + 云 srcC, 逐太阳各算一次)
			vec3 src = vec3(0.0);
			for (int s = 0; s < MAX_SUNS; s++) {
				if (!sun_active(s)) break;
				// OmniLight3D 逐像素能量衰减(对齐 Godot 公式); 方向光 → 1.0
				float atten = sun_atten_for(p, s);
				if (atten <= 1e-4) continue;   // 此像素在此太阳光照范围外 → 不参与累加
				vec3 sdir = sun_dir_for(p, s);
				float mu = dot(rd, sdir);
				float phaseR = (3.0 / (16.0 * PI)) * (1.0 + mu * mu);
				float phaseM = (1.0 - g2) * (1.0 + mu * mu) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g2 * mu, 1e-4), 1.5));

				// 大气内散射: 太阳→p 透射 × 行星软遮挡 × 散射×相位×密度 × 距离衰减
				float shadow = planetShadow(p, s);
				if (shadow > 0.0) {
					vec3 odSun;
					if (pc.lut_on > 0.5) {
						// 透射率 LUT(M3): 球对称 → od 只取决于(r, 太阳天顶余弦 mu)。移植 web sampling。
						float rr = length(p - fd.planet_center.xyz);
						float mus = dot(normalize(p - fd.planet_center.xyz), sdir);
						vec2 luv = vec2(mus * 0.5 + 0.5, clamp((rr - fd.radii.x) / max(fd.radii.y - fd.radii.x, 1e-4), 0.0, 1.0));
						odSun = texture(lut_tex, luv).rgb;
					} else {
						odSun = opticalDepthToSun(p, s);   // 回退: 实时向太阳 march
					}
					vec3 Tsun = exp(-(fd.scatter_r_m.xyz * odSun.x + vec3(fd.scatter_r_m.w * 1.1) * odSun.y + fd.ozone_dither.xyz * odSun.z)) * shadow;
					src += fd.sun_exp_twilight.x * Tsun * atten * (fd.scatter_r_m.xyz * phaseR * dens.x + vec3(fd.scatter_r_m.w * phaseM) * dens.y);
				}

				// 云内散射(每太阳各算一次自阴影 + 晨昏线)
				if (clouds && sigC > 0.0) {
					// 晨昏线位移 cterminator: 正值→sunUp 有效值变小→day/amb 更早归零, 云的明暗分界线向阳侧移动(更贴近晨昏线);
					// 负值→分界线向背阳侧延伸。默认 0 = 原行为。
					float sunUp = dot(normalize(p - fd.planet_center.xyz), sdir) - fd.cloud_c.y;
					float day = smoothstep(-0.12, 0.12, sunUp);
					float amb = smoothstep(-0.4, 0.15, sunUp);
					// 夜侧 day=0, 而 sunT 只与 day 相乘 → 直接跳过 cloudLightSteps 步自阴影 march(省整片夜半球云的光照采样, 结果不变)。
					float sunT = (day > 0.0) ? lightMarch(p, s) : 0.0;
					float cphase = 0.4 + fd.cloud_b.z * cloudPhase(mu);   // silver
					float powder = mix(1.0, 1.0 - exp(-dcl * fd.cloud_a.y * 2.0), fd.cloud_b.w);
					vec3 lit = vec3(1.7, 1.6, 1.5) * (sunT * day * cphase * powder) + vec3(0.28, 0.34, 0.45) * amb;
					src += sigC * lit * atten;
				}
			}

			// front-to-back 合成
			vec3 sigT = sigA + vec3(sigC);
			if (dot(sigT, sigT) > 1e-12) {
				vec3 dT = exp(-sigT);
				vec3 integ = src * (1.0 - dT) / max(sigT, vec3(1e-7));
				L += T * integ;
				T *= dT;
			}
			// 早停: 累计透射率极低时(被厚云/深大气挡住), 后续采样贡献 <0.2%, 直接结束剩余步进(结果肉眼无变化)。
			if (max(max(T.r, T.g), T.b) < 0.002) break;
			t += ds;
		}
	}

	// 分离写出(半分辨率): L(内散射)、T(逐通道透射率)、cshadowFac(地面云影)。
	// 全分辨率 composite pass 会做: final = (scene·cshadow·T + L)·exposure。
	// 曝光不在此乘, 留给 composite(避免半分辨率场把曝光烘进上采样)。
	imageStore(scat_image, ipix, vec4(L, cshadowFac));
	imageStore(trans_image, ipix, vec4(T, 1.0));
}
