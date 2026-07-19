# 天体 SOI 捕获 / 移交 —— 分层引力归属设计

> 描述「天体在不同引力主之间动态换主」的完整规则：月球离开地球→太阳接管、行星系子天体在两行星间互换、双星系统里的 P-type 环双星轨道与跨星捕获。
>
> 本文档 = 物理判据 + 两条移交通道 + 每个场景的代码路径 + 守卫/迟滞机制 + 已知边界行为，供后续游戏机制规划与维护参照。行号对应 `celestial_system.gd`，截至 2026-07。

---

## 一、背景与目标

### 物理直觉（用户原始诉求）
1. **地月系 / 太阳系**：月球离开地球的引力作用区（SOI）→ 应被太阳接管，变成和地球平级；反之别的星进入地球 SOI → 应被地球捕获为子天体（绕转或再冲出）。
2. **两行星系靠近**：行星 A 的子天体飞进行星 B 的 SOI → 应被 B 捕获为子天体；大概率因速度脱离 → 回到 A，或被甩到恒星系层与两行星平级。
3. **双星 / 恒星系群**：每颗恒星瓜分约一半空间的 SOI；行星飞出某颗星的 SOI 但仍在双星联合引力内 → 应继续绕双星运动（P-type），**不丢失、不飞走**；只有获得超过双星逃逸速度才会真正离开。

### 目标
在同一套机制里统一处理上述三类，且**判定与视觉共用同一个物理量**（多体引力等势面 η），保证「看到的 SOI 边界」与「触发换主的边界」一致。

---

## 二、物理基础

### 分层 Kepler 近似
每个 `CelestialSystem` 持有独立 `NBodySystem sim`。**子层 sim 对兄弟系统引力盲**——CS1 的 sim 不知道 CS2 的存在，PlanetSystem1 的 sim 不知道 PlanetSystem2。跨层引力作用通过 **动态 reparent**（换主）体现，而非每帧全宇宙 N 体。

世界运动由基座位/速 `_bcx/_bvx` 沿父链传播（`_step_recursive`），每层局部质心归零（`sim.zero_momentum()`，`_init_physics:244`）。

### 归属判据：多体摄动比 η
对中心天体 `T = sub.dominant`，测试点 P（世界 double）：

```
g_T(P)       = G·M_T / |P−T|²                         # T 对 P 的主引力
tidal_S(P)   = a_S(P) − a_S(T)                         # 摄动源 S 在 T 共动系里的潮汐
             = G·M_S·[(S−P)/|S−P|³ − (S−T)/|S−T|³]
η_S(P)       = |tidal_S(P)| / g_T(P)
η(P)         = max_S η_S(P)                            # 取最严苛的摄动源
```

- **归属 T** ⇔ `η(P) < 1.0`；边界 = `η = 1.0` 的等值面。
- 二体（单 S）→ 经典 Roche lobe / Hill 面，朝 S 收尖，形状随 `q = M_S/M_T` 变。
- 多体 → 不同方向被不同 S 主导 → 扭曲面。
- 无摄动源（顶层单星）→ 退化球，半径 = Hill×阈值。

实现：`_max_perturbation_ratio`（`:760`）、`_inside_potential_surface`（`:821`）、摄动源收集 `_collect_perturbers`（`:803`）。

### dominant 与 fallback
`_collect`（`:179`）取 `is_dominant=true` 的 member 为 `dominant`；`_init_physics:192` 兜底——**没标 `is_dominant` 的子系统取 `members[0]`**。所以 `MoonSystem.dominant = 月球`（唯一成员）。这是月球「换主」走子系统通道（而非叶子通道）的前提。

### Hill 半径
`_init_physics:235`：`sub._hill_radius = sdist · (m_sub / (3·M_dominant))^(1/3)`；顶层群边界 `_compute_top_boundary`（`:246`）。Hill 是 η=1 的下界估计，退化球判定与等势面射线上界都用它。

---

## 三、两条移交通道

捕获/移交有**两条独立通道**，对象不同、函数对应：

| 通道 | 对象 | 判定函数 | 执行函数 |
|---|---|---|---|
| **叶子天体** | `Celestial`（Planet、月球本体等 member） | `_resolve_desired_owner`（`:561`） | `_reparent_celestial`（`:596`） |
| **子系统** | `CelestialSystem` 壳（PlanetSystem1、MoonSystem 等 child_system） | `_resolve_desired_owner_sub`（`:537`） | `_reparent_subsystem`（`:706`） |

