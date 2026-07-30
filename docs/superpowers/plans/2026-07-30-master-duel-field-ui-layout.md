# 大师决斗式场地与 UI 布局实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将纵向表格式决斗界面重构为中央连续棋盘、近端悬浮手牌、远端压缩场地和独立左右 HUD。

**Architecture:** 保留 `DuelBoard`、`ZoneView`、`HandView` 的公开信号与快照接口，只在 `.tscn` 中重组稳定节点层级。四排卡位继续由 `HBoxContainer` 管理，棋盘、手牌、HUD 和浮层分别使用独立锚点层，GDScript 仅按视口比例应用紧凑模式。

**Tech Stack:** Godot 4.6、GDScript、`.tscn` 场景、`.tres` Theme、GDExtension、Godot MCP。

## Global Constraints

- 不修改 C++/GDExtension 快照、合法候选、响应编码和隐私门禁。
- 不复制《大师决斗》的贴图、字体、音效、角色或场地资产。
- 不创建尚无 C++ 语义映射的额外怪兽区、场地区、卡组或墓地伪交互。
- 1920×1080、3840×2160、1920×1200 共用同一场景结构与布局逻辑。
- 新增或修改的项目代码使用充分、准确的中文注释；用户可见文本使用简体中文。

---

### Task 1: 建立分层场景契约

**Files:**
- Modify: `tests/ui/test_native_scene_contract.gd`
- Modify: `src/duel/duel_board.tscn`

**Interfaces:**
- Consumes: 现有唯一节点名 `PlayerHand`、`OpponentHand`、四个 Zone Row、`TurnLabel`、`PhaseButton` 和所有 Overlay。
- Produces: 稳定层节点 `%FieldStage`、`%HandLayer`、`%HudLayer`、`%OverlayLayer`，现有业务节点名保持不变。

- [ ] **Step 1: 写入失败的场景层级测试**

在 `test_native_scene_contract.gd` 载入 `duel_board.tscn` 后断言：

```gdscript
var board := DUEL_BOARD.instantiate()
assert(board.get_node("FieldStage") != null)
assert(board.get_node("HandLayer/PlayerHand") != null)
assert(board.get_node("HudLayer/TurnPhaseHud/PhaseButton") != null)
assert(board.get_node("OverlayLayer/ConfirmationOverlay") != null)
```

并断言 `PlayerHand` 不再是四排卡位共同父容器的子节点。

- [ ] **Step 2: 运行测试确认旧场景失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tests/ui/test_native_scene_contract.gd
```

Expected: FAIL，提示缺少 `FieldStage` 或 `HandLayer`。

- [ ] **Step 3: 重组 `.tscn` 稳定节点**

将场景改为四个全屏 `Control` 层：

```text
FieldStage/OpponentField/{OpponentSpellRow,OpponentMonsterRow}
FieldStage/PlayerField/{PlayerMonsterRow,PlayerSpellRow}
HandLayer/{OpponentHand,PlayerHand}
HudLayer/{OpponentHud,PlayerHud,TurnPhaseHud,SystemTools}
OverlayLayer/{StatusToast,CardDetailOverlay,ActionBox,ConfirmationOverlay,DebugOverlay}
```

四排继续实例化原有五个 `ZoneView`，所有 `%UniqueName` 与脚本消费名称保持不变。

- [ ] **Step 4: 运行场景契约确认通过**

Run 同 Step 2。Expected: 输出“Godot 原生场景契约通过”。

- [ ] **Step 5: 提交**

```bash
git add src/duel/duel_board.tscn tests/ui/test_native_scene_contract.gd
git commit -m "refactor(场地布局): 拆分棋盘手牌与界面层"
```

### Task 2: 定义棋盘纵深与 HUD 空间关系

**Files:**
- Modify: `src/duel/duel_board.tscn`
- Modify: `src/ui/themes/duel_theme.tres`
- Modify: `tests/ui/test_responsive_duel_layout.gd`

**Interfaces:**
- Consumes: Task 1 的四层场景与原有 `ZoneView` 最小点击尺寸。
- Produces: 三种目标分辨率下稳定的场地 Rect 关系，不新增规则字段。

- [ ] **Step 1: 写入失败的响应式几何断言**

对每个目标视口等待两帧布局后检查：

```gdscript
assert(player_field.size.x > opponent_field.size.x)
assert(player_field.size.y > opponent_field.size.y)
assert(player_hand.global_position.y < board.size.y)
assert(player_hand.global_position.y > player_field.global_position.y)
assert(!player_hand.get_global_rect().intersects(phase_button.get_global_rect()))
assert(!system_tools.get_global_rect().intersects(confirmation_overlay.get_global_rect()))
```

另检查四个 Zone Row 的全局 Rect 两两不重叠。

- [ ] **Step 2: 运行响应式测试确认失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tests/ui/test_responsive_duel_layout.gd
```

Expected: FAIL，旧布局不存在独立玩家/对手场地或尺寸关系不成立。

- [ ] **Step 3: 配置二维锚点布局**

在 `.tscn` 中设置：

