# Godot 原生决斗界面迁移设计

## 背景与目标

当前决斗原型已经能够通过 `YgoCoreBridge` 驱动真实 OCGCore 数据、召唤、
阶段切换、直接攻击、生命值和连续回合，但 `DuelBoard`、`HandView`、
`ZoneView` 和 `CardView` 的固定节点与大部分视觉属性仍由 GDScript 在运行时
创建。这种结构便于验证早期规则链路，却让 Godot 编辑器无法直接预览和调整
场景树、主题、动画与响应式布局，也会放大后续 4K 适配和战斗表现的维护成本。

本次迁移的目标是：

1. 将稳定的可视结构迁移到 Godot 原生 `.tscn` 场景。
2. 将共享视觉参数迁移到 `.tres` Theme 与 StyleBox 资源。
3. 保持现有 C++/GDExtension 规则接口和 `render_snapshot()` 快照契约不变。
4. 让 GDScript 只负责绑定快照、实例化数据驱动子场景、编排轻量表现和转发信号。
5. 用同一套布局支持原生全屏、1920×1080、3840×2160 和常见宽高比。
6. 为后续“点击怪兽选择攻击目标、点击对手 LP 面板进行直接攻击”提供原生节点、
   高亮状态和动画挂点。

## 方案选择

采用渐进式场景化，而不是一次性重写或只抽取主题。

- 一次性重写会同时改变场景结构、行为和规则交互，难以定位回归。
- 只抽取 Theme 仍会让固定场景树隐藏在脚本中，无法解决编辑器预览、动画挂点和
  MCP 场景操作问题。
- 渐进式场景化先保证行为等价，再增加视觉表现；每个阶段都能单独测试、审查和
  回退。

## 职责边界

### C++/GDExtension

以下职责继续由 C++ 层独占：

- 卡片数据库、脚本加载和 OCGCore 生命周期。
- OCGCore 消息解析、候选动作验证和响应编码。
- 生命值、区域卡片、胜负与当前决策状态。
- 对 Godot 暴露稳定、经过验证的语义 Dictionary/Array。

Godot 不得拼装原始 OCGCore 响应，也不得在提交动作前本地改变生命值、卡牌位置、
区域归属或胜负状态。

### Main

`src/main/main.gd` 继续作为规则状态与界面之间的协调器：

- 创建并持有 `YgoCoreBridge`。
- 从 Bridge 读取公开决斗状态和当前合法动作。
- 将两者转换成 `DuelBoard.render_snapshot(snapshot)` 所需快照。
- 接收场景信号，调用 Bridge 语义接口，并在成功后重新读取完整快照。

`Main` 不再通过 `DUEL_BOARD_SCRIPT.new()` 创建界面。`src/main/main.tscn`
直接实例化 `duel_board.tscn`，`main.gd` 使用 `%DuelBoard` 获取节点并连接信号。

### Godot 场景与脚本

Godot 层负责：

- 显示 C++ 返回的公开快照。
- 只为当前合法候选动作创建情境按钮或目标状态。
- 使用原生容器、主题、动画和输入系统表达视觉与交互。
- 将玩家选择转换为候选索引或稳定语义参数并发回 Main。

固定节点必须存在于 `.tscn`；只有手牌卡片、区域内卡片和数量不固定的候选按钮
可以运行时实例化，而且必须优先实例化预制子场景。

## 场景与资源结构

### `src/main/main.tscn`

- 根节点 `Main: Control` 保持全屏锚点。
- 新增 `DuelBoard`，实例化 `res://src/duel/duel_board.tscn`。
- `DuelBoard` 设置 `unique_name_in_owner = true`，供 `main.gd` 通过
  `%DuelBoard` 获取。

### `src/duel/duel_board.tscn`

根节点 `DuelBoard: Control` 使用全屏锚点并挂载 `duel_board.gd`。固定子树为：

```text
DuelBoard
├── Background
├── SafeArea
│   ├── Battlefield
│   │   ├── OpponentHand
│   │   ├── OpponentSpellRow
│   │   ├── OpponentMonsterRow
│   │   ├── TurnDivider
│   │   ├── TurnLabel
│   │   ├── PlayerMonsterRow
│   │   ├── PlayerSpellRow
│   │   └── PlayerHand
│   ├── OpponentStatus
│   ├── PlayerStatus
│   ├── PhaseButton
│   ├── SystemTools
│   └── StatusToast
├── CardDetailOverlay
├── ContextActionBar
├── ConfirmationOverlay
├── DebugOverlay
└── AnimationPlayer
```

