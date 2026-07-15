# 大气 / 体积云 / 体积光 —— 全屏后处理重构方案

> 把行星大气从「挂在 3D 世界里的 spatial 球壳 shader」迁移到「CompositorEffect + Compute 的多 pass 全屏后处理」，1:1 复刻 web 参照实现 `F:\workspace\godot\github\sidereal_era_web\src\effects.js` 的管线结构。
>
> 本文档 = 设计思路 + 关键技术决策 + 已踩坑记录 + 里程碑进度，供后续开发与维护参照。

---

## 一、背景与动机

### 现状（重构前）
Godot 大气是一个挂在 3D 世界里的 **spatial 球壳 shader**（`shaders/atmosphere.gdshader`），靠 `blend_mix` 一次性合成。参照的 web 实现是一套**多 pass 全屏后处理管线**（`createAtmospherePass` / `createCompositePass` / `createGodrayPass` / `createTransmittanceLUT`）。差距是**结构性的，调参补不了**。

### 结构性差距
1. **体积光（godrays）根本没实现** —— `planet_params.gd` 有 `showGodrays`/`godray*` 参数，但 `planet.gd._build_effects` 没建任何 godray pass，参数空转。
2. **透射率 LUT 缺失** —— web 预烘 256×64 LUT 把「每采样点的太阳方向内循环」换成 1 次查表；Godot 每采样点真跑 `opticalDepthToSun`，是 `steps × lightSteps` 开销，被迫降步数 → banding。
3. **合成有损** —— web 在全分辨率做精确 `scene·T + L`；Godot 把透射率 T 折成标量再用 alpha blend，还叠了非物理的 `atmoEdge`。（web 的 LT 缓冲也把 T 折成 `.gray`，所以逐通道 T 只在 march 内部算 L 时有意义；真正要修的是「去掉 atmoEdge + alpha blend，改成精确 scene·T + L」。）
4. **云频率没按半径归一** —— web `cloudFreq/radius*100`；Godot 传原值。场景 `radius=1000`、web 基准 100 → 云特征尺寸大 10×，形态不对。

### 选定方案
用 Godot 4 的 **`CompositorEffect`**（渲染管线级、compute shader）1:1 复刻 web 多 pass：半分辨率大气积分(输出 L,T) → 全分辨率合成 → 屏幕空间 godrays，全帧统一一次 tonemap。

**可行性已确认**：Forward+ + 无 MSAA → `render_data.get_render_scene_buffers().get_color_layer(view)` / `get_depth_layer(view)` 直接拿到场景 color+depth（深度能读，这是之前球壳方案存在的唯一理由，现在 Compositor 也能拿）。官方 Compositor 教程的 compute post-process 模板 + `@tool` 编辑器可见 → 路线成立。

---

## 二、架构设计

### 触发点
`EFFECT_CALLBACK_TYPE_POST_TRANSPARENT`（透明 pass 之后、内置 tonemap/glow 之前）。此时 color buffer 含地形+海洋（都是已渲内容），是线性 HDR。

> **输出线性 HDR 写回 color buffer，让 WorldEnvironment（tonemap_mode=4 = AgX + glow）做全帧唯一一次色调映射** = 等价 web「末端一次 ACES」。海洋是透明壳，已在 buffer 里 → 大气正确合成在海洋之上。

### Pass 规划（最终态）
| pass | 分辨率 | 输入 | 输出 | 移植自 |
|---|---|---|---|---|
| **LUT**（脏时才跑） | 256×64 | 无 | 持久 rgba16f `_lut_tex`（r,g,b=瑞利/米氏/臭氧光学深度） | web `createTransmittanceLUT` |
| **大气** | 半分辨率 | color(全)+depth(全)+LUT | 半分辨率 rgba16f `_lt_tex`（RGB=L, A=T.gray） | web atmo pass，逻辑=现 `atmosphere.gdshader` 的 raymarch+云 |
| **合成** | 全分辨率 | color(全)+`_lt_tex`(半,双线性) | 写回 color：`scene·T + L`（精确，无 atmoEdge） | web `createCompositePass` |
| **godray** | 全分辨率 | color(全,已合成) | 写回 color：径向光束叠加 | web `createGodrayPass` |

> **M2 当前**：大气+合成暂未拆分，先做**单个融合 compute**（`atmosphere_compute.glsl`）全分辨率跑 atmo+云+精确合成，输出线性 HDR。验证正确后再 M6 拆半分辨率。

### 相机矩阵与参数传递（跨线程，关键）

**相机矩阵**从 `render_data.get_render_scene_data()`（rsd）在渲染线程取：

- `rsd.get_cam_projection()` → 投影矩阵 P
- `rsd.get_cam_transform()` → **相机世界变换 C**（camera→world；origin 即相机世界位）。⚠️ 这**不是**视图矩阵 V，原样用、**不要再取逆**——取逆会把相机镜像到行星背面，大气/散射错位成横切盘面的亮带。

