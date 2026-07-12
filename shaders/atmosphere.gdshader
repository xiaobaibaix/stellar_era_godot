shader_type spatial;
// 大气壳 + 体积云(移植 effects.js createAtmospherePass 的统一积分路径)。球壳 spatial shader:
// 读 screen_texture(场景色) + depth_texture(场景深度), 沿视线 raymarch Rayleigh/Mie/ozone + 体积云,
// 用场景深度 + 解析地面球终止积分, front-to-back 复合 color = sceneColor*T + L;
// 输出线性辐亮度, 色调映射交给 WorldEnvironment 的 AgX 对整帧统一处理(不在片元里做 ACES)。
//
// 云与大气在【同一条视线积分】里一起采样 → 云只是连续大气里更密的一团, 不再有分层分界线;
// 深度顺序(云前/云内/云后的大气)也天然正确。u_clouds_on=0 时退化为纯大气(与旧版一致)。
//
// 深度约定: Godot 4 用 reverse-Z(depth 1=near, 0=far=天空)。几何 depth>0, 天空 depth≈0。
// 反投影: ndc.z = depth*2-1 → INV_PROJECTION → INV_VIEW。地面球 uRground 兜底(深度读不准也安全)。
//
// render_mode 说明:
// - cull_disabled: 双面渲染。圆盘上的【近侧壳面】比地形更靠近相机 → 通过深度测试, 覆盖整盘画大气+云;
//   远侧壳面在地形之后 → 被地形深度(early-Z)廉价剔除。相机进壳内(角色模式)时头顶壳面是最近几何 →
//   同样通过深度测试画出大气。不依赖 depth_test_disabled(该标志运行期不可靠 → 曾导致运行时云被地形盖住)。
// - depth_draw_never: 壳不写深度(只测), 避免壳互相/与地形乱写深度。积分终止靠场景深度纹理 + 解析地面球。
// - unshaded: 大气辐亮度已在片元里自行积分(含太阳散射/行星阴影 + 云自阴影), 不能再被引擎方向光二次照亮。
render_mode cull_disabled, blend_mix, depth_draw_never, unshaded;

uniform sampler2D screen_texture : hint_screen_texture;
uniform sampler2D depth_texture : hint_depth_texture;

uniform vec3 u_sun_dir = vec3(0.739, 0.443, 0.515);
uniform vec3 u_planet_center = vec3(0.0);
uniform float u_rground = 100.0;        // 海平面/地面球半径
uniform float u_ratmo = 108.0;          // 大气顶半径(= 壳半径)
uniform float u_density_falloff = 6.0;  // Rayleigh 指数衰减
uniform float u_mie_falloff = 16.0;     // Mie 衰减
uniform vec3 u_scatter_r = vec3(0.00853, 0.02596, 0.05464);  // RAY_RATIO×atmoRayleigh
uniform float u_scatter_m = 0.03;       // atmoMie
uniform float u_mie_g = 0.76;           // atmoMieG
uniform vec3 u_ozone = vec3(0.007, 0.02, 0.0009);            // OZONE_RATIO×atmoOzone
uniform float u_sun_intensity = 22.0;   // atmoSunIntensity
uniform float u_exposure = 1.0;         // atmoExposure(线性增益; 非线性映射由 AgX 负责)
uniform int u_steps = 24;               // 视线积分步数(纯大气)
uniform int u_light_steps = 8;          // 向阳光学深度步数
uniform float u_shadow_softness = 0.6;  // 晨昏带软度
uniform float u_twilight = 0.3;         // 几何下陷(暮光)
uniform float u_dither = 0.5;           // 去 banding 抖动

