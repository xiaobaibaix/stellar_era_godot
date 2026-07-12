shader_type spatial;
// 大气壳(移植 effects.js createAtmospherePass 的 main + 数学)。球壳 spatial shader:
// 读 screen_texture(场景色) + depth_texture(场景深度), 沿视线 raymarch Rayleigh/Mie/ozone,
// 用场景深度 + 解析地面球终止积分, front-to-back 复合 color = sceneColor*T + L;
// 输出线性辐亮度, 色调映射交给 WorldEnvironment 的 AgX 对整帧统一处理(不在片元里做 ACES)。
//
// 深度约定: Godot 4 用 reverse-Z(depth 1=near, 0=far=天空)。几何 depth>0, 天空 depth≈0。
// 反投影: ndc.z = depth*2-1 → INV_PROJECTION → INV_VIEW。地面球 uRground 兜底(深度读不准也安全)。
//
// render_mode 说明:
// - cull_front: 渲染球壳背面。从外面看仍覆盖整个行星圆盘; 相机进到壳内(靠近/角色模式)时,
//   背面正好包住相机 → 大气不会消失(旧的 cull_back 一进壳就整片剔掉 = 大气突然没了)。
// - depth_test_disabled: 不做深度测试。否则 cull_front 的远侧壳面会被前方地形的深度剔掉,
//   导致行星圆盘上没有大气(只剩外圈)。关掉深度测试 → 壳面片元恒运行, 覆盖整盘; 积分终止靠
//   场景深度纹理 + 解析地面球, 与 mesh 深度无关。
// - unshaded: 大气辐亮度已在片元里自行积分(含太阳散射/行星阴影), 不能再被引擎方向光二次照亮。
render_mode cull_front, blend_mix, depth_draw_never, depth_test_disabled, unshaded;

uniform sampler2D screen_texture : hint_screen_texture;
uniform sampler2D depth_texture : hint_depth_texture;

uniform vec3 u_sun_dir = vec3(0.739, 0.443, 0.515);
uniform vec3 u_planet_center = vec3(0.0);
uniform float u_rground = 100.0;        // 海平面/地面球半径
uniform float u_ratmo = 108.0;          // 大气顶半径
uniform float u_density_falloff = 6.0;  // Rayleigh 指数衰减
uniform float u_mie_falloff = 16.0;     // Mie 衰减
uniform vec3 u_scatter_r = vec3(0.00853, 0.02596, 0.05464);  // RAY_RATIO(0.1066,0.3245,0.6830)*atmoRayleigh(0.08)
uniform float u_scatter_m = 0.03;       // atmoMie
uniform float u_mie_g = 0.76;           // atmoMieG
uniform vec3 u_ozone = vec3(0.007, 0.02, 0.0009);            // OZONE_RATIO(0.35,1.0,0.045)*atmoOzone(0.02)
uniform float u_sun_intensity = 22.0;   // atmoSunIntensity
uniform float u_exposure = 1.0;         // atmoExposure
uniform int u_steps = 24;               // atmoSteps(视线积分)
uniform int u_light_steps = 8;          // atmoLightSteps(向阳光学深度)
uniform float u_shadow_softness = 0.6;  // atmoShadowSoftness(晨昏带软度)
uniform float u_twilight = 0.3;         // atmoTwilight(几何下陷, 暮光)
uniform float u_dither = 0.5;           // atmoDither(去 banding 抖动)

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

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 ro = INV_VIEW_MATRIX[3].xyz;              // 相机世界位
	vec3 rd = normalize(v_world_pos - ro);         // 视线方向(片元决定)

	// 场景深度 → 场景距离(reverse-Z: depth≈0 = 天空/远平面)
	float depth = texture(depth_texture, SCREEN_UV).r;
	float sceneDist = 1e20;
	if (depth > 0.0001) {
		vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth * 2.0 - 1.0);
		vec4 vp = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		vp.xyz /= vp.w;
		vec3 wp = (INV_VIEW_MATRIX * vec4(vp.xyz, 1.0)).xyz;
		sceneDist = distance(wp, ro);
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
		// 相位(每像素算一次)
		float mu = dot(rd, normalize(u_sun_dir));
		float phaseR = (3.0 / (16.0 * PI)) * (1.0 + mu * mu);
		float g2 = u_mie_g;
		float phaseM = (1.0 - g2) * (1.0 + mu * mu) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g2 * mu, 1e-4), 1.5));

		int N = u_steps;
		float stepU = (tFar - tNear) / float(N);
		float jit = (hash12(SCREEN_UV * vec2(1920.0, 1080.0) + fract(TIME)) - 0.5) * u_dither * stepU;

		// front-to-back 复合(无早退)
		vec3 T = vec3(1.0);
		vec3 L = vec3(0.0);
		for (int i = 0; i < 256; i++) {
			if (i >= N) break;
			float tcur = tNear + (float(i) + 0.5) * stepU + jit;
			vec3 p = ro + rd * tcur;
			vec3 dens = densityAt(p) * stepU;
			vec3 sigA = u_scatter_r * dens.x + u_ozone * dens.z + vec3(u_scatter_m * 1.1 * dens.y);
			vec3 srcA = vec3(0.0);
			float shadow = planetShadow(p);
			if (shadow > 0.0) {
				vec3 odSun = opticalDepthToSun(p);
				vec3 Tsun = exp(-(u_scatter_r * odSun.x + vec3(u_scatter_m * 1.1) * odSun.y + u_ozone * odSun.z)) * shadow;
				srcA = u_sun_intensity * Tsun * (u_scatter_r * phaseR * dens.x + vec3(u_scatter_m * phaseM) * dens.y);
			}
			if (dot(sigA, sigA) > 1e-12) {
				vec3 dT = exp(-sigA);
				vec3 integ = srcA * (1.0 - dT) / max(sigA, vec3(1e-7));
				L += T * integ;
				T *= dT;
			}
		}
		// 输出线性辐亮度: 片元里不做色调映射, 交给 WorldEnvironment 的 AgX 对整帧统一 tonemap。
		// AgX 在高亮时能更好保持色相(蓝紫不会被推成灰白), 且大气与其余场景走同一条曲线 → 无色彩割裂。
		// u_exposure 保留为线性曝光增益(默认 1.0); 非线性映射由管线负责。
		color = sceneColor * T + L;
		color *= u_exposure;
	}
	// 大气外圈按 impact parameter(射线到行星中心垂距 b)平滑渐隐到天空:
	// b 从 rground→ratmo 时, 整个大气效果(T 衰减 + L 散射)过渡到原始场景色。
	// 临边(b≈rground)辉光保留, 外圈(b→ratmo)渐隐 → 消除亮环/硬边。
	vec3 oc = ro - u_planet_center;
	float b = length(cross(oc, rd));
	float atmoEdge = 1.0 - smoothstep(u_rground, u_ratmo, b);
	color = mix(sceneColor, color, atmoEdge);
	ALBEDO = color;
	ALPHA = 1.0;
}
