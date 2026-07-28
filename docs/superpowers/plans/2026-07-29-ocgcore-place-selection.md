# OCGCore 情境式区域选择 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让玩家直接点击原生空卡位，完成所有 `count=1` 的真实 OCGCore 区域选择，不再由客户端自动选择第一个区域。

**Architecture:** C++ 解析器把 forbidden 位掩码转换为不可变 `PlaceOption` 候选，响应构建器与 `DuelSession` 独占三字节协议提交。Bridge 只向 Godot 发布语义三元组；`DuelBoard` 全量映射空 `ZoneView` 后原子高亮，`Main` 使用决策代次和提交锁把点击转交 Bridge。

**Tech Stack:** C++20、OCGCore 11、Godot 4.6 GDExtension、GDScript、CTest、Godot headless、Godot MCP

## Global Constraints

- 项目内容只能保存在 `/Volumes/WD/YGO`。
- 新增或修改的自有代码必须有准确中文注释；项目日志、错误和界面诊断使用简体中文。
- C++ 独占 OCGCore 协议、候选校验和响应组包；Godot 只消费语义字段和发出交互意图。
- 原生 UI 使用现有 `Control`、`Container`、`ZoneView` 和主题，不以代码绘制替代 Godot 场景能力。
- 当前可视范围是双方 sequence 0–4 的五怪兽区与五魔陷区；任何不可映射候选都必须原子阻断，不能部分显示或默认提交。
- 提交前运行与风险匹配的 C++、Godot、真实 OCGCore、多分辨率和 Godot MCP 验收。
- Git 提交使用简体中文 Conventional Commits，并在正文记录原因、修改和验证。

---

### Task 1: 严格解析区域候选并构造语义响应

**Files:**
- Modify: `native/include/ygo/duel_message_parser.hpp`
- Modify: `native/src/duel_message_parser.cpp`
- Modify: `native/include/ygo/duel_response.hpp`
- Modify: `native/src/duel_response.cpp`
- Test: `native/tests/test_duel_message_parser.cpp`
- Test: `native/tests/test_duel_response.cpp`

**Interfaces:**
- Consumes: OCGCore `MSG_SELECT_PLACE` 的 `player/count/forbidden` 正文。
- Produces: `PendingActionKind::SelectPlace`、`PendingAction::place_options`、`build_place_response(const PendingAction &, uint8_t, uint8_t, uint8_t)`。

- [ ] **Step 1: 写严格解析失败测试**

在 `test_duel_message_parser.cpp` 增加并注册以下断言：

```cpp
assert(parse_place({MSG_SELECT_PLACE, 0, 1, /* forbidden=... */}).kind
       == ygo::PendingActionKind::SelectPlace);
assert(player_two.place_options.front().player == 1);
assert(truncated.kind == ygo::PendingActionKind::Malformed);
assert(trailing.kind == ygo::PendingActionKind::Malformed);
assert(no_options.kind == ygo::PendingActionKind::Malformed);
assert(multi.kind == ygo::PendingActionKind::Unsupported);
```

同时断言怪兽区 0–6、魔陷区 0–7 的位映射和“决策玩家低 16 位、另一方高
16 位”语义。

- [ ] **Step 2: 写响应构建失败测试**

在 `test_duel_response.cpp` 构造含多个非连续候选的 `SelectPlace` 快照，断言：

```cpp
const auto valid = ygo::build_place_response(pending, 0, LOCATION_MZONE, 3);
assert(valid.ok);
assert(valid.bytes == std::vector<std::uint8_t>({0, LOCATION_MZONE, 3}));
assert(!ygo::build_place_response(pending, 0, LOCATION_MZONE, 2).ok);
assert(!ygo::build_place_response({}, 0, LOCATION_MZONE, 3).ok);
```

- [ ] **Step 3: 运行目标测试确认失败**

Run:

```bash
cmake --build build --target test_duel_message_parser test_duel_response
ctest --test-dir build --output-on-failure -R 'duel_message_parser|duel_response'
```

Expected: FAIL，缺少 `SelectPlace` 或 `build_place_response`。

