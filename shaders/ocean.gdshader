shader_type spatial;
// 海洋(移植 effects.js createOcean)。海平面球: 菲涅尔 + Lambert + Blinn-Phong(仅向阳侧)。
// 不透明(写颜色+深度): 必须进 opaque 缓冲 → 大气壳的 screen_texture/depth_texture 才能读到海洋,
// 云才能正确合成在海洋之上(透明海洋不在 screen_texture 里, 会被大气壳的 ALPHA=1.0 替换或盖在云上)。
render_mode cull_back;

uniform vec3 u_sun_dir = vec3(0.739, 0.443, 0.515);   // normalize(1, 0.6, 0.8)
uniform vec3 u_deep = vec3(0.039, 0.118, 0.247);      // 0x0a1e3f
uniform vec3 u_shallow = vec3(0.180, 0.471, 0.659);   // 0x2e78a8
uniform float u_ambient = 0.2;                        // 夜侧基础亮度(0=全黑)

varying vec3 v_world_normal;
varying vec3 v_world_pos;

void vertex() {
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 cam_pos = INV_VIEW_MATRIX[3].xyz;             // 相机世界位
	vec3 N = normalize(v_world_normal);
	vec3 V = normalize(cam_pos - v_world_pos);          // 片元→相机
	vec3 L = normalize(u_sun_dir);
	float fres = pow(1.0 - max(dot(N, V), 0.0), 3.0);
	float diff = max(dot(N, L), 0.0);
	vec3 H = normalize(L + V);
	float spec = pow(max(dot(N, H), 0.0), 120.0) * step(0.0001, diff);  // 仅向阳侧高光
	vec3 col = mix(u_deep, u_shallow, fres);
	col = col * (u_ambient + (1.0 - u_ambient) * diff) + vec3(1.0, 0.96, 0.85) * spec * 0.9;
	ALBEDO = col;
}