`SafeArea` 负责屏幕边缘安全间距。`Battlefield` 使用容器完成纵向布局；左右信息面板
通过锚点和最小尺寸约束，不依赖开发机的绝对像素位置。

四行区域分别包含五个 `zone_view.tscn` 实例。对手行在场景中按视觉顺序排列，
脚本保留 OCGCore `sequence` 到节点的显式映射，不能依赖显示顺序猜测。

所有需要被脚本访问的固定节点使用唯一名称。`duel_board.gd` 在 `_ready()` 中只
缓存节点引用、校验必需节点并连接运行时信号，不再调用 `_build_interface()`。

### `src/ui/card_view.tscn`

根节点保留 `CardView: TextureButton`，挂载 `card_view.gd`，并包含：

- `SelectionFrame: Panel`：通过 Theme 状态显示选中边框。
- `FaceDownLabel: Label`：黑白原型的卡背占位文字。
- `AnimationPlayer`：提供 `hover_in`、`hover_out`、`select` 和 `reset` 动画。

脚本负责加载运行时卡图和设置卡片数据。选中、悬浮和卡背视觉由子节点、Theme 与
AnimationPlayer 表达，不再依赖 `_draw()` 手绘整张卡片。

### `src/ui/zone_view.tscn`

根节点保留 `ZoneView: PanelContainer`，挂载 `zone_view.gd`，并包含：

- `CardContainer: CenterContainer`
- `TitleLabel: Label`
- `TargetHighlight: Panel`
- `AnimationPlayer`

`TargetHighlight` 默认隐藏，为后续攻击目标和规则候选提供明确挂点。区域内卡片通过
实例化 `card_view.tscn` 创建。

### `src/ui/hand_view.tscn`

根节点保留 `HandView: HBoxContainer`，挂载 `hand_view.gd`。手牌数量由规则数据
决定，因此卡片仍动态创建，但创建对象必须来自 `card_view.tscn` 的 `PackedScene`。

### `src/ui/themes/duel_theme.tres`

Theme 统一承载：

- Label、Button、PanelContainer 的基础字体尺寸和颜色。
- 圆形阶段按钮、系统按钮、卡片边框、区域边框和浮层背景的 StyleBox。
- 常用容器间距和控件状态。

场景可保留少量只属于单个节点的最小尺寸与布局约束；重复出现的视觉值不得继续分散
在脚本中。

## 快照与交互数据流

数据流保持单向：

```text
OCGCore
  → C++ DuelSession / YgoCoreBridge
  → Main 生成公开快照
  → DuelBoard.render_snapshot()
  → 原生子场景渲染
  → 玩家点击节点
  → Godot 信号携带候选类型和索引
  → Main 调用 Bridge
  → OCGCore 返回新快照
```

场景迁移阶段不得改变现有快照字段名称和动作语义。`idle_actions` 暂时保留现有字段名，
其中也可能包含战斗动作；后续攻击目标功能可以在独立提交中将其重命名为更通用的
`actions`，但必须同步迁移测试与调用方。

## 响应式布局

项目继续以 1920×1080 为逻辑视口，`canvas_items` Stretch 负责基础缩放。原生场景
还必须满足：

- 1920×1080：动作条不覆盖玩家手牌，状态提示不覆盖对手手牌。
- 3840×2160：节点由锚点和容器扩展，不出现只占左上角或绝对坐标漂移。
- 常见 16:10 或超宽窗口：中央战场保持可用，左右浮层不侵入五列区域。
- 卡片和区域使用最小尺寸保障可读性；空间不足时优先压缩间距，不能让关键按钮离开
  视口。
- 退出按钮在全屏和窗口模式下始终位于安全区域内。

布局测试应读取真实节点的全局矩形，而不是只检查配置文本。

## 动画与表现

第一阶段只迁移已有表现并保留黑白原型，不引入最终美术素材。迁移完成后：

