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

layout(set = 0, binding = 0, std140) uniform FrameData {
	mat4 inv_proj;             // 投影逆矩阵(NDC → 相机本地/视图空间)
	mat4 cam_xform;            // 相机世界变换(视图空间 → 世界)
	vec4 cam_pos_time;         // xyz=相机世界位, w=时间(云飘动)
	vec4 sun_dir;              // xyz=太阳方向(无穷远平行光, 归一化), w=0
	vec4 sun_pos;              // xyz=太阳世界位置(近场点光源), w=sun_is_local (1=近场, 0=无穷远)
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

layout(set = 1, binding = 0, rgba16f) uniform image2D color_image;
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

// 点 p 处指向太阳的单位方向。
// 无穷远平行光(fd.sun_pos.w<0.5): 用 fd.sun_dir, 整个星球方向恒定 → 晨昏线是大圆(半个球)。
// 近场点光源(fd.sun_pos.w>=0.5): 用 normalize(sun_pos - p), 方向随 p 变 →
// 晨昏线缩成球冠(从光到星球的切线决定), 光越近球冠越小。物理正确, 视觉与地形实照亮范围一致。
vec3 sun_dir_at(vec3 p) {
	if (fd.sun_pos.w >= 0.5) {
		return normalize(fd.sun_pos.xyz - p);
	}
	return normalize(fd.sun_dir.xyz);
}

// 向阳方向光学深度(realtime; M3 会换成 LUT)。被行星挡住则提前停。
vec3 opticalDepthToSun(vec3 p) {
	vec3 dir = sun_dir_at(p);   // 近场点光源: 方向随 p 变(光走直线, 单次 march 内 dir 恒定)
	vec2 h = raySphere(p, dir, fd.planet_center.xyz, fd.radii.y);
	float tMax = max(h.y, 0.0);
	float dt = tMax / max(int(fd.sun_exp_twilight.w), 1);   // steps(太阳方向)
	vec3 sum = vec3(0.0);
	for (int i = 0; i < 64; i++) {
		if (i >= int(fd.sun_exp_twilight.w)) break;
		vec3 sp = p + dir * (dt * (float(i) + 0.5));
		vec2 g = raySphere(sp, dir, fd.planet_center.xyz, fd.radii.x);
		if (g.x > 0.0 && g.y > g.x) break;                  // 太阳被行星遮蔽
		sum += densityAt(sp) * dt;
	}
	return sum;
}

// 软行星遮挡(带 twilight 几何下陷 → 暮光从地平线下渗出)
float planetShadow(vec3 p) {
	vec3 q = p - fd.planet_center.xyz;
	float r = max(length(q), 1e-4);
	float sinElev = dot(q / r, sun_dir_at(p));              // 近场: p 处真实太阳方向
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

// 云向太阳的自阴影(Beer)
float lightMarch(vec3 pos) {
	float st = (fd.radii.w - fd.radii.z) / max(int(fd.counts.z), 1);  // cloudLightSteps
	float sum = 0.0;
	vec3 q = pos;
	vec3 sdir = sun_dir_at(pos);   // 光走直线, 整条 march 方向恒定
	for (int i = 0; i < 12; i++) {
		if (i >= int(fd.counts.z)) break;
		q += sdir * st;
		sum += cloudDensity(q, false) * st;
	}
	return exp(-sum * fd.cloud_a.y * fd.cloud_b.y);         // cdensity * absorb
}

float dayFactor(vec3 pos) {
	vec3 up = normalize(pos - fd.planet_center.xyz);
	return smoothstep(-0.12, 0.12, dot(up, sun_dir_at(pos)));
}

// 地面点的云影
float cloudShadow(vec3 gp) {
	vec3 sd = sun_dir_at(gp);
	vec2 o = raySphere(gp, sd, fd.planet_center.xyz, fd.radii.w);
	vec2 inr = raySphere(gp, sd, fd.planet_center.xyz, fd.radii.z);
	float s0 = max(inr.y, 0.0);
	float s1 = o.y;
	if (s1 <= s0) return 1.0;
	int N = max(int(fd.counts.z), 1);
	float st = (s1 - s0) / float(N);
	float sum = 0.0;
	vec3 q = gp + sd * (s0 + st * 0.5);
	for (int i = 0; i < 12; i++) {
		if (i >= N) break;
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

	vec4 scene = imageLoad(color_image, ipix);
	vec3 sceneColor = scene.rgb;

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

		// 命中自身地表 + 云开 → 白天侧云影, 压暗背景(自身地形)
		if (clouds && fd.cloud_c.x > 0.0 && hitGround && length(hitPos - fd.planet_center.xyz) < fd.radii.w) {
			float day = dayFactor(hitPos);
			if (day > 0.01) {
				float sh = cloudShadow(hitPos);
				cshadowFac = mix(1.0, sh, fd.cloud_c.x * day);
			}
		}

		float span = tFar - tNear;
		int Nmarch = clouds ? max(int(fd.sun_exp_twilight.w), int(fd.counts.x) * 2) : int(fd.sun_exp_twilight.w);
		Nmarch = max(Nmarch, 1);
		float stepU = span / float(Nmarch);
		float jitter = mix(0.5, hash12(uv * vec2(1920.0, 1080.0) + fract(fd.cam_pos_time.w)), fd.ozone_dither.w);
		float t = tNear + stepU * jitter;

		float g2 = fd.mie_params.x;                                   // mieG (循环不变, 提前算)

		for (int i = 0; i < 512; i++) {
			if (t >= tFar) break;
			float jit = (hash12(uv * vec2(1920.0, 1080.0) + vec2(float(i) * 7.31, float(i) * 3.17)) - 0.5) * stepU * 0.25 * fd.ozone_dither.w;
			vec3 p = ro + rd * (t + jit);
			float ds = min(stepU, tFar - t);

			// 太阳方向 + 散射相位: 近场点光源时随 p 变化, 必须在循环内重算(无穷远平行光时退化为常数)。
			vec3 sdir = sun_dir_at(p);
			float mu = dot(rd, sdir);
			float phaseR = (3.0 / (16.0 * PI)) * (1.0 + mu * mu);
			float phaseM = (1.0 - g2) * (1.0 + mu * mu) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g2 * mu, 1e-4), 1.5));
			float cphase = clouds ? (0.4 + fd.cloud_b.z * cloudPhase(mu)) : 0.0;  // silver

			// 大气: 密度×ds → 消光 sigA
			vec3 dens = densityAt(p) * ds;
			vec3 sigA = fd.scatter_r_m.xyz * dens.x + fd.ozone_dither.xyz * dens.z + vec3(fd.scatter_r_m.w * 1.1 * dens.y);

			// 云
			float sigC = 0.0;
			vec3 srcC = vec3(0.0);
			if (clouds) {
				float dcl = cloudDensity(p, true);
				if (dcl > 0.0) {
					float sunT = lightMarch(p);
					// 晨昏线位移 cterminator: 正值→sunUp 有效值变小→day/amb 更早归零, 云的明暗分界线向阳侧移动(更贴近晨昏线);
					// 负值→分界线向背阳侧延伸。默认 0 = 原行为。
					float sunUp = dot(normalize(p - fd.planet_center.xyz), sdir) - fd.cloud_c.y;
					float day = smoothstep(-0.12, 0.12, sunUp);
					float amb = smoothstep(-0.4, 0.15, sunUp);
					float powder = mix(1.0, 1.0 - exp(-dcl * fd.cloud_a.y * 2.0), fd.cloud_b.w);
					vec3 lit = vec3(1.7, 1.6, 1.5) * (sunT * day * cphase * powder) + vec3(0.28, 0.34, 0.45) * amb;
					sigC = dcl * fd.cloud_a.y * ds;
					srcC = sigC * lit;
				}
			}

			// 大气内散射源: 太阳→p 透射(透射率 LUT 查表 / 回退实时 march) × 行星软遮挡 × 散射×相位×密度
			vec3 srcA = vec3(0.0);
			float shadow = planetShadow(p);
			if (shadow > 0.0) {
				vec3 odSun;
				if (pc.lut_on > 0.5) {
					// 透射率 LUT(M3): 球对称 → od 只取决于(r, 太阳天顶余弦 mu)。移植 web sampling。
					float rr = length(p - fd.planet_center.xyz);
					float mus = dot(normalize(p - fd.planet_center.xyz), sdir);
					vec2 luv = vec2(mus * 0.5 + 0.5, clamp((rr - fd.radii.x) / max(fd.radii.y - fd.radii.x, 1e-4), 0.0, 1.0));
					odSun = texture(lut_tex, luv).rgb;
				} else {
					odSun = opticalDepthToSun(p);   // 回退: 实时向太阳 march
				}
				vec3 Tsun = exp(-(fd.scatter_r_m.xyz * odSun.x + vec3(fd.scatter_r_m.w * 1.1) * odSun.y + fd.ozone_dither.xyz * odSun.z)) * shadow;
				srcA = fd.sun_exp_twilight.x * Tsun * (fd.scatter_r_m.xyz * phaseR * dens.x + vec3(fd.scatter_r_m.w * phaseM) * dens.y);
			}

			// front-to-back 合成
			vec3 sigT = sigA + vec3(sigC);
			vec3 src = srcA + srcC;
			if (dot(sigT, sigT) > 1e-12) {
				vec3 dT = exp(-sigT);
				vec3 integ = src * (1.0 - dT) / max(sigT, vec3(1e-7));
				L += T * integ;
				T *= dT;
			}
			t += ds;
		}
	}

	// 精确合成: scene·(云影·T逐通道) + L, 再乘曝光(线性 HDR, 交 WorldEnvironment AgX)
	vec3 bg = sceneColor * cshadowFac;
	vec3 finalColor = (bg * T + L) * fd.sun_exp_twilight.y;     // exposure
	imageStore(color_image, ipix, vec4(finalColor, scene.a));
}
