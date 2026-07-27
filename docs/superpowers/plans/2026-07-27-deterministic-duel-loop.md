# 确定性最小对局闭环实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 使用固定牌组和种子，从玩家 1 主阶段安全提交结束回合并推进到玩家 2 主阶段，全程由 C++ 解析 OCGCore 协议。

**Architecture:** `DuelMessageParser` 负责解析带长度前缀的 OCGCore 消息缓冲区，`DuelSession` 保存待决策状态并提供语义化结束回合操作，`YgoCoreBridge` 只向 Godot 暴露 Dictionary。GDScript 不再构造原始响应字节。

**Tech Stack:** C++17、OCGCore C API、Godot 4.6 GDExtension、GDScript、CMake、CTest、Godot MCP。

## Global Constraints

- 项目文件只能保存在 `/Volumes/WD/YGO` 内。
- 新增或修改的自有代码必须包含准确的中文注释。
- 项目自有日志、错误和用户可见诊断必须使用简体中文。
- 不修改 `third_party/` 中的上游源码。
- 本计划只实现空闲阶段的“结束回合”，不实现召唤、盖放、发动、战斗、AI 或牌组编辑。
- 不把当前 `third_party/godot-cpp` 的既有本地改动纳入提交。

---

## 文件结构

- Create: `native/include/ygo/duel_message_parser.hpp` — Godot 无关的消息帧与 `MSG_SELECT_IDLECMD` 解析接口。
- Create: `native/src/duel_message_parser.cpp` — 有界小端读取和消息流解析实现。
- Create: `native/tests/test_duel_message_parser.cpp` — 合法、截断及通知消息解析测试。
- Modify: `native/include/ygo/duel_session.hpp` — 待决策模型、推进结果和语义结束回合接口。
- Modify: `native/src/duel_session.cpp` — 获取消息缓冲区、维护待决策、提交受校验的响应。
- Modify: `native/tests/test_duel_session.cpp` — 真实素材固定牌组闭环集成测试。
- Modify: `native/include/ygo/ygo_core_bridge.hpp` — Godot 语义接口声明。
- Modify: `native/src/ygo_core_bridge.cpp` — `PendingAction` 到 Dictionary 的转换与绑定。
- Modify: `src/main/main.gd` — 删除字节组包，使用 `submit_end_turn()`。
- Modify: `native/CMakeLists.txt` — 注册解析器库和测试。

### Task 1: 解析 OCGCore 空闲阶段消息

**Files:**
- Create: `native/include/ygo/duel_message_parser.hpp`
- Create: `native/src/duel_message_parser.cpp`
- Create: `native/tests/test_duel_message_parser.cpp`
- Modify: `native/CMakeLists.txt`

**Interfaces:**
- Consumes: OCGCore 消息缓冲区格式 `[uint32 little-endian length][message bytes]...`。
- Produces: `ygo::PendingAction parse_pending_action(const std::uint8_t *data, std::size_t size)`。
- Produces: `PendingActionKind::{None, Idle, Unsupported, Malformed}` 与字段 `player`、`can_end_turn`、`message_type`、`message`。

- [ ] **Step 1: 写合法空闲消息失败测试**

构造一帧 `MSG_NEW_TURN` 和一帧所有列表为空、`to_bp=1`、`to_ep=1`、
`can_shuffle=0` 的 `MSG_SELECT_IDLECMD`，断言结果为 `Idle`、玩家 0 且
允许结束回合。

- [ ] **Step 2: 运行测试并确认因解析器不存在而失败**

Run:

```bash
cmake -S native -B build/native -DCMAKE_BUILD_TYPE=Debug
cmake --build build/native --target test_duel_message_parser -j4
```

Expected: FAIL，提示目标或 `duel_message_parser.hpp` 尚不存在。

- [ ] **Step 3: 实现最小消息帧和空闲消息解析**

解析每个 `uint32` 长度前缀；对 `MSG_SELECT_IDLECMD` 按顺序读取玩家、
六组列表和三个尾部布尔值。六组元素宽度依次为
`10、10、7、10、10、19` 字节。任何越界都返回 `Malformed` 和中文诊断。

- [ ] **Step 4: 运行解析器测试并确认通过**

Run:

```bash
cmake --build build/native --target test_duel_message_parser -j4
ctest --test-dir build/native -R duel_message_parser --output-on-failure
```

Expected: PASS。

- [ ] **Step 5: 写截断消息和未知交互消息失败测试**

断言截断帧返回 `Malformed`；未知消息帧返回 `Unsupported` 并保留消息号。

- [ ] **Step 6: 运行测试确认新用例失败，再补最小实现并复跑**

Run:

```bash
cmake --build build/native --target test_duel_message_parser -j4
ctest --test-dir build/native -R duel_message_parser --output-on-failure
```

Expected: 首次 FAIL；实现后 PASS。

### Task 2: 在 `DuelSession` 中建立语义动作闭环