> **关键**：月球的「换主」通过 **MoonSystem 壳整体上抛/被捕获** 实现，不是月球本体在移。因为月球是 MoonSystem 的 dominant，`_scan_system_soi:509` 会跳过 dominant（`if c == sys.dominant: continue`），叶子通道不处理它。

每帧入口：`_update_dynamic_soi`（`:495`）→ 遍历所有顶层 → `_scan_system_soi`（`:504`）对 member 和 child_system 分别判定，归属变化即 reparent，最后 `_after_reparent`（`:635`）刷新 Hill / SOI 视觉 / 轨道预测。

---

## 四、核心函数索引

| 函数 | 行 | 职责 |
|---|---|---|
| `_collect` | 179 | 直系子分类：member / child_system / light；选 dominant |
| `_init_physics` | 191 | dominant-centric 建 sim；child_system 加 proxy；`zero_momentum` |
| `_init_cluster_physics` | 251 | 顶层群（无 dominant）N 体；双星精确圆速度 |
| `_update_dynamic_soi` | 495 | 每帧扫描所有顶层，触发 reparent |
| `_scan_system_soi` | 504 | 对 member + child_system 判归属，递归用快照 |
| `_resolve_desired_owner` | 561 | 叶子天体归属（逃逸→上抛，否则下钻捕获） |
| `_resolve_desired_owner_sub` | 537 | 子系统归属（含双星互不吞守卫 :545） |
| `_capture_descend` | 576 | 从 start 向下找包含 P 的最深子系统 |
| `_escaped_from` | 840 | P 是否逃出 sys（η ≥ OUT） |
| `_reparent_celestial` | 596 | 叶子换主：世界位速→新 sim 局部坐标 |
| `_reparent_subsystem` | 706 | 子系统换主：proxy 摘/建，子树跟随 |
| `_inside_potential_surface` | 821 | η < thresh 判定（含退化球） |
| `_max_perturbation_ratio` | 760 | 多体 η 计算 |
| `_collect_perturbers` | 803 | 沿祖先链 + 兄弟 dominant 收集摄动源 |
| `_resolve_initial_ownership_all` | 646 | 初始化一次性上抛（编辑器层级≠运行时 SOI） |
| `_get_top_of` | 871 | 沿父链取顶层 |

---

## 五、场景代码路径

### 场景1：月球离开地球 SOI → 太阳接管 → 和地球平级
```
_resolve_desired_owner_sub(MoonSystem)           # :537
  cur = PlanetSystem1
  pb  = PlanetSystem1.child_proxy[MoonSystem]    # 月球质心 proxy
  P   = PlanetSystem1._bcx + pb.px               # 月球世界位
  _escaped_from(PlanetSystem1, P)                # :840
    T = Planet;  sources = _collect_perturbers(PlanetSystem1) = [Star, Star2, ...]
    η = tidal_Star(P)/g_Planet(P)  →  月球远离 Planet 时 η↑
    return η ≥ 1.1                               # 触发上抛
  _capture_descend(CS1, P, exclude=MoonSystem)   # :576  CS1 无更深包含者 → 归 CS1
_reparent_subsystem(MoonSystem, PlanetSystem1, CS1)   # :706  月球随壳进 CS1 sim，绕 Star
```
> 月球变成 CS1 直接引力成员，和 Planet 同层（都在 CS1 sim 绕 Star）。✓

反向（别的星进地球 SOI 被捕获）：`_capture_descend` 从 CS1 下钻命中 PlanetSystem1（P 落入其等势面）→ `_reparent_subsystem` 进去。冲出再走 `_escaped_from` 上抛。✓

### 场景2：两行星系靠近 → 子天体互换
与场景1同构。MoonSystem 飞出 PlanetSystem1、落进 PlanetSystem2 等势面：
```
_resolve_desired_owner_sub(MoonSystem)
  _escaped_from(PlanetSystem1) → true
  _capture_descend(CS1, P) → 命中 PlanetSystem2（η_Planet2 < IN）
_reparent_subsystem(MoonSystem, PlanetSystem1, PlanetSystem2)
```
脱离再逃回 CS1（和两行星平级）。✓