- `FieldStage`：水平居中，基准宽度约为视口 64%，高度约为 72%；
- `OpponentField`：远端居中，宽度约为 `FieldStage` 的 84%，占上部 40%；
- `PlayerField`：近端居中，宽度 100%，占下部 52%；
- `PlayerHand`：底部中央前景，覆盖玩家场地下沿；
- `OpponentHand`：顶部中央，尺寸小于玩家手牌；
- `OpponentHud`、`PlayerHud` 分居远端和近端外侧；
- `TurnPhaseHud` 位于右侧中部，`SystemTools` 位于右下。

Theme 中新增 `FieldRowLayout`、`RemoteFieldRowLayout` 和 `HudPanel` 变体，
统一排间距、卡位间距和 HUD 内边距，避免脚本重复硬编码。

- [ ] **Step 4: 运行响应式测试确认通过**

Run 同 Step 2。Expected: 三种分辨率均输出布局契约通过。

- [ ] **Step 5: 提交**

```bash
git add src/duel/duel_board.tscn src/ui/themes/duel_theme.tres \
  tests/ui/test_responsive_duel_layout.gd
git commit -m "feat(场地布局): 建立近远场地与独立HUD"
```

### Task 3: 适配脚本引用和交互浮层

**Files:**
- Modify: `src/duel/duel_board.gd`
- Modify: `tests/ui/test_contextual_duel_layout.gd`
- Modify: `tests/ui/test_attack_target_flow.gd`

**Interfaces:**
- Consumes: 保持不变的 `%UniqueName` 节点、现有 `render_snapshot(Dictionary, bool)` 与规则信号。
- Produces: 不依赖旧 `Battlefield VBoxContainer` 的渲染逻辑；确认框、动作框和状态提示不会改变棋盘 Rect。

- [ ] **Step 1: 写入失败的浮层独立性测试**

记录 `FieldStage.get_global_rect()`，依次渲染 `yes_no`、`select_place`、
`effect_yes_no` 快照，等待一帧后断言棋盘 Rect 始终等于基准值，并检查重开、
退出按钮在确认浮层可见时仍未禁用。

- [ ] **Step 2: 运行交互测试确认失败或暴露旧路径**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tests/ui/test_contextual_duel_layout.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tests/ui/test_attack_target_flow.gd
```

Expected: 至少一项因缺少新层引用或浮层几何关系失败。

- [ ] **Step 3: 更新脚本布局引用**

在 `duel_board.gd` 新增四层 `@onready` 引用，用中文注释说明规则快照只改变
各层内容与可见性，不能触发布局层重建。删除对旧 `Battlefield` 行高分配的
假设，保留全部规则信号和代次门禁原样。

- [ ] **Step 4: 运行所有 Godot 交互测试**

Run:

```bash
for test_script in tests/ui/*.gd; do
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
    --script "res://$test_script" || exit 1
done
```

Expected: 所有项目测试脚本返回 0。

- [ ] **Step 5: 提交**

```bash
git add src/duel/duel_board.gd tests/ui/test_contextual_duel_layout.gd \
  tests/ui/test_attack_target_flow.gd
git commit -m "fix(场地布局): 保持规则浮层不挤压棋盘"
```

### Task 4: Godot MCP 实机验收与全量回归

**Files:**
- Modify only if verification exposes a defect: files from Tasks 1–3

**Interfaces:**
- Consumes: 完成后的场景、Theme 和测试。
- Produces: 真实引擎三分辨率证据、完整回归结果和无注入的干净工作区。

- [ ] **Step 1: 使用 Godot MCP 验收 1920×1080**

启动项目并读取场景树及 `FieldStage`、`PlayerField`、`OpponentField`、
`PlayerHand`、`PhaseButton`、`SystemTools` 的实际 Rect。截图确认玩家手牌
悬浮于底部、对手场地更窄、HUD 不占棋盘行高。

- [ ] **Step 2: 使用 Godot MCP 验收 3840×2160 与 1920×1200**

分别设置根视口尺寸或运行对应测试场景，重复读取关键 Rect，确认同一场景
结构生效且不存在重叠。覆盖一个确认决策和一个清除/取消路径。

- [ ] **Step 3: 清理 MCP 注入**

停止项目，检查 `project.godot`、`mcp_interaction_server.gd` 和 `.uid`；
删除本次生成的临时内容，并确保没有加入暂存区。

- [ ] **Step 4: 运行最终验证**

```bash
./scripts/build_native.sh
for test_script in \
  tests/ui/test_native_scene_contract.gd \
  tests/ui/test_contextual_duel_layout.gd \
  tests/ui/test_attack_target_flow.gd \
  tests/ui/test_main_attack_target_flow.gd \
  tests/ui/test_position_selection_flow.gd \
  tests/ui/test_chain_selection_flow.gd \
  tests/ui/test_place_selection_flow.gd \
  tests/ui/test_effect_yes_no_flow.gd \
  tests/ui/test_responsive_duel_layout.gd; do
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
    --script "res://$test_script" || exit 1
done
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --quit-after 180
git diff --check
```

Expected: 原生 12/12、全部 UI 测试和启动检查通过。

- [ ] **Step 5: 最终审查与提交**

请求独立代码审查，修复所有 Critical/Important，再提交：

```bash
git add src tests docs/superpowers/plans/2026-07-30-master-duel-field-ui-layout.md
git commit -m "feat(场地布局): 重构大师决斗式界面骨架"
git push origin main
```