**Files:**
- Modify: `native/include/ygo/duel_session.hpp`
- Modify: `native/src/duel_session.cpp`
- Modify: `native/tests/test_duel_session.cpp`
- Modify: `native/CMakeLists.txt`

**Interfaces:**
- Consumes: `parse_pending_action(...)`。
- Produces: `const PendingAction &pending_action() const noexcept`。
- Produces: `ProcessResult start()`、`ProcessResult step()`。
- Produces: `ProcessResult submit_end_turn()`，仅在 `Idle && can_end_turn` 时提交小端 `int32(7)`。

- [ ] **Step 1: 写非活动决斗拒绝结束回合的失败测试**

创建但不启动或已销毁的 `DuelSession`，断言 `submit_end_turn().ok == false`
且中文消息为“决斗尚未创建”或“当前不是可结束回合的空闲阶段”。

- [ ] **Step 2: 构建并确认接口缺失导致失败**

Run:

```bash
cmake --build build/native --target test_duel_session -j4
```

Expected: FAIL，提示 `submit_end_turn` 或 `ProcessResult` 不存在。

- [ ] **Step 3: 实现统一推进与消息捕获**

每次 `OCG_DuelProcess` 后立即调用 `OCG_DuelGetMessage`，将缓冲区交给解析器，
更新 `pending_action_` 并返回 `ProcessResult`。`destroy()` 同时清空待决策。

- [ ] **Step 4: 实现受校验的 `submit_end_turn()`**

仅当待决策为 `Idle` 且 `can_end_turn=true` 时，用固定 4 字节小端响应
`{7, 0, 0, 0}` 调用 `OCG_DuelSetResponse`，随后推进并捕获新消息。

- [ ] **Step 5: 运行会话测试并确认通过**

Run:

```bash
cmake --build build/native --target test_duel_session -j4
ctest --test-dir build/native -R duel_session --output-on-failure
```

Expected: PASS。

- [ ] **Step 6: 写真实素材固定牌组闭环失败测试**

从仓库卡库中按卡号升序选择前 40 张同时具有 `official/c<id>.lua` 的卡，
双方使用相同列表和固定种子。断言启动后双方 `deck=35`、`hand=5`，
待决策玩家为 0；提交结束回合后继续推进，直到待决策玩家为 1。

- [ ] **Step 7: 运行集成测试确认失败，再补最小推进循环**

Run:

```bash
cmake --build build/native --target test_duel_session -j4
ctest --test-dir build/native -R duel_session --output-on-failure
```

Expected: 首次因尚未持续处理通知消息或待决策不完整而 FAIL；实现有限循环后 PASS。
循环必须在 `AWAITING`、`END`、不支持消息或最大步数处停止，禁止无限推进。

### Task 3: Godot 只使用语义接口

**Files:**
- Modify: `native/include/ygo/ygo_core_bridge.hpp`
- Modify: `native/src/ygo_core_bridge.cpp`
- Modify: `src/main/main.gd`

**Interfaces:**
- Consumes: `DuelSession::pending_action()` 与 `submit_end_turn()`。
- Produces: `get_pending_action() -> Dictionary`。
- Produces: `submit_end_turn() -> Dictionary`。

- [ ] **Step 1: 在 GDScript 中先改为调用尚不存在的语义接口**

删除 `_build_idle_cmd_response()` 和 `_on_duel_response()`；结束回调改为
`bridge.call("submit_end_turn")`，刷新逻辑从返回的 `pending_action` 决定按钮。

- [ ] **Step 2: 运行 Godot 无头模式并确认因方法未绑定而失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Volumes/WD/YGO --quit-after 3
```

Expected: FAIL 或调试输出报告 `submit_end_turn` 不存在。

- [ ] **Step 3: 实现 Dictionary 转换和方法绑定**

将 `PendingActionKind` 映射为稳定字符串 `none`、`idle`、`unsupported`、
`malformed`；返回玩家、能否结束回合、消息号和中文诊断。桥接层不得暴露
原始响应缓冲区。

- [ ] **Step 4: 构建并运行完整自动验证**

Run:

```bash
./scripts/build_native.sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Volumes/WD/YGO --quit-after 3
git diff --check
```

Expected: 全部 CTest 通过；Godot 退出码为 0 且无项目错误；差异检查通过。

- [ ] **Step 5: 使用 Godot MCP 做交互验收**

通过 Godot MCP 打开并运行项目，读取调试输出，确认双方显示“卡组 35、
手牌 5”；确认玩家 1 时“结束回合”可用；点击后确认界面显示玩家 2
决策且按钮状态正确；捕获最终画面。

- [ ] **Step 6: 审阅工作区并提交功能**

Run:

```bash
git status --short
git diff --check
git diff -- native src/main project.godot
```

只暂存本计划涉及的项目自有文件，不暂存 `third_party/godot-cpp`。
提交标题和正文使用简体中文 Conventional Commits，并在正文记录测试与
Godot MCP 验证结果。