**关键 API 语义（踩坑得来）**：
- `get_view_projection(view)` 在单视图下返回的是**投影矩阵**，**不是** view-projection！所以不能直接 `.inverse()` 当 invViewProj。
- 正确做法是**两步重建**：
  1. `inv_proj = get_cam_projection().inverse()`（NDC → 视图空间）
  2. `cam_xform = get_cam_transform()`（直接就是 camera→world，**不取逆**）
  3. shader 里 `cam_xform * (inv_proj * ndc)` = `C · P⁻¹ · ndc` = 等价 invViewProj
- 相机世界位置 `ro = cam_xform.origin`。
- 仅 godray 的**反向投影**（world→clip）才需要视图矩阵：`view = cam_xform.affine_inverse()`、`world_to_clip = P * Projection(view)`（见 `_dispatch_godray`）。

**参数**（sun_dir / planet_center / 半径 / 散射 / 云…）：`planet.gd`（主线程）每帧打包成 UBO 字节快照，经 **Mutex** 写入 CompositorEffect 的 `_frame`；`_render_callback`（渲染线程）在 Mutex 下读快照上传 UBO。

### Uniform set 布局
- set 0 = `FrameData` UBO（inv_proj + cam_xform + cam_pos + sun_dir + planet_center + 全部标量，std140 16 字节对齐）
- set 1 = color image（读+写）
- set 2 = depth texture + sampler（NEAREST；非 shadow compare）
- set 3 = LUT texture + sampler（仅大气 pass，M3 起）
- set 4 = `_lt_tex`（仅合成 pass，M6 起）
- push constant：分辨率等小数据（≤128B）

### 深度 / NDC 约定（踩坑得来）
Godot 4 用 **reverse-Z + NDC z∈[0,1]**（near=1, far=0）。反投影时：
- **far plane**：`inv_proj * vec4(ndc.xy, 0.0, 1.0)`（z=0 是远平面；曾误用 `-1.0` 在 [0,1] 之外，inv_proj 外推）
- **depth 命中点**：`inv_proj * vec4(ndc.xy, depth, 1.0)`（depth 直接就是 NDC z；曾误用 `depth*2-1` 当 [-1,1]）
- 这两处错会让视线方向 `rd` 有系统偏差 → 相机静止时几乎看不出（"方向对"），相机一动就暴露成大气相对球体的滑动偏移。

---

## 三、当前实现（M2）

### 文件
- `scripts/render/atmosphere_compositor.gd` — `@tool extends CompositorEffect`，`class_name AtmosphereCompositor`。
- `shaders/compute/atmosphere_compute.glsl` — 融合 compute（atmo + 云 + 精确合成）。
- `scripts/planet/planet.gd` — 删了 spatial 大气壳，加 `_build_compositor()` + 每帧 `_push_compositor_frame()`。

### `atmosphere_compositor.gd` 结构
- `_init`：设 `effect_callback_type = POST_TRANSPARENT`，`enabled = true`，取 RD。
- `_notification(PREDELETE)`：释放 shader / sampler RID。
- `set_frame_data(dict)`：Mutex 保护的主线程入口（planet.gd 每帧调）。
- `mark_shader_dirty()`：标记需重编（暂未用，靠重启重载）。
- `_ensure_shader()`：`load(_SHADER_PATH) as RDShaderFile` → `get_spirv()` → `shader_create_from_spirv` → `compute_pipeline_create`。⚠️ `.glsl` 须带 `#[compute]` 头才能导入。
- `_ensure_depth_sampler()`：`RDSamplerState`（NEAREST/NEAREST）→ `rd.sampler_create`。
- `_build_frame_ubo(f, cam_pos, inv_proj, cam_xform)`：std140 打包（见下）。
- `_render_callback`：取 color/depth layer → 两步相机矩阵 → 建 UBO → bind set 0/1/2 → dispatch `(size-1)/8+1` → 释放 UBO RID。

### UBO 布局（FrameData，std140，须与 glsl 完全一致）
```c
mat4 inv_proj;          // 投影逆(NDC → 视图空间)
mat4 cam_xform;         // 相机世界变换(视图 → 世界)
vec4 cam_pos_time;      // xyz=相机世界位, w=时间(云飘动)
vec4 sun_dir;           // xyz=太阳方向(归一化)
vec4 planet_center;     // xyz=行星中心(世界)
vec4 radii;             // rground, ratmo, cbottom, ctop
vec4 scatter_r_m;       // rgb=瑞利散射系数, a=米氏
vec4 ozone_dither;      // rgb=臭氧吸收, a=去 banding 抖动强度
vec4 mie_params;        // mieG, densityFalloff, mieFalloff, shadowSoftness
vec4 sun_exp_twilight;  // sunIntensity, exposure, twilight, steps
vec4 counts;            // cloudSteps, lightSteps, cloudLightSteps, clouds_on
vec4 cloud_a;           // coverage, cdensity, cfreq(已按半径归一), cwarp
vec4 cloud_b;           // cwindspeed, absorb, silver, powder
vec4 cloud_c;           // cshadow, 0, 0, 0
```

