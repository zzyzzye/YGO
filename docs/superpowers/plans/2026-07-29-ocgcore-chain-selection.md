# OCGCore 连锁候选情境交互 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用卡牌高亮和情境按钮完成真实 OCGCore 带候选连锁响应。

**Architecture:** C++ 严格解析并拥有候选索引、响应编码和 Retry；Bridge 只透传
语义字典；Godot 根据核心位置映射真实节点并转发候选索引，不解释原始协议。

**Tech Stack:** C++20、OCGCore 11、Godot 4.6.3、GDExtension、GDScript。

## Global Constraints

- 项目文件仅位于 `/Volumes/WD/YGO`。
- 自有代码使用充分中文注释，项目日志与诊断使用简体中文。
- 固定 UI 使用现有 `.tscn/.tres`，动态候选按钮由 Godot 原生 Control 创建。
- 每项实现先观察失败测试，再实现并运行对应回归。
- 最终必须运行 CTest、全部 Godot UI 测试、headless 与 Godot MCP。

---

### Task 1: 连锁帧与响应语义

**Files:**
- Modify: `native/include/ygo/duel_message_parser.hpp`
- Modify: `native/src/duel_message_parser.cpp`
- Modify: `native/include/ygo/duel_response.hpp`
- Modify: `native/src/duel_response.cpp`
- Test: `native/tests/test_duel_message_parser.cpp`
- Test: `native/tests/test_duel_response.cpp`

**Interfaces:**
- Produces: `PendingActionKind::SelectChain`、`ChainOption`、
  `build_chain_response(const PendingAction &, std::size_t)`、
  `build_chain_pass_response(const PendingAction &)`.

- [ ] 写严格 23 字节候选、同卡多效果、截断、尾随、非法玩家/forced 测试。
- [ ] 运行目标测试并确认因 SelectChain 尚不存在而失败。
- [ ] 实现严格解析；保留无候选可选窗口的 AutoPassChain。
- [ ] 写发动索引、非强制跳过、强制拒绝跳过和未知索引响应测试。
- [ ] 实现两个纯响应构建器并运行解析器/响应测试。
- [ ] 以 `feat(规则): 解析并编码连锁候选` 提交。

### Task 2: Session、Retry 与对手策略

**Files:**
- Modify: `native/include/ygo/duel_session.hpp`
- Modify: `native/src/duel_session.cpp`
- Modify: `native/src/ygo_core_bridge.cpp`
- Test: `native/tests/test_duel_session.cpp`

**Interfaces:**
- Produces: `submit_chain(std::size_t)`、`pass_chain()`。
- Consumes: Task 1 的 ChainOption 与响应构建器。

- [ ] 写本地合法/非法提交、强制跳过拒绝、完整 Retry 恢复测试。
- [ ] 写对手可选窗口跳过、强制窗口选择第一个候选的确定性策略测试。
- [ ] 运行 `test_duel_session` 并确认红灯。
- [ ] 实现 Session 方法，并让自动对手只调用语义接口。
- [ ] 确保 `advance_to_local_decision` 遇到本地 SelectChain 停止推进。
- [ ] 运行 Session 测试与完整 CTest。
- [ ] 以 `feat(规则): 推进真实连锁决策` 提交。

### Task 3: GDExtension 语义桥接

**Files:**
- Modify: `native/include/ygo/ygo_core_bridge.hpp`
- Modify: `native/src/pending_action_godot_adapter.cpp`
- Modify: `native/src/ygo_core_bridge.cpp`
- Test: `native/tests/test_pending_action_godot_adapter.cpp`

**Interfaces:**
- Produces: Godot 字典 `chain_forced`、`chain_options`；
  `submit_chain(index: int)`、`pass_chain()`。

- [ ] 写字典字段、隐藏对手里侧身份、负索引和方法绑定契约测试。
- [ ] 运行 adapter 测试并确认红灯。
- [ ] 实现字典转换、Bridge 门禁和 ClassDB 绑定。
- [ ] 运行 adapter 测试、CTest 和缺扩展负向契约。
- [ ] 以 `feat(桥接): 暴露连锁候选语义` 提交。

### Task 4: Godot 情境式连锁交互

**Files:**
- Modify: `src/main/main.gd`
- Modify: `src/duel/duel_board.gd`
- Modify: `src/ui/hand_view.gd`
- Modify: `src/ui/zone_view.gd`
- Create: `tests/ui/test_chain_selection_flow.gd`

**Interfaces:**
- Produces: `chain_requested(index, generation)`、`chain_pass_requested(generation)`。
- Consumes: Task 3 的 chain_options、chain_forced 与 Bridge 方法。

- [ ] 用入树 Main、DuelBoard 和 FakeBridge 写手牌/场区高亮与点击测试。
- [ ] 覆盖同卡多效果按钮、不连锁、强制门禁和不可完整映射整组拒绝。
- [ ] 覆盖 Bridge 失败、MSG_RETRY、旧卡/旧按钮重入、终局和重开清理。
- [ ] 运行新测试并确认红灯。
- [ ] 实现按 controller/location/sequence 的完整映射、独立高亮和情境按钮。
- [ ] Main 在提交锁与决策代次校验后调用语义 Bridge，拒绝时恢复当前入口。
- [ ] 运行新测试及现有情境、攻击、位置测试。
- [ ] 以 `feat(界面): 增加连锁候选情境交互` 提交。

### Task 5: 真实核心与多分辨率验收

**Files:**
- Modify: `native/tests/test_duel_session.cpp`
- Modify: `tests/ui/test_responsive_duel_layout.gd`
- Modify: `tests/ui/test_chain_selection_flow.gd`

**Interfaces:**
- Consumes: 完整连锁语义与 Godot UI。

- [ ] 构造固定卡组/种子，真实触发本地有候选 SelectChain。
- [ ] 断言发动或跳过后 pending 与场面继续推进，重复点击只提交一次。
- [ ] 在三种逻辑分辨率验证候选按钮、安全区和手牌不碰撞。
- [ ] 运行 `./scripts/build_native.sh`、五组既有 Godot 测试和新连锁测试。
- [ ] 运行 Godot headless 启动。
- [ ] 用 Godot MCP 点击真实候选卡、发动/不连锁按钮并验证状态回传。
- [ ] 清理 MCP Autoload、脚本和 UID，执行 `git diff --check`。
- [ ] 独立复审 Critical/Important 为零后，以中文 Conventional Commit 修复残留。
- [ ] 推送 `main`。