- CardView 悬浮使用 AnimationPlayer 做轻微上移或缩放。
- 选中使用 Theme 边框和短动画，不改变规则数据。
- ZoneView 预留 `set_targetable(bool)` 和 `set_target_selected(bool)` 的表现接口。
- DuelBoard 预留攻击指示层；后续可用 Tween 或 Line2D 从攻击者指向目标。
- 状态刷新动画只能响应 Bridge 新快照，不能先播放“成功结果”来伪造规则处理。

## 错误与生命周期

- 缺少必需唯一节点时，脚本使用中文断言或错误提示立即失败，不能悄悄创建替代节点。
- PackedScene 加载失败时，不创建裸节点兜底；显示中文诊断并让测试失败。
- 外部卡图加载失败时允许使用场景内黑白占位视觉，不影响规则流程。
- 新快照到达时必须关闭旧确认框、清除旧动作按钮和卡牌选择，防止过期候选被提交。
- Main 退出树时继续销毁活动 DuelSession。
- MCP 验收结束必须停止项目并清除临时 Autoload 与交互服务器脚本。

## 迁移阶段

### 阶段一：子场景与主题

创建 CardView、ZoneView、HandView 的 `.tscn` 以及 `duel_theme.tres`，将对应脚本从
创建固定子节点改为缓存场景节点。保持现有公开信号与方法不变。

### 阶段二：DuelBoard 场景

创建 `duel_board.tscn`，迁移所有固定节点、锚点、容器和信号。删除
`_build_interface()` 及固定节点工厂函数，保留快照、选择、确认和动作逻辑。

### 阶段三：Main 集成与响应式验证

让 `main.tscn` 直接实例化 DuelBoard；调整测试加载真实 PackedScene。补充 1080p、
4K 和不同宽高比的节点矩形契约，并通过 Godot MCP 实际切换窗口尺寸检查。

### 阶段四：攻击目标交互

在场景化基础上解析 OCGCore 的 `MSG_SELECT_YESNO` 与 `MSG_SELECT_CARD`，用
ZoneView 目标高亮和对手 LP 面板点击完成真实目标选择。直击和怪兽目标都必须由
OCGCore 候选驱动，不能由前端根据场面自行推断。

## 自动化验证

迁移必须保留并扩展以下证据：

1. GDScript 场景契约测试加载 `.tscn`，验证必需节点、信号和默认可见性。
2. CardView、HandView、ZoneView 测试验证预制场景实例化、选择与悬浮信号。
3. 现有真实 Bridge 集成继续验证连续回合、LP 和合法动作门禁。
4. 1920×1080 与 3840×2160 测试检查控件矩形、重叠和安全边距。
5. `./scripts/build_native.sh` 保持 8 项原生 CTest 全部通过。
6. Godot 无界面启动不得出现项目自有错误或警告。

## Godot MCP 验收

每个场景迁移阶段都必须使用 Godot MCP：

1. 读取 `.tscn` 场景树，确认固定节点确实存在于场景而非运行时代码。
2. 启动项目并读取关键节点属性，确认 Theme、容器布局和唯一节点引用生效。
3. 在 1920×1080 和 3840×2160 下检查战场、手牌、动作条、状态栏和退出按钮。
4. 操作卡片悬浮、点击、再次点击取消、点击空白取消和阶段确认框取消。
5. 运行一次真实召唤、进入战斗阶段和攻击流程，确认 C++ 状态仍回传到原生场景。
6. 停止项目，检查并清理 MCP 注入文件，再运行 `git diff --check`。

## 完成标准

只有同时满足以下条件，原生场景迁移才算完成：

- 固定界面结构不再由 GDScript 动态创建。
- CardView、ZoneView、HandView 和 DuelBoard 均有可在 Godot 编辑器中打开的
  `.tscn`。
- 共享视觉规则来自 `.tres` Theme/StyleBox 资源。
- 现有真实 OCGCore 流程和公开 Godot 接口没有回归。
- 自动化测试覆盖场景结构、交互与 1080p/4K 布局。
- Godot MCP 已在两种分辨率完成真实交互验收。
- 工作区不包含 MCP 临时 Autoload 或交互脚本。

## 非目标

- 本次迁移不制作最终场地图、角色立绘、粒子素材或商业级卡牌动画。
- 本次迁移不重写 OCGCore、卡片数据库或 Bridge 协议。
- 本次迁移不同时实现完整连锁、效果目标、祭品选择等所有交互消息。
- 本次迁移不引入新的第三方 UI 框架。