- [ ] **Step 4: 实现严格解析与响应构建器**

将 `AutoSelectPlace` 重命名为 `SelectPlace`；解析器要求 `reader.remaining()==0`，
按位展开候选且拒绝零候选。实现纯值构建器，只匹配完整三元组并输出：

```cpp
return {true, "", {player, location, sequence}};
```

- [ ] **Step 5: 运行测试并提交**

Run:

```bash
cmake --build build --target test_duel_message_parser test_duel_response
ctest --test-dir build --output-on-failure -R 'duel_message_parser|duel_response'
git diff --check
```

Expected: PASS。

Commit:

```bash
git add native/include/ygo/duel_message_parser.hpp native/src/duel_message_parser.cpp \
  native/include/ygo/duel_response.hpp native/src/duel_response.cpp \
  native/tests/test_duel_message_parser.cpp native/tests/test_duel_response.cpp
git commit -m "feat(规则): 解析并编码区域选择"
```

### Task 2: DuelSession 提交真实区域并恢复 Retry

**Files:**
- Modify: `native/include/ygo/duel_session.hpp`
- Modify: `native/src/duel_session.cpp`
- Test: `native/tests/test_duel_session.cpp`

**Interfaces:**
- Consumes: Task 1 的 `SelectPlace` 与 `build_place_response(...)`。
- Produces: `DuelSession::submit_place(uint8_t player, uint8_t location, uint8_t sequence)`；所有来源的区域选择都停在玩家决策点。

- [ ] **Step 1: 写会话失败测试**

扩展测试夹具，使伪核心或可观察边界能验证：

```cpp
auto result = session.submit_place(0, LOCATION_MZONE, 3);
assert(result.ok);
assert(!session.submit_place(0, LOCATION_MZONE, 3).ok); // 已消费
assert(!session.submit_place(0, LOCATION_MZONE, 2).ok); // 非候选
```

增加 Retry 场景，断言拒绝后 `pending_action().kind == SelectPlace` 且候选完整
恢复；增加非召唤来源的 SelectPlace，断言不会改写为 Unsupported。

- [ ] **Step 2: 运行目标测试确认失败**

Run:

```bash
cmake --build build --target test_duel_session
ctest --test-dir build --output-on-failure -R duel_session
```

Expected: FAIL，缺少 `submit_place`，或当前流程仍自动选第一区域。

- [ ] **Step 3: 删除自动选区状态并实现语义提交**

删除 `allow_auto_select_place_` 及 `process_once()` 的自动提交分支。新增：

```cpp
ProcessResult DuelSession::submit_place(
    std::uint8_t player,
    std::uint8_t location,
    std::uint8_t sequence);
```

它调用 Task 1 构建器，保存 `last_submitted_action_`，写入响应并推进。所有其他
提交入口不再维护自动选区标记。

- [ ] **Step 4: 运行会话与全套原生测试并提交**

Run:

```bash
cmake --build build
ctest --test-dir build --output-on-failure
git diff --check
```

Expected: 全部 PASS。

Commit:

```bash
git add native/include/ygo/duel_session.hpp native/src/duel_session.cpp \
  native/tests/test_duel_session.cpp
git commit -m "feat(会话): 提交真实区域决策"
```

### Task 3: Bridge 发布区域语义并拒绝伪造输入

**Files:**
- Modify: `native/src/pending_action_godot_adapter.cpp`
- Modify: `native/include/ygo/ygo_core_bridge.hpp`
- Modify: `native/src/ygo_core_bridge.cpp`
- Test: `native/tests/test_pending_action_godot_adapter.cpp`
- Test: `native/tests/test_ygo_core_bridge.cpp`

**Interfaces:**
- Consumes: Task 2 的 `DuelSession::submit_place(...)`。
- Produces: 字典字段 `place_options: Array[Dictionary]`；ClassDB 方法 `submit_place(controller, location, sequence) -> Dictionary`。

- [ ] **Step 1: 写 Adapter 与 Bridge 失败测试**

断言 Adapter 对 `SelectPlace` 输出：

