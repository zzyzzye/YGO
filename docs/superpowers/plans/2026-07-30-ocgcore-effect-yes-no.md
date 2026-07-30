# OCGCore 情境式效果确认 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让本地玩家和自动对手通过独立语义接口安全处理 `MSG_SELECT_EFFECTYN`。

**Architecture:** C++ 严格解析效果来源卡和描述，Session 独立编码 0/1 响应并
恢复 Retry，Bridge 发布纯值字典；Godot 复用原生确认浮层，只负责展示语义快照
和提交布尔意图。

**Tech Stack:** C++20、OCGCore 11、Godot 4.6 GDExtension、GDScript、CTest、
Godot MCP。

## Global Constraints

- 所有项目文件必须保存在 `/Volumes/WD/YGO`。
- 新增自有代码需包含准确中文注释，项目日志与用户诊断使用简体中文。
- 原始消息解析、响应编码、不可信输入校验和自动对手策略属于 C++。
- Godot 只能提交稳定语义参数，并由新快照更新画面。
- 每项行为先验证失败测试，再实现最小代码。

---

### Task 1: 严格解析并编码 EffectYesNo

**Files:**
- Modify: `native/include/ygo/duel_message_parser.hpp`
- Modify: `native/src/duel_message_parser.cpp`
- Modify: `native/include/ygo/duel_response.hpp`
- Modify: `native/src/duel_response.cpp`
- Modify: `native/tests/test_duel_message_parser.cpp`
- Modify: `native/tests/test_duel_response.cpp`

**Interfaces:**
- Produces: `PendingActionKind::EffectYesNo`、效果来源字段及
  `build_effect_yes_no_response(const PendingAction &, bool)`。

- [ ] 写合法、截断、尾随和非法字段解析失败测试并确认 RED。
- [ ] 实现固定 24 字节解析，运行 parser 测试确认 GREEN。
- [ ] 写独立 0/1 响应测试并确认 RED。
- [ ] 实现 EffectYesNo 专用响应构造器，运行 response 测试确认 GREEN。

### Task 2: Session、自动对手与 Bridge 语义

**Files:**
- Modify: `native/include/ygo/duel_session.hpp`
- Modify: `native/src/duel_session.cpp`
- Modify: `native/include/ygo/ygo_core_bridge.hpp`
- Modify: `native/src/ygo_core_bridge.cpp`
- Modify: `native/src/pending_action_godot_adapter.cpp`
- Modify: `native/tests/test_duel_session.cpp`
- Modify: `native/tests/test_pending_action_godot_adapter.cpp`

**Interfaces:**
- Consumes: Task 1 的 EffectYesNo 快照和响应构造器。
- Produces: `submit_effect_yes_no(bool)`、确定性对手“不发动”策略和
  `kind="effect_yes_no"` Bridge 字典。

- [ ] 写 Session、纯自动策略、字典和 ClassDB 绑定失败测试。
- [ ] 实现 Session 提交和自动推进分支。
- [ ] 实现 Bridge 独立门禁、字典字段与方法绑定。
- [ ] 运行全部原生测试，确认无普通 YesNo 回归。

### Task 3: Godot 情境式效果确认

**Files:**
- Modify: `src/duel/duel_board.gd`
- Modify: `src/main/main.gd`
- Modify: `tests/ui/test_contextual_duel_layout.gd`
- Modify: `tests/ui/test_attack_target_flow.gd`
- Modify: `tests/ui/test_responsive_duel_layout.gd`
- Create: `tests/ui/test_effect_yes_no_flow.gd`

**Interfaces:**
- Consumes: Bridge 的 EffectYesNo 字典与 `submit_effect_yes_no(bool)`。
- Produces: “发动/不发动”确认、独立提交锁、Retry 文案和响应式契约。

- [ ] 写确认内容、普通 YesNo 隔离、失败、Retry、双击、旧代次、重开和退出测试。
- [ ] 确认测试因缺少 EffectYesNo UI 失败。
- [ ] 复用原生确认浮层实现效果确认，不动态拼装新稳定场景结构。
- [ ] Main 接入独立 Bridge 方法并验证所有 UI 测试通过。

### Task 4: 真实核心、响应式与 MCP 验收

**Files:**
- Modify: `native/tests/test_duel_session.cpp`
- Modify: `tests/ui/test_responsive_duel_layout.gd`
- Modify: `tests/ui/test_effect_yes_no_flow.gd`

**Interfaces:**
- Consumes: Tasks 1–3 的完整链路。
- Produces: 可重复的真实核心证据、三分辨率契约和 MCP 实机结果。

- [ ] 从现有卡库与脚本筛选能稳定产生 EffectYesNo 的固定卡与种子。
- [ ] 若可稳定触发，验证发动/不发动后核心推进；否则记录可复现探索结果，不制造
  错位响应，并以解析、响应、Session、Bridge、Godot 分层测试覆盖。
- [ ] 运行 `./scripts/build_native.sh` 和全部 Godot UI 测试。
- [ ] 用 Godot MCP 检查主路径、取消/非法路径、状态回传和布局，停止项目并清理。
- [ ] 审阅差异，使用中文 Conventional Commit 提交并推送 `main`。