打包要点：GDScript `Basis.x/.y/.z` 是列向量，GLSL `mat4` 列主序 → 按 `[col0.xyzw][col1...][col2...][origin,1]` 顺序 append 即对齐。inv_proj 同理按 `Projection.x/.y/.z/.w` 四列。

### `planet.gd` 改动
- 删 `_atmo_mesh/_atmo_mat/_atmo_shader` 及 `_build_effects`/`_resize_effects`/`_apply_visual_changes`/`_on_param_changed`/`rebuild`/`_update_sun`/`_process` 里所有大气球壳引用。
- 加 `_atmo_compositor: AtmosphereCompositor` + `_atmo_comp_res: Compositor`。
- `_build_compositor()`：建 CompositorEffect 挂 **`WorldEnvironment.compositor`**（⚠️ compositor 在 WorldEnvironment **节点**上，不是 Environment 资源）。场景无 WorldEnvironment（如单独编辑 planet.tscn）→ 跳过。
- `_push_compositor_frame()`（每帧 `_process`）：打包全部参数；`cfreq = cloudFreq/radius*100`（对齐 web）；`enabled = params.showAtmosphere`。

---

## 四、里程碑与进度

| 里程碑 | 状态 | 说明 |
|---|---|---|
| **M1** 管线骨架 + 编辑器证明 | ✅ 完成 | trivial 染色 pass 挂进 main.tscn，编辑器视口+运行时都看到效果 → 证明 Compositor+compute+@tool+Forward+ 全链路通、color/depth 拿得到。 |
| **M2** 移植大气（全分辨率融合 compute + 精确合成），删 spatial 球壳 | 🔧 进行中 | 大气/合成 compute 上线，输出线性 HDR，删 spatial 球壳。已修：相机矩阵两步重建（`cam_xform = get_cam_transform()` 原样、**不取逆**）、reverse-Z NDC z（far=0 / depth 直接）。**待用户 F5 确认运动偏移修复。** |
| **M3** 透射率 LUT | ✅ 完成 | `transmittance_lut_compute.glsl` 烘 256(mu)×64(r) LUT(rgb=光学深度)；大气 pass `lut_on` 分支查表替代向太阳 march（保留实时 march 回退）。参数(rground/ratmo/densityFalloff/mieFalloff)变则重烘，烘后**下一帧起**查表（避同帧 storage→sampler 竞态）。**待用户 F5 验外观不变+更快。** |
| **M4** 云尺度按半径归一 | ✅ 完成 | 已折进 M2 的 `_push_compositor_frame`：`cfreq = cloudFreq/radius*100`。 |
| **M5** 体积光 godray | ✅ 完成 | `godray_copy.glsl`(color→lit 快照) + `godray_compute.glsl`(lit→color 径向累积) 两 pass 已接 `_render_callback`；太阳投屏幕 UV + `dot(camFwd,sunDir)` smoothstep 可见度；lit 快照解决单缓冲读写竞态。**待用户 F5 验观感/参数。** |
| **M6** 清理 + 可选半分辨率 | ✅ 清理完成 | 已删 `shaders/atmosphere.gdshader`(spatial 版)+ `.uid`（M2 已清 planet.gd 球壳死代码，grep 复查无残留）。半分辨率拆分（`_lt_tex` + 全分辨率 composite）为**可选**性能优化；当前全分辨率融合 compute 工作良好，**暂缓**，需要时再做。 |
| **M7**（可选）参数对齐 web | ✅ 已对齐(试看) | main.tscn 已按 web `createAtmospherePass` 默认对齐：atmoMieG=0.76、atmoDensityFalloff=6、atmoMieFalloff=16、atmoSunIntensity=22、atmoShadowSoftness=0.6、atmoTwilight=0.3、atmoScale=1.2、cloud 全套 web 值（Density 1.2 / Freq 0.06 / Absorb 1 / Silver 1 / Powder 0.6 / Coverage 0.5 / Bottom 1.01 / Top 1.06 / Warp 0.5 / Wind 0.6）。保留 radius=500、atmoSteps/LightSteps=64/32（质量，LUT 后低成本）。**注意 `showClouds`/`showGodrays` 仍=false** → 翻开才看得到云/光束。不喜欢 `git checkout scenes/main.tscn` 还原。 |