// —— 体积云(与大气同一 raymarch 积分; u_clouds_on=1 开启)——
uniform float u_clouds_on = 0.0;        // 1=同积分叠云, 0=纯大气
uniform int u_cloud_steps = 24;         // 云开启时视线步数基准: max(u_steps, u_cloud_steps*2)
uniform float u_cbottom = 101.0;        // 云底半径(世界单位) = radius×cloudBottom
uniform float u_ctop = 106.0;           // 云顶半径 = radius×cloudTop(必须 ≤ u_ratmo)
uniform float u_coverage = 0.5;         // 覆盖率(越大云越多)
uniform float u_cdensity = 1.2;         // 云消光强度
uniform float u_cfreq = 0.06;           // 噪声频率(越大云越碎)
uniform float u_cwarp = 0.5;            // 域扭曲(飘逸感)
uniform vec3 u_cwind = vec3(1.0, 0.0, 0.3);   // 风向
uniform float u_cwind_speed = 0.6;      // 飘动速度
uniform int u_clight_steps = 6;         // 云向太阳自阴影步数
uniform float u_cabsorb = 1.0;          // 云光照吸收(自阴影强度)
uniform vec3 u_suncolor = vec3(1.7, 1.6, 1.5);     // 云受阳光色(HDR, 线性)
uniform vec3 u_ambient = vec3(0.28, 0.34, 0.45);   // 天空环境光(线性)
uniform float u_silver = 1.0;           // 银边(前向散射相位)强度
uniform float u_powder = 0.6;           // powder 暗边强度
uniform float u_cshadow = 0.7;          // 云影投到地表强度(0=关)

varying vec3 v_world_pos;

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
	float r = length(p - u_planet_center);
	return clamp((r - u_rground) / max(u_ratmo - u_rground, 1e-4), 0.0, 1.0);
}

// 返回 (Rayleigh, Mie, Ozone) 密度
vec3 densityAt(vec3 p) {
	float t = heightFrac(p);
	float edge = 1.0 - t;
	float dR = exp(-t * u_density_falloff) * edge;
	float dM = exp(-t * u_mie_falloff) * edge;
	float dO = max(0.0, 1.0 - abs(t - 0.35) / 0.35);   // ozone 帐篷(峰值在 h≈0.35)
	return vec3(dR, dM, dO);
}

// 向阳方向光学深度(realtime, 无 LUT)。被行星挡住则提前停。
vec3 opticalDepthToSun(vec3 p) {
	vec3 dir = normalize(u_sun_dir);
	vec2 h = raySphere(p, dir, u_planet_center, u_ratmo);
	float tMax = max(h.y, 0.0);
	float dt = tMax / float(u_light_steps);
	vec3 sum = vec3(0.0);
	for (int i = 0; i < 64; i++) {
		if (i >= u_light_steps) break;
		vec3 sp = p + dir * (dt * (float(i) + 0.5));
		vec2 g = raySphere(sp, dir, u_planet_center, u_rground);
		if (g.x > 0.0 && g.y > g.x) break;   // 太阳被行星遮蔽
		sum += densityAt(sp) * dt;
	}
	return sum;
}

// 软行星遮挡(带 twilight 几何下陷 → 暮光从地平线下渗出)
float planetShadow(vec3 p) {
	vec3 q = p - u_planet_center;
	float r = max(length(q), 1e-4);
	float sinElev = dot(q / r, normalize(u_sun_dir));
	float dip = sqrt(max(1.0 - (u_rground * u_rground) / (r * r), 0.0)) * u_twilight;
	float soft = max(u_shadow_softness * 0.25, 1e-3);
	return smoothstep(-soft, soft, sinElev + dip);
}

