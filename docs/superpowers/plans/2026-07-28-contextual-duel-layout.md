# Contextual Duel Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把决斗界面重构为以中央战场为主体、动作跟随所选卡牌出现的黑白全屏布局。

**Architecture:** `DuelBoard` 改为覆盖式 UI：战场占满根节点，卡片详情、动作条、阶段确认和系统确认均使用独立浮层，不再参与三栏宽度分配。`HandView` 与 `CardView` 补充鼠标离开和重复点击语义，`Main` 只向快照提供明确的本地回合及结束回合能力。

**Tech Stack:** Godot 4.6、GDScript、C++ GDExtension、Godot MCP。

## Global Constraints

- 继续使用项目自己的黑白视觉、真实卡图和简体中文，不复制《游戏王：大师决斗》的美术资源、图标或界面纹理。
- 设计基准为 `1920×1080`，默认原生全屏并继续适配更高分辨率。
- 只显示 OCGCore 当前真实提供的动作，不制作战斗、连锁、效果目标或多区域选择的假交互。
- 每次后端快照更新必须清除陈旧动作索引。
- 不修改或暂存 `third_party/godot-cpp` 的现有工作区变化。

---

### Task 1: 卡牌与手牌交互事件

**Files:**
- Modify: `src/ui/card_view.gd`
- Modify: `src/ui/hand_view.gd`
- Create: `tests/ui/test_contextual_duel_layout.gd`

**Interfaces:**
- `CardView` produces: `card_unhovered(card_data: Dictionary)`。
- `HandView` produces: `card_unhovered(card_data: Dictionary)` 与重复点击同卡时的取消选择事件。
- Later tasks consume: `DuelBoard` 连接上述信号控制详情浮层。

- [ ] **Step 1: 编写失败的交互契约测试**

创建 `tests/ui/test_contextual_duel_layout.gd`，实例化 `HandView`，连接
`card_hovered`、`card_unhovered`、`card_selected`，调用对应内部事件后断言：

```gdscript
assert(hover_count == 1)
assert(unhover_count == 1)
assert(selected_sequence == 2)
assert(cancelled_on_second_click)
```

- [ ] **Step 2: 运行测试确认失败**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Volumes/WD/YGO \
  --script res://tests/ui/test_contextual_duel_layout.gd