### main.tscn 当前参数 vs planet_params 默认
| 参数 | main.tscn | params 默认 | 备注 |
|---|---|---|---|
| atmoRayleigh | 0.01 | 0.08 | 远低于默认/典型 |
| atmoMie | 0.01 | 0.008 | |
| atmoMieG | 0.0 | 0.5 | 0 = 无前向银边 |
| atmoDensityFalloff | 16.0 | 6.0 | 大 → 贴地衰减快 |
| atmoMieFalloff | 10.65 | 16.0 | |
| atmoExposure | 0.55 | 1.0 | 偏暗 |
| cloudDensity | 6.6 | 1.2 | 远高于默认 |
| cloudFreq | 0.025 | 0.06 | |
| cloudAbsorb | 20.0 | 1.0 | |
| cloudSilver | 3.35 | 1.0 | |

---

## 五、已踩坑清单（关键经验）

| 现象 | 根因 | 解法 |
|---|---|---|
| `Invalid assignment of property 'compositor' ... on base 'Environment'` | compositor 在 **WorldEnvironment 节点**上，不在 Environment 资源 | `we.compositor = res`（不是 `we.environment.compositor`） |
| `.glsl` 导入报「Text does not belong to a valid section: #version 450」+ 完全无大气 | `.glsl` 须带 `#[compute]` 头才被导入为 RDShaderFile | 文件首行加 `#[compute]`；改用 `load as RDShaderFile` + `get_spirv` + `shader_create_from_spirv` |
| `SamplerStateDs.new()` doesn't exist | 类名错 | `RDSamplerState.new()` + `rd.sampler_create(st)` |
| INTEGER_DIVISION 警告 `(size.x-1)/8+1` | GDScript 整除告警 | `@warning_ignore("integer_division")` |
| 全屏蓝/白、随相机变化、吹白 | `get_view_projection(view)` 单视图返回**投影**而非 vp，`.inverse()` 给的是 inv_proj → rd 垃圾 | 拆两步：`inv_proj` + `cam_xform` |
| 误以为 `get_cam_transform()` 返回视图矩阵 V 而加了 `.affine_inverse()` | 实际它**直接返回相机世界变换 C**（camera→world）；取逆会把相机镜像到行星背面 → 大气/散射错位成横切盘面的亮带 | `cam_xform = get_cam_transform()` 原样用、不取逆；`ro = cam_xform.origin` |
| 方向对但运动有偏移（大气不跟球中心） | reverse-Z NDC z∈[0,1]：far plane 用了 `z=-1`（外推）、depth 用了 `*2-1`（当 [-1,1]）→ rd 系统偏差，相机转动时视差偏移 | far 用 `z=0`，depth 直接当 NDC z |

---

## 六、风险
- compute 读深度的格式/sampler 细节（reverse-Z、sampler 创建）——M1 验证 color 通路、M2 验 depth。
- 跨线程参数快照需 Mutex（`_render_callback` 在渲染线程）。
- 半分辨率中间纹理（`_lt_tex`/`_lut_tex`）按 render 尺寸重建，避免泄漏/尺寸错。
- UBO std140 对齐写错 → 数据错乱但**不报错**，需仔细打包。
- POST_TRANSPARENT 时旧大气球壳若未删会进 buffer 被二次合成 → M2 必须同步删球壳。
- 单缓冲 godray 读写 hazard → 先读副本再写。
- 编辑器里 WorldEnvironment 的 Compositor 是否如期触发 → M1 已验证（@tool 且编辑器可见，OK）。

---

## 七、验证方式
每里程碑用 godot-mcp：`godot_editor_edit run(frozen=true)` → `godot_runtime_state digest` / `screenshot_game`，并 `godot_editor_read get_log_messages(severity=error)` 查 shader 编译错误。编辑器视口用 `screenshot_editor`。

> 用户偏好「写好我自己跑」——M1 之后各步把改动交给用户 F5 验证；需要用 MCP 复现时再说。

---

## 八、改动文件总览

**新增**
- `scripts/render/atmosphere_compositor.gd` ✅
- `shaders/compute/atmosphere_compute.glsl` ✅
- `shaders/compute/transmittance_lut_compute.glsl` ✅（M3）
- `shaders/compute/godray_copy.glsl` ✅（M5）
- `shaders/compute/godray_compute.glsl` ✅（M5）
- `shaders/compute/composite_compute.glsl` ⏳（M6 拆分时）

**修改**
- `scripts/planet/planet.gd` ✅（删球壳 + 加 compositor 驱动 + 每帧推帧数据）
- `scenes/main.tscn`（compositor 通过代码挂 WorldEnvironment，未改 tscn）

**删除（M6）**
- ~~`shaders/atmosphere.gdshader`~~（spatial 版，已删 + `.uid`）

---

## 九、原始计划
完整计划存于 `C:\Users\23080\.claude\plans\elegant-humming-wozniak.md`（含最初的需求拆解与决策过程）。本文档是其在项目内的落地版本，会随实现持续更新。