vec3 acesFilm(vec3 x) {
	float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
	return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// ===== 体积云辅助(与大气在同一 raymarch 内积分)=====
// Henyey-Greenstein 相位; 双叶(前向峰=银边 + 一点后向)近似米氏
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

// 云密度: 高度梯度(上下边缘渐隐, 陡段藏在地面下避免云底切线亮带) × 覆盖阈值化的 fbm。
// hi=true 视线采样(域扭曲 + 4 octave); false 光照采样(便宜: 无扭曲 + 3 octave)。
float cloudDensity(vec3 pos, bool hi) {
	float r = length(pos - u_planet_center);
	float thick = max(u_ctop - u_cbottom, 1e-4);
	float h = (r - u_cbottom) / thick;                  // 0=云底, 1=云顶
	if (h < -1.3 || h > 1.2) return 0.0;
	float heightGrad = smoothstep(-1.2, 0.6, h) * (1.0 - smoothstep(0.6, 1.2, h));
	vec3 sp = (pos - u_planet_center) * u_cfreq + u_cwind * (TIME * u_cwind_speed);
	float base;
	if (hi) {
		vec3 w = vec3(fbm(sp * 0.5 + 11.5, 2), fbm(sp * 0.5 + 47.2, 2), fbm(sp * 0.5 + 83.1, 2)) - 0.5;
		base = fbm(sp + u_cwarp * w, 4);
	} else {
		base = fbm(sp, 3);
	}
	float thr = 1.0 - u_coverage;
	return smoothstep(thr, thr + 0.4, base * heightGrad);
}

// 云向太阳的自阴影(Beer): 沿 sunDir 累积密度(便宜密度) → 透射率
float lightMarch(vec3 pos) {
	float st = (u_ctop - u_cbottom) / float(u_clight_steps);
	float sum = 0.0;
	vec3 q = pos;
	for (int i = 0; i < 12; i++) {
		if (i >= u_clight_steps) break;
		q += normalize(u_sun_dir) * st;
		sum += cloudDensity(q, false) * st;
	}
	return exp(-sum * u_cdensity * u_cabsorb);
}

// 昼夜: 采样点当地地平上太阳仰角(软过渡)
float dayFactor(vec3 pos) {
	vec3 up = normalize(pos - u_planet_center);
	return smoothstep(-0.12, 0.12, dot(up, normalize(u_sun_dir)));
}

// 地面点的云影: 从地面点沿太阳方向穿过云层累积密度 → 透射率
float cloudShadow(vec3 gp) {
	vec3 sd = normalize(u_sun_dir);
	vec2 o = raySphere(gp, sd, u_planet_center, u_ctop);
	vec2 inr = raySphere(gp, sd, u_planet_center, u_cbottom);
	float s0 = max(inr.y, 0.0);
	float s1 = o.y;
	if (s1 <= s0) return 1.0;
	int N = u_clight_steps;
	float st = (s1 - s0) / float(N);
	float sum = 0.0;
	vec3 q = gp + sd * (s0 + st * 0.5);
	for (int i = 0; i < 12; i++) {
		if (i >= N) break;
		sum += cloudDensity(q, false) * st;
		q += sd * st;
	}
	return exp(-sum * u_cdensity * u_cabsorb);
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 ro = INV_VIEW_MATRIX[3].xyz;              // 相机世界位
	vec3 rd = normalize(v_world_pos - ro);         // 视线方向(片元决定)

	// 场景深度 → 场景距离 + 命中点(reverse-Z: depth≈0 = 天空/远平面)
	float depth = texture(depth_texture, SCREEN_UV).r;
	float sceneDist = 1e20;
	vec3 hitPos = ro;
	bool hitGround = false;
	if (depth > 0.0001) {
		vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth * 2.0 - 1.0);
		vec4 vp = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		vp.xyz /= vp.w;
		vec3 wp = (INV_VIEW_MATRIX * vec4(vp.xyz, 1.0)).xyz;
		sceneDist = distance(wp, ro);
		hitPos = wp;
		hitGround = true;
	}

	vec3 sceneColor = texture(screen_texture, SCREEN_UV).rgb;

	vec2 atmo = raySphere(ro, rd, u_planet_center, u_ratmo);
	float tNear = max(atmo.x, 0.0);
	float tFar = atmo.y;
	bool valid = tFar > tNear;
	if (valid) {
		tFar = min(tFar, sceneDist);                    // 在真实地表面停
		vec2 gnd = raySphere(ro, rd, u_planet_center, u_rground);
		if (gnd.x > 0.0 && gnd.y > gnd.x) tFar = min(tFar, gnd.x);   // 解析地面球兜底
		valid = tFar > tNear;
	}

	vec3 color = sceneColor;
	if (valid) {
		bool clouds = u_clouds_on > 0.5;

		// 背景 = 场景色; 命中地表且云开 → 叠云影(仅白天侧)
		vec3 background = sceneColor;
		if (clouds && u_cshadow > 0.0 && hitGround && length(hitPos - u_planet_center) < u_ctop) {
			float day = dayFactor(hitPos);
			if (day > 0.01) {
				float sh = cloudShadow(hitPos);
				background *= mix(1.0, sh, u_cshadow * day);
			}
		}

		// 统一步长(非自适应): 云开时整段用足够细的【统一】步长, 任何半径上都没有采样跳变
		// → 不会有云底球面切线产生的亮带; 配合 cloudDensity 长尾渐隐, 云底被自然混合掉。
		float span = tFar - tNear;
		int Nmarch = clouds ? max(u_steps, u_cloud_steps * 2) : u_steps;
		float stepU = span / float(Nmarch);
		float jitter = mix(0.5, hash12(SCREEN_UV * vec2(1920.0, 1080.0) + fract(TIME)), u_dither);
		float t = tNear + stepU * jitter;

		// 相位(每像素常量)
		float mu = dot(rd, normalize(u_sun_dir));
		float phaseR = (3.0 / (16.0 * PI)) * (1.0 + mu * mu);
		float g2 = u_mie_g;
		float phaseM = (1.0 - g2) * (1.0 + mu * mu) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g2 * mu, 1e-4), 1.5));
		// 云相位: 0.4 基底保证背光侧也有照明, 再叠前向银边
		float cphase = clouds ? (0.4 + u_silver * cloudPhase(mu)) : 0.0;

		// 统一 front-to-back 合成: T=剩余透射, L=累计内散射(大气 + 云, 同一积分)。
		// 全程线性辐亮度, 末端不 tonemap → 交 WorldEnvironment 的 AgX 统一处理(与场景一致, 无色彩割裂)。
		vec3 T = vec3(1.0);
		vec3 L = vec3(0.0);
		for (int i = 0; i < 512; i++) {
			if (t >= tFar) break;
			// 每步微抖动打散同心环(低幅, 不破坏能量守恒)
			float jit = (hash12(SCREEN_UV * vec2(1920.0, 1080.0) + vec2(float(i) * 7.31, float(i) * 3.17)) - 0.5) * stepU * 0.25 * u_dither;
			vec3 p = ro + rd * (t + jit);
			float ds = min(stepU, tFar - t);                          // 统一步长, 不越过终点(地表)

			// —— 大气: 密度(R,M,O)×ds → 本步消光 sigA ——
			vec3 dens = densityAt(p) * ds;
			vec3 sigA = u_scatter_r * dens.x + u_ozone * dens.z + vec3(u_scatter_m * 1.1 * dens.y);

			// —— 云: 壳外 cloudDensity≈0 早退(便宜); 壳内才算自阴影 + 受光 ——
			float sigC = 0.0;
			vec3 srcC = vec3(0.0);
			if (clouds) {
				float dcl = cloudDensity(p, true);
				if (dcl > 0.0) {
					float sun = lightMarch(p);                       // 向太阳透射率(Beer 自阴影)
					float sunUp = dot(normalize(p - u_planet_center), normalize(u_sun_dir));
					float day = smoothstep(-0.12, 0.12, sunUp);      // 直射昼夜(窄)
					float amb = smoothstep(-0.4, 0.15, sunUp);       // 环境光昼夜(宽, 含暮光)
					float powder = mix(1.0, 1.0 - exp(-dcl * u_cdensity * 2.0), u_powder);
					vec3 lit = u_suncolor * (sun * day * cphase * powder) + u_ambient * amb;
					sigC = dcl * u_cdensity * ds;
					srcC = sigC * lit;
				}
			}

			// —— 大气内散射源: 太阳→p 透射 × 行星软遮挡 × 散射×相位×密度 ——
			vec3 srcA = vec3(0.0);
			float shadow = planetShadow(p);
			if (shadow > 0.0) {
				vec3 odSun = opticalDepthToSun(p);
				vec3 Tsun = exp(-(u_scatter_r * odSun.x + vec3(u_scatter_m * 1.1) * odSun.y + u_ozone * odSun.z)) * shadow;
				srcA = u_sun_intensity * Tsun * (u_scatter_r * phaseR * dens.x + vec3(u_scatter_m * phaseM) * dens.y);
			}

			// —— 合成本步: 大气与云共用同一消光/源, front-to-back(不早退, 让远侧云也积分出来)——
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

		color = background * T + L;
		color *= u_exposure;   // 线性曝光增益; 非线性 tonemap 交 AgX
	}

	// 大气外圈按 impact parameter(射线到行星中心垂距 b)平滑渐隐到天空:
	// b 从 rground→ratmo 时, 整个大气效果(T 衰减 + L 散射 + 云)过渡到原始场景色。
	// 临边(b≈rground)辉光保留, 外圈(b→ratmo)渐隐 → 消除亮环/硬边。
	vec3 oc = ro - u_planet_center;
	float b = length(cross(oc, rd));
	float atmoEdge = 1.0 - smoothstep(u_rground, u_ratmo, b);
	color = mix(sceneColor, color, atmoEdge);
	ALBEDO = color;
	ALPHA = 1.0;
}