### 场景3：双星 —— P-type 环双星轨道 & 跨星捕获
PlanetSystem1 飞出 CS1（靠近双星 L1）：
```
_resolve_desired_owner_sub(PlanetSystem1)
  cur = CS1
  _escaped_from(CS1, P)                          # :840  群守卫已删除(:847 注释)
    T = Star;  sources = _collect_perturbers(CS1) = [Star2]
    η = tidal_Star2(P)/g_Star(P)  →  近 L1 时 η ≥ 1.1
  _capture_descend(group, P, exclude=PlanetSystem1)   # :576
    遍历 group.child_systems = [CS1, CS2]
    P 落进 CS2 泪滴 → _inside_potential_surface(CS2) true → 归 CS2   # 跨星捕获
    P 在公共区（不在任一单星 SOI）→ 归 group（顶层）              # P-type
```
- **归 CS2**：被另一颗星接管，在其 sim 里绕 Star2。✓
- **归 group**：PlanetSystem1 作为 proxy 进 **group 的 N 体 sim**，绕**双星质心** = **P-type 环双星轨道**。✓ 这就是用户要的「一直挂在天体系统里、不飞走」。

> **group 就是双星系统的顶层本身**。P-type 行星挂在 group 下不是「丢失」，而是在双星联合引力下继续运动。节点层级挂在顶层（而非 CS1/CS2 名下）是正确的——它已不绕任何单星。

**真逃逸**：行星获得超过双星逃逸速度 → 在 group 走双曲轨道 → 真离开。`_escaped_from(group)` 因 `parent==null` 返回 false（顶层不上抛，`:845`），行星留 group 但轨道双曲。物理正确，分层模型无法回收。

---

## 六、守卫与迟滞机制

### 1. 双星互不吞守卫（`_resolve_desired_owner_sub:545`）
```
if sub.dominant != null and cur.dominant == null:
    return cur   # 有 dominant 的恒星系在顶层群(无 dominant)里是平等成员, 互不捕获
```
保证 CS1/CS2 **作为恒星系**永远归属群。否则测「CS1 在 CS2 SOI 内」时 P 恰落 CS2.dominant(Star2) 上，`_max_perturbation_ratio` 因 `dp2≈0` 跳过该源 → η 被低估为 0 → 误判 CS1 在 CS2 内 → 把整个 CS1 吞进 CS2。守卫拦住。对三合星同样适用。

> 注意：此守卫**只拦恒星级子系统**（有 dominant 且父是群）。PlanetSystem1（有 dominant，但父 CS1 也有 dominant）**不受限**，正常可上抛/被捕获——这正是跨星捕获能工作的原因。

### 2. η 迟滞死区（防 reparent 震荡）
`_SOI_HYSTERESIS_IN = 0.9`（捕获下钻阈值）、`_SOI_HYSTERESIS_OUT = 1.1`（逃逸上抛阈值）。
- η ∈ [0.9, 1.1] 既不捕获也不逃逸 → 边界附近不反复翻转。
- 捕获侧 `_capture_descend:586` 用 IN；逃逸侧 `_escaped_from:867` 用 OUT。

### 3. NaN 防御（物理发散不断链）
`_escaped_from:853/861/865` 与 `_inside_potential_surface` 对 η / 位置 / hill 是 NaN 时取保守值（不逃逸、不下钻）。斩断「NaN→误判 reparent→速度换算出错→更多 NaN→翻转闪烁」恶性循环。

### 4. 初始化上抛守卫（`_collect_initial_moves:672`）
```
var par := sys.parent_system
if par.dominant != null:   # 父是群(无 dominant) → 不上抛群成员恒星系内部
    ...子系到 dominant 距离 > Hill 才收集上抛...
```
一次性初始化时，群成员恒星系（CS1）内部的行星系作为封闭单元跟随，不上抛到群层。否则群成员 Hill（基于到群质心）小于行星轨道 → 行星系被误判出 Hill 搬到群层。分层近似下群内恒星系不受伴星引力，行星系稳定绕本星，上抛反而错。

### 5. 群隔离守卫已删除（`_escaped_from:847-851` 注释）
旧版 `_escaped_from` 对「父是群（无 dominant）」硬 `return false`，阻断了所有群成员恒星系内部行星的逃逸检测 → 行星飞进另一恒星 SOI 却不被接管（用户报告的 bug）。已删除。安全性由守卫 1（双星互不吞，子系统级不走 `_escaped_from`）和守卫 4（初始化）覆盖。