```cpp
assert(dictionary["kind"] == godot::String("select_place"));
assert(place_options.size() == 2);
assert(option["controller"] == 0);
assert(option["location"] == LOCATION_MZONE);
assert(option["sequence"] == 3);
```

Bridge 测试断言 ClassDB 注册 `submit_place`，但不暴露原始响应入口；负数、超过
uint8、非本地玩家、终局和错误决策均返回中文失败且不推进。

- [ ] **Step 2: 运行目标测试确认失败**

Run:

```bash
cmake --build build --target test_pending_action_godot_adapter test_ygo_core_bridge
ctest --test-dir build --output-on-failure -R 'pending_action_godot_adapter|ygo_core_bridge'
```

Expected: FAIL，缺少字段与方法。

- [ ] **Step 3: 实现稳定字典与 Bridge 门禁**

Adapter 始终输出 `place_options`；Bridge 在转换为 `uint8_t` 前校验三个参数均在
0–255，并要求当前决策属于本地玩家且会话未结束，再调用 Session。

- [ ] **Step 4: 运行测试并提交**

Run:

```bash
cmake --build build
ctest --test-dir build --output-on-failure
git diff --check
```

Expected: 全部 PASS。

Commit:

```bash
git add native/src/pending_action_godot_adapter.cpp \
  native/include/ygo/ygo_core_bridge.hpp native/src/ygo_core_bridge.cpp \
  native/tests/test_pending_action_godot_adapter.cpp \
  native/tests/test_ygo_core_bridge.cpp
git commit -m "feat(桥接): 暴露区域选择语义"
```

### Task 4: Godot 原生卡位高亮与代次安全提交

**Files:**
- Modify: `src/ui/zone_view.gd`
- Modify: `src/ui/zone_view.tscn`
- Modify: `src/duel/duel_board.gd`
- Modify: `src/main/main.gd`
- Test: `tests/ui/test_contextual_duel_layout.gd`
- Test: `tests/ui/test_main_attack_target_flow.gd`

**Interfaces:**
- Consumes: snapshot `decision_kind="select_place"` 与 `place_options`。
- Produces: `DuelBoard.place_requested(controller, location, sequence, decision_generation)`；Main 调用 `bridge.submit_place(...)`。

- [ ] **Step 1: 写界面失败测试**

在 DuelBoard 测试构造双方怪兽区/魔陷区候选，断言：

- 只有合法且为空的 ZoneView 使用 `PlaceCandidate` 主题变体；
- 点击发出精确三元组和当前代次；
- 非候选、已占用区、双击与旧代次不发出第二次信号；
- 任一 sequence 5 或未知 location 使全部候选原子隐藏；
- Retry 保留代次重建，正常新快照递增代次；
- 重开/终局清除高亮。

在 Main 测试用 FakeBridge 记录：

```gdscript
func submit_place(controller: int, location: int, sequence: int) -> Dictionary:
    place_submissions.append([controller, location, sequence])
    return next_result
```

断言提交锁与过期代次门禁。

- [ ] **Step 2: 运行 Godot 目标测试确认失败**

Run:

```bash
godot --headless --path . --script tests/ui/test_contextual_duel_layout.gd
godot --headless --path . --script tests/ui/test_main_attack_target_flow.gd
```

Expected: FAIL，缺少信号、高亮和 Main 路由。

- [ ] **Step 3: 用原生 ZoneView 实现区域候选**

给 `ZoneView` 增加 `place_requested` 信号或复用其 GUI 输入，通过场景内
`TargetHighlight` 节点的 `PlaceCandidate` 主题变体显示候选。`DuelBoard`
先映射所有候选到四组 ZoneView，确认卡位为空，再发布绑定；点击后立即清空本代
入口并发出信号。

- [ ] **Step 4: Main 接入 Bridge 与 Retry**

连接 `place_requested`。处理函数同时校验 `_input_locked`、当前
`decision_generation` 和 `decision_kind`，调用 `bridge.submit_place`；
`response_rejected` 时使用 `preserve_decision_generation=true` 重绘，其余结果
走现有统一快照刷新。

