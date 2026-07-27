# 黑白可视化决斗原型实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个 `1280×720` 黑白 2D 决斗场，用真实卡图和真实 OCGCore 候选完成选卡、召唤/盖放/发动入口及结束回合。

**Architecture:** C++ 解析 OCGCore 空闲阶段候选并提供语义动作与决斗快照；Godot 使用拆分后的 `CardView`、`ZoneView`、`HandView` 和 `DuelBoard` 渲染。前端只消费后端快照，不维护第二套规则状态。

**Tech Stack:** Godot 4.6.3、GDScript、C++17、GDExtension、OCGCore、CMake、CTest、Godot MCP。

## Global Constraints

- 项目文件只能保存在 `/Volumes/WD/YGO`。
- 基准 viewport 固定为 `1280×720`，使用 `canvas_items` 拉伸。
- 项目自有代码必须包含准确的中文注释，项目自有诊断必须使用简体中文。
- 黑白界面保留真实卡图原色；不制作复杂动画、音效、联网或 AI。
- Godot 不得构造 OCGCore 原始响应字节。
- 不修改 `third_party/` 上游代码，不暂存其现有本地改动。

---

## 文件结构

- Modify: `native/include/ygo/duel_message_parser.hpp` — 空闲阶段候选值类型。
- Modify: `native/src/duel_message_parser.cpp` — 完整解析六类候选列表。
- Modify: `native/tests/test_duel_message_parser.cpp` — 非空候选和非法索引测试。
- Modify: `native/include/ygo/duel_session.hpp` — 语义动作及区域快照类型。
- Modify: `native/src/duel_session.cpp` — 提交动作、查询可见区域。
- Modify: `native/tests/test_duel_session.cpp` — 真实素材动作闭环测试。
- Modify: `native/include/ygo/ygo_core_bridge.hpp` — Godot 快照与动作接口。
- Modify: `native/src/ygo_core_bridge.cpp` — Dictionary/Array 转换。
- Create: `src/ui/card_view.gd`、`src/ui/card_view.tscn` — 单张卡片显示与输入。
- Create: `src/ui/zone_view.gd`、`src/ui/zone_view.tscn` — 场地区域显示。
- Create: `src/ui/hand_view.gd`、`src/ui/hand_view.tscn` — 手牌排列。
- Create: `src/duel/duel_board.gd`、`src/duel/duel_board.tscn` — 决斗场和详情/动作面板。
- Modify: `src/main/main.gd`、`src/main/main.tscn` — 初始化后端并承载决斗场。
- Modify: `project.godot` — 保持 1280×720，增加 F1 诊断输入动作。

### Task 1: 完整解析空闲阶段候选

**Files:**
- Modify: `native/include/ygo/duel_message_parser.hpp`
- Modify: `native/src/duel_message_parser.cpp`
- Modify: `native/tests/test_duel_message_parser.cpp`

**Interfaces:**
- Produces: `IdleActionKind::{NormalSummon, SpecialSummon, Reposition, MonsterSet, SpellTrapSet, Activate}`。
- Produces: `IdleAction { kind, index, card_id, controller, location, sequence, description, client_mode }`。
- Extends: `PendingAction::idle_actions`。

- [ ] **Step 1: 写六类非空候选失败测试**

构造每类恰好一个候选的 `MSG_SELECT_IDLECMD`，使用独立字面量卡号和索引，
断言解析出 6 个 `IdleAction`，动作顺序和字段与消息一致。

- [ ] **Step 2: 运行解析器测试确认接口缺失**

Run:

```bash
cmake --build build/native --target test_duel_message_parser -j4
```

Expected: FAIL，提示 `IdleAction` 或 `idle_actions` 不存在。

- [ ] **Step 3: 实现有界候选解析**

为六类列表逐项读取已验证宽度；索引按各自列表从 0 开始。任何元素截断均返回
`Malformed`，且不得保留部分可执行动作。

- [ ] **Step 4: 运行解析器测试**

Run:

```bash
cmake --build build/native --target test_duel_message_parser -j4
ctest --test-dir build/native -R duel_message_parser --output-on-failure
```

Expected: PASS。

### Task 2: 提交语义动作并验证真实区域变化

**Files:**
- Modify: `native/include/ygo/duel_session.hpp`
- Modify: `native/src/duel_session.cpp`
- Modify: `native/tests/test_duel_session.cpp`

**Interfaces:**
- Consumes: `PendingAction::idle_actions`。
- Produces: `ProcessResult submit_idle_action(IdleActionKind kind, std::size_t index)`。
- Produces: `std::vector<VisibleCard> query_cards(team, location)`。

- [ ] **Step 1: 写非法动作拒绝失败测试**

在玩家 1 空闲阶段提交不存在的动作类型和越界索引，断言 `ok=false`，手牌与场区
计数保持不变。

- [ ] **Step 2: 构建确认语义接口缺失**

Run:

```bash
cmake --build build/native --target test_duel_session -j4
```

Expected: FAIL，提示 `submit_idle_action` 不存在。

- [ ] **Step 3: 实现动作快照校验和响应组包**

把动作类型映射到 OCGCore `type=0/3/4/5`，只接受当前快照中同类型、同索引候选，
构造小端 `int32((index << 16) | type)`；`submit_end_turn()` 复用 `type=7`。

- [ ] **Step 4: 写真实动作闭环测试**

使用包含通常怪兽和可盖放魔陷的固定真实牌组，推进到空闲阶段；选择一个实际候选，
提交后断言玩家手牌减少 1，对应怪兽区或魔陷区增加 1。

