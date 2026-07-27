# Fullscreen Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将决斗原型升级为默认原生全屏、以 1920×1080 为设计基准且可继续适配 4K 的响应式界面。

**Architecture:** Godot 项目配置负责全屏和设计 viewport，现有 Control 容器负责按可用空间布局。退出动作通过 DuelBoard 信号交给主场景，保持界面与应用生命周期解耦。

**Tech Stack:** Godot 4.6、GDScript、Godot MCP、现有 C++ GDExtension。

## Global Constraints

- 项目设计 viewport 固定为 `1920×1080`。
- 默认使用当前显示器原生分辨率全屏。
- 自有代码注释和用户可见文字使用简体中文。
- 不修改 `third_party/` 或 MCP 临时注入文件。

---

### Task 1: 全屏与设计分辨率

**Files:**
- Modify: `project.godot`

**Interfaces:**
- Consumes: Godot `display/window` 项目设置。
- Produces: 默认全屏的 `1920×1080` 设计 viewport。

- [ ] **Step 1: 记录当前配置检查**

运行 `rg -n "viewport_width|viewport_height|window/size/mode" project.godot`，
确认当前仍为 `1280×720` 且没有全屏模式。

- [ ] **Step 2: 修改项目设置**

将 viewport 改为 `1920×1080`，并设置
`window/size/mode=3`（独占全屏）。

- [ ] **Step 3: 验证配置**

再次运行相同 `rg` 命令，预期三个设置均存在且数值正确。

### Task 2: 1080P 响应式布局与退出入口

**Files:**
- Modify: `src/duel/duel_board.gd`
- Modify: `src/main/main.gd`

**Interfaces:**
- Produces: `exit_requested` 信号。
- Consumes: 主场景 `_on_exit_requested()` 回调。

- [ ] **Step 1: 增加退出信号和按钮**

在 `DuelBoard` 声明 `exit_requested`，右侧操作栏增加“退出游戏”按钮并连接
该信号；主场景连接信号并调用 `get_tree().quit()`。

- [ ] **Step 2: 调整 1080P 尺寸**

扩大三栏宽度、主场区、详情卡图、手牌与场区卡片最小尺寸；继续使用容器、
全屏锚点和扩展填充，不增加屏幕绝对坐标依赖。

- [ ] **Step 3: Godot 语法验证**

运行 Godot 无头启动三帧，预期退出码为 0 且无项目脚本错误。

### Task 3: MCP 画面和交互验收

**Files:**
- Verify: `project.godot`
- Verify: `src/duel/duel_board.gd`
- Verify: `src/main/main.gd`

**Interfaces:**
- Consumes: Godot MCP 启动、截图、UI 查询和日志。
- Produces: 1920×1080 视觉验收证据。

- [ ] **Step 1: 以窗口覆盖模式启动**

使用 Godot MCP 启动项目，并将验收窗口固定为 `1920×1080`，避免全屏遮挡开发环境。

- [ ] **Step 2: 截图与节点检查**

截图必须为 `1920×1080`，五张手牌、双方区域、详情栏、操作栏和“退出游戏”
按钮完整可见且不重叠。

- [ ] **Step 3: 完整回归**

运行 `./scripts/build_native.sh`、Godot 无头启动及 `git diff --check`；
预期 8/8 原生测试通过、Godot 退出码为 0、差异检查无输出。