- [ ] **Step 5: 运行 UI 套件并提交**

Run:

```bash
godot --headless --path . --script tests/ui/test_native_scene_contract.gd
godot --headless --path . --script tests/ui/test_contextual_duel_layout.gd
godot --headless --path . --script tests/ui/test_main_attack_target_flow.gd
godot --headless --path . --script tests/ui/test_position_selection_flow.gd
godot --headless --path . --script tests/ui/test_chain_selection_flow.gd
git diff --check
```

Expected: 全部 PASS。

Commit:

```bash
git add src/ui/zone_view.gd src/ui/zone_view.tscn src/duel/duel_board.gd \
  src/main/main.gd tests/ui/test_contextual_duel_layout.gd \
  tests/ui/test_main_attack_target_flow.gd
git commit -m "feat(界面): 以原生卡位选择放置区域"
```

### Task 5: 真实 OCGCore、多分辨率与 Godot MCP 验收

**Files:**
- Modify: `native/tests/test_duel_session.cpp`
- Modify: `tests/ui/test_responsive_duel_layout.gd`
- Create: `tests/ui/test_place_selection_flow.gd`
- Modify: `CMakeLists.txt` only if a new native test target is required

**Interfaces:**
- Consumes: Tasks 1–4 的完整区域选择链路。
- Produces: 固定种子的真实核心回归、多分辨率契约和可重复 Godot MCP 验收证据。

- [ ] **Step 1: 增加真实核心非首位选区测试**

使用当前测试牌库和公开 API 推进到真实 `SelectPlace`。从至少两个候选中选择非
首项，调用 `submit_place`，再用 `query_cards` 断言目标卡的
`location/sequence` 与所选候选完全一致。相同牌组与种子重放，决策序列一致。

- [ ] **Step 2: 增加独立 Godot 流程与响应式场景**

`test_place_selection_flow.gd` 覆盖候选点击、伪造输入、Retry、双击、旧代次和
重开。响应式测试增加同时包含怪兽区、魔陷区候选的场景，并在
1920×1080、3840×2160、1920×1200 断言高亮矩形位于 SafeArea 且不遮挡手牌、
阶段按钮或退出按钮。

- [ ] **Step 3: 运行完整自动化**

Run:

```bash
./scripts/build_native.sh
godot --headless --path . --script tests/ui/test_native_scene_contract.gd
godot --headless --path . --script tests/ui/test_contextual_duel_layout.gd
godot --headless --path . --script tests/ui/test_main_attack_target_flow.gd
godot --headless --path . --script tests/ui/test_position_selection_flow.gd
godot --headless --path . --script tests/ui/test_chain_selection_flow.gd
godot --headless --path . --script tests/ui/test_place_selection_flow.gd
godot --headless --path . --script tests/ui/test_responsive_duel_layout.gd
godot --headless --path . --quit-after 180
```

Expected: CTest 与全部 Godot 测试 PASS，启动无项目错误。

- [ ] **Step 4: 使用 Godot MCP 验收**

用 Godot MCP：

1. 运行 `/Volumes/WD/YGO`。
2. 获取场景树与 1920×1080 截图。
3. 通过真实输入进入召唤或盖放的 SelectPlace，点击非首个高亮空卡位。
4. 截图确认卡片进入所选 sequence，读取调试输出确认无项目错误。
5. 通过生产 `SubViewport` 验证 3840×2160 原生布局。
6. 停止项目并清理 MCP 注入的 Autoload、脚本和 UID。

- [ ] **Step 5: 最终审查、提交与推送**

Run:

```bash
git status --short
git diff --check
git diff --stat origin/main..HEAD
git log --oneline origin/main..HEAD
```

修复所有 Critical/Important 审查问题后提交测试：

```bash
git add native/tests/test_duel_session.cpp \
  tests/ui/test_place_selection_flow.gd \
  tests/ui/test_responsive_duel_layout.gd CMakeLists.txt
git commit -m "test(选区): 完成真实核心与多分辨率验收"
git push origin main
```