---

## 七、已知边界行为（非 bug，规划时需知晓）

1. **子系统壳层级**：月球换主后节点树仍包在 `CS1/MoonSystem/月球` 壳里，不是裸 `CS1/月球`。物理/视觉上和地球平级，只是多一层壳。若要严格平级节点需专门做「壳塌缩」，目前无必要。
2. **P-type 挂顶层**：环双星整体的行星挂 `group`（双星顶层），不挂 CS1/CS2 名下。这是对的——它已不绕单星。若 UI 上希望显示在「双星联合」虚拟节点下，是纯节点组织偏好，物理已正确。
3. **真逃逸不可回收**：超过系统逃逸速度的天体走双曲轨道飞出，分层模型无法重新捕获（顶层不上抛）。物理正确。
4. **数值边界 `r2<1e-6`**：`_max_perturbation_ratio:768/780/788` 当 P 恰落在 T 或某 S 上时跳过，η 取 0 或跳过该源。测点 = 自身位置时返回 0（不误判逃逸）。

---

## 八、验证记录

### 修复1：`zero_momentum` 漏子层（行星被甩飞）
**现象**：CS1 的行星/卫星运行时被越甩越远，但节点仍在 CS1 下。
**根因**：旧版 `_init_physics:244` 只顶层调 `sim.zero_momentum()`；子层 sim 残留 `add_orbiting` 切向速度的质心动量 → dominant（中心天体）被线性反推 → `sim_speed` 高时每帧漂移 ×sim_speed 放大 → 长期整个子层飞散。
**修复**：`zero_momentum()` 对**所有层**调用（`:244`）。验证：Star 振幅 ±5（无漂移），P2 能量 ±1%（原 ±50%）。

### 修复2：跨星捕获失效（群隔离守卫过严）
**现象**：双星靠近时，CS1 的行星飞进 CS2 的 SOI 却不被接管。
**根因**：`_escaped_from` 旧版「父是群→硬 return false」阻断群成员恒星系的逃逸检测。
**修复**：删除硬守卫（`:847-851`）。验证（godot_exec 单点测试）：正常行星 η=0.0064（不逃逸，留 CS1）；近 CS2 的点 η=1537（逃逸），`_capture_descend` 归 CS2。

### 积分器稳定性
velocity-Verlet（辛积分器），能量有界（影子哈密顿量守恒），**不**像 Euler 那样累积发散。10000 步月球能量漂移 ±0.06%（~233 圈）。`sim_speed` 只影响单步精度（`dt_sub/T` 判据），不累积。真正风险面：快周期 / 弱束缚 / 近距交会天体。

---

## 九、后续可选改进

- **自适应 substeps**：按最快轨道周期动态调 `substeps`，让 `dt_sub/T` 全局达标（当前固定 2）。已在前期讨论中提出，待定。
- **P-type 视觉分组**：若 UI 需求，加「双星联合系统」虚拟节点收纳 P-type 行星，纯展示层。
- **壳塌缩**：月球换主到恒星系层时，可选把 MoonSystem 壳拆掉、月球直接挂恒星系（严格平级节点）。
- **多体 η 视觉**：`_make_potential_surface_mesh`（等势面线框）已是径向采样 η=1，多体场景天然扭曲；可调 `soi_rebuild_interval` / 采样密度平衡性能。

---

## 附：判定流程速查

```
叶子天体 c:                       子系统 sub:
_resolve_desired_owner(c)         _resolve_desired_owner_sub(sub)
  cur = c.owner_system              cur = sub.parent_system
  P = c._wx/_wy/_wz                 P = cur._bcx + proxy.px
  if cur 有父且有 dominant:         if sub 有dom 且 cur 群(无dom): return cur  # 双星互不吞
    if _escaped_from(cur, P):       if cur 有父且有 dominant:
      return _capture_descend(父,P)   if _escaped_from(cur, P):
  return _capture_descend(cur, P)       return _capture_descend(父,P,sub)
                                    return _capture_descend(cur,P,sub)

_escaped_from(sys,P): η(P) ≥ 1.1  （NaN/顶层→false）
_capture_descend(start,P): 从 start 向下找 η<0.9 的最深子系统
```
