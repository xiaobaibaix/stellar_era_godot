// GPU/CPU 共享噪声自检用 canvas_item shader(Phase 1+ Step1)。
// 噪声实现必须与 scripts/terrain/noise_shared.gd 【逐位一致】(同 hash/grad/fade/worley)。
// 输出 primitive(uv*scale,0) 映射 [-1,1]→[0,1](clamp) 到 RGB, GDScript 读 R 通道比对。
// 容差 0.003(> 8 bit 量化上界 0.00196) → 通过即证明 GPU/CPU 一致。
shader_type canvas_item;
render_mode unshaded;

uniform float scale = 4.0;
uniform int primitive = 0;   // 0=noise3  1=fbm  2=ridged  3=worley_f2f1

// ---- 整数哈希(与 noise_shared.gd 逐位一致) ----
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

float fbm(vec3 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) { s += a * noise3(p); p *= 2.0; a *= 0.5; }
	return s;
}
float ridged(vec3 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		float n = 1.0 - abs(noise3(p));
		s += a * n * n;
		p *= 2.0;
		a *= 0.5;
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

float sstep(float a, float b, float x) {
	float t = clamp((x - a) / (b - a), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

// 完整高度场(与 terrain.gdshader::terrain_height / terrain.gd::height_at 同式; 默认 PlanetParams 值)。
// 用于自检: 若 GPU 此值与 CPU terrain.height_at 一致 → 算术正确, 平滑球问题在 spatial shader 别处。
float terrain_height_test(vec3 d) {
	vec3 wp = d * 1.0 + vec3(777.0, 1554.0, 2331.0);
	float q0 = noise3(wp);
	float q1 = noise3(wp + vec3(31.4, 12.7, 5.2));
	float q2 = noise3(wp + vec3(7.7, 41.3, 19.1));
	vec3 pw = d + vec3(q0, q1, q2) * 0.2;
	float cont = fbm(pw * 1.2 + vec3(1337.0, 2674.0, 4011.0));
	float land = sstep(-0.06, 0.10, cont);
	float mtn = clamp(ridged(pw * 3.0 + vec3(9001.0, 18002.0, 27003.0)), 0.0, 1.0);
	float f2f1 = worley_f2f1(pw * 1.6 + vec3(555.0, 1110.0, 1665.0));
	float belt = pow(1.0 - clamp(f2f1, 0.0, 1.0), 6.0);
	float mountains = (mtn + belt * 0.5) * land;
	return cont + mountains * 0.6;
}

void fragment() {
	vec3 sp = vec3(UV * scale, 0.0);
	float n = 0.0;
	if (primitive == 0) {
		n = noise3(sp);
	} else if (primitive == 1) {
		n = fbm(sp);
	} else if (primitive == 2) {
		n = ridged(sp);
	} else if (primitive == 3) {
		n = worley_f2f1(sp);
	} else {
		n = terrain_height_test(sp);
	}
	float m = clamp(n * 0.5 + 0.5, 0.0, 1.0);   // [-1,1]→[0,1]
	COLOR = vec4(vec3(m), 1.0);
}