- [ ] **Step 5: 实现区域卡片查询**

使用 `OCG_DuelQuery` 查询玩家手牌、怪兽区、魔陷区、墓地和除外区，解析可见卡号、
位置、序号和表示形式。对手手牌只对外返回数量。

- [ ] **Step 6: 运行会话测试**

Run:

```bash
cmake --build build/native --target test_duel_session -j4
ctest --test-dir build/native -R duel_session --output-on-failure
```

Expected: PASS。

### Task 3: 暴露 Godot 决斗快照

**Files:**
- Modify: `native/include/ygo/ygo_core_bridge.hpp`
- Modify: `native/src/ygo_core_bridge.cpp`
- Modify: `src/main/main.gd`

**Interfaces:**
- Produces: `get_duel_snapshot() -> Dictionary`。
- Produces: `submit_idle_action(action_kind: String, index: int) -> Dictionary`。

- [ ] **Step 1: 让 GDScript 调用尚未绑定的快照接口**

启动后读取 `get_duel_snapshot()`，断言玩家手牌数组为 5 项且每项包含
`card_id`、`image_path`、`cn_name`。

- [ ] **Step 2: 无头运行确认方法缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Volumes/WD/YGO --quit-after 3
```

Expected: 调试输出报告 `get_duel_snapshot` 不存在。

- [ ] **Step 3: 实现 Dictionary 转换和绑定**

快照返回玩家可见卡、对手手牌数量、各区域卡列表、待决策动作、当前玩家和中文状态；
动作接口把稳定字符串映射为 C++ 枚举，未知字符串直接拒绝。

- [ ] **Step 4: 构建和无头验证**

Run:

```bash
./scripts/build_native.sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Volumes/WD/YGO --quit-after 3
```

Expected: CTest 全绿且 Godot 无项目自身错误。

### Task 4: 建立黑白场地与真实卡图组件

**Files:**
- Create: `src/ui/card_view.gd`
- Create: `src/ui/card_view.tscn`
- Create: `src/ui/zone_view.gd`
- Create: `src/ui/zone_view.tscn`
- Create: `src/ui/hand_view.gd`
- Create: `src/ui/hand_view.tscn`
- Create: `src/duel/duel_board.gd`
- Create: `src/duel/duel_board.tscn`
- Modify: `src/main/main.gd`
- Modify: `src/main/main.tscn`
- Modify: `project.godot`

**Interfaces:**
- Consumes: `get_duel_snapshot()`。
- Produces signal: `idle_action_requested(action_kind: String, index: int)`。
- Produces method: `DuelBoard.render_snapshot(snapshot: Dictionary)`。

- [ ] **Step 1: 创建 CardView**

使用 `TextureButton`/`TextureRect` 显示 `res://images/<id>.webp`，卡背用黑色圆角矩形
与白色细框绘制；正面加载失败时显示卡号占位。悬停和点击分别发出卡资料与选择信号。

- [ ] **Step 2: 创建 ZoneView 与 HandView**

`ZoneView` 固定黑白边框并能显示顶牌和数量；`HandView` 根据宽度重叠排列卡片，
玩家可点击、对手只显示卡背。

- [ ] **Step 3: 创建 DuelBoard**

按设计三列布局建立详情、中央场地和动作面板；创建双方完整区域框架，并用快照填充
玩家手牌、对手卡背、区域卡和动作按钮。

- [ ] **Step 4: 替换主诊断页**

`Main` 只初始化桥接、开局、连接动作信号并刷新快照；旧诊断文字移入默认隐藏的
`F1` 覆盖层。

- [ ] **Step 5: Godot MCP 第一轮视觉验收**

运行项目并截图，检查 viewport 为 `1280×720`，双方手牌、区域、详情和动作面板
均在画面内；玩家 5 张真实卡图、对手 5 张卡背可见。

### Task 5: 打通选卡、动作和回合流程

**Files:**
- Modify: `src/duel/duel_board.gd`
- Modify: `src/main/main.gd`
- Modify: `native/src/ygo_core_bridge.cpp`
- Test: `native/tests/test_duel_session.cpp`

**Interfaces:**
- Consumes: `submit_idle_action` 与 `submit_end_turn`。
- Produces: 可实际操作的选卡—动作—场面刷新流程。

- [ ] **Step 1: 实现卡片选择与动作过滤**

点击玩家手牌后按 `card_id/location/sequence` 过滤快照候选，只为真实候选创建
“召唤”“怪兽盖放”“魔陷盖放”“发动”按钮；没有候选时显示中文说明。

- [ ] **Step 2: 提交动作并刷新**

点击动作时发送 `action_kind/index`，成功后清除选择并重新读取快照；失败时保留选择
和场面，右侧显示后端中文错误。

- [ ] **Step 3: 保持结束回合和重新开局**

结束回合调用现有语义接口并刷新对手手牌数量；重新开局恢复双方 5 张手牌和空场。

- [ ] **Step 4: Godot MCP 完整交互验收**

实际点击一张有候选的玩家手牌，确认动作按钮；执行召唤/盖放/发动中的至少一种，
确认手牌减少和对应场区出现卡图；再点击结束回合，确认对手手牌数量增加和决策玩家切换。

- [ ] **Step 5: 完整验证和提交**

Run:

```bash
./scripts/build_native.sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Volumes/WD/YGO --quit-after 3
git diff --check
```

只暂存项目自有文件，以简体中文 Conventional Commit 记录功能范围、测试和
Godot MCP 验收结果。