```

预期：因 `card_unhovered` 不存在或重复点击不取消而失败。

- [ ] **Step 3: 实现事件**

`CardView` 在 `mouse_exited` 时发出 `card_unhovered(card_data)`。
`HandView` 转发该信号，并把重复点击当前 `_selected_key` 解释为空选择：

```gdscript
var clicked_key := _card_key(card_data)
_selected_key = "" if clicked_key == _selected_key else clicked_key
card_selected.emit({} if _selected_key.is_empty() else card_data)
```

- [ ] **Step 4: 运行契约测试确认通过**

重复 Step 2 命令，预期退出码为 0。

### Task 2: 全屏战场与情境浮层

**Files:**
- Modify: `src/duel/duel_board.gd`
- Extend test: `tests/ui/test_contextual_duel_layout.gd`

**Interfaces:**
- Consumes: `HandView.card_hovered`、`card_unhovered`、`card_selected`。
- Produces: `end_turn_requested`、`restart_requested`、`exit_requested`、`idle_action_requested`；这些信号签名保持不变。
- Produces named controls: `Battlefield`, `CardDetailOverlay`, `ContextActionBar`, `PhaseButton`, `SystemTools`, `StatusToast`。

- [ ] **Step 1: 扩展失败的布局契约测试**

测试实例化 `DuelBoard` 并等待一帧，然后断言：

```gdscript
assert(board.find_child("LegacyActionPanel", true, false) == null)
assert(board.find_child("Battlefield", true, false) != null)
assert(board.find_child("CardDetailOverlay", true, false) != null)
assert(board.find_child("ContextActionBar", true, false) != null)
assert(board.find_child("PhaseButton", true, false) != null)
assert(board.find_child("SystemTools", true, false) != null)
assert(!board.find_child("CardDetailOverlay", true, false).visible)
```

并渲染含一张可操作手牌的快照，调用选中后断言详情和动作条显示；传入新快照后
断言动作条隐藏。

- [ ] **Step 2: 运行测试确认旧三栏布局失败**

运行 Task 1 的 Godot 命令，预期因缺少命名浮层而失败。

- [ ] **Step 3: 重建场地根布局**

删除 `_build_detail_panel()` 和 `_build_action_panel()` 的永久列。建立全屏
`Battlefield`，中央纵向排列对手手牌、四行区域和玩家手牌；双方状态分别锚定
右上角与左下角，阶段控件锚定右侧中部。

- [ ] **Step 4: 实现详情浮层**

创建默认隐藏的 `CardDetailOverlay`。悬停调用 `_preview_card()`，鼠标移开且
`selected_card.is_empty()` 时关闭；点击调用 `_lock_card()`，空字典则清除详情。
效果文字放入 `ScrollContainer`，防止长文本裁切。

- [ ] **Step 5: 实现情境动作条**

创建默认隐藏的横向 `ContextActionBar`。只在精确匹配
`controller/location/sequence/card_id` 的候选数量大于零时生成胶囊按钮；
没有候选时保持隐藏，不生成占位文字。每次 `render_snapshot()` 先调用
`_clear_selection()` 销毁旧按钮。

- [ ] **Step 6: 实现阶段与系统确认**

`PhaseButton` 仅在 `local_player_turn && can_end_turn` 时可点击；点击显示
“结束回合 / 取消”。`SystemTools` 包含重新开局、信息、退出三个圆形文本按钮；
重新开局和退出均需确认，信息按钮切换现有诊断浮层。

- [ ] **Step 7: 运行布局契约测试确认通过**

运行 Task 1 的 Godot 命令，预期退出码为 0。

### Task 3: 快照能力与端到端验收

**Files:**
- Modify: `src/main/main.gd`
- Verify: `src/duel/duel_board.gd`
- Verify: `tests/ui/test_contextual_duel_layout.gd`

**Interfaces:**
- `Main` snapshot produces: `local_player_turn: bool`、`can_end_turn: bool`、
  `turn_text: String`、双方卡牌和区域统计。
- `DuelBoard.render_snapshot(snapshot: Dictionary)` consumes these exact keys。

- [ ] **Step 1: 扩展快照测试**

在契约测试中分别渲染：

```gdscript
{"local_player_turn": true, "can_end_turn": true}
{"local_player_turn": false, "can_end_turn": false}
```

断言第一份快照启用 `PhaseButton`，第二份禁用并清空动作条。

- [ ] **Step 2: 修改主场景快照**

在 `_refresh_board()` 中增加：

```gdscript
"local_player_turn": pending.kind == "idle" and int(pending.player) == 0,
"can_end_turn": pending.kind == "idle"
    and int(pending.player) == 0
    and bool(pending.can_end_turn),
```

状态错误改为写入 `StatusToast` 对应公开方法，不再依赖已删除的右侧
`status_label` 永久列。

- [ ] **Step 3: 运行自动化回归**

运行：

```bash
./scripts/build_native.sh
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Volumes/WD/YGO \
  --script res://tests/ui/test_contextual_duel_layout.gd
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Volumes/WD/YGO --quit-after 3
git diff --check
```

预期：8/8 原生测试通过，两次 Godot 进程退出码均为 0，差异检查无输出。

- [ ] **Step 4: 使用 Godot MCP 验收**

在原生全屏运行项目并验证：

1. 默认画面没有右侧永久操作列。
2. 悬停手牌显示详情，移开关闭。
3. 点击可操作卡牌显示且只显示该卡候选。
4. 召唤或盖放后动作条清空，场区使用后端快照更新。
5. 阶段球确认后结束回合，对手回合阶段球禁用。
6. 信息和重新开局确认工作；最后点击退出确认结束进程。
