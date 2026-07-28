# OCGCore 表示形式选择实施计划

1. 为解析器与响应构建器先写失败测试，锁定 7 字节帧、离散候选和小端
   `int32` 响应。
2. 增加 SelectPosition 数据模型、严格解析、响应构建和 Session 语义提交，
   补齐 `MSG_RETRY` 恢复测试。
3. 扩展 Godot adapter 与 Bridge 字典/方法，并用契约测试防止字段或绑定遗漏。
4. 扩展 Main 与 DuelBoard 原生确认面板，按真实候选显示四种中文表示形式，
   对成功、失败、Retry、重复点击和决策切换建立门禁。
5. 增加真实 OCGCore 通常召唤流程和三种分辨率布局验收。
6. 运行原生 CTest、全部 Godot UI 测试、headless 启动和 Godot MCP 实机点击；
   独立复审无高优先级问题后提交并推送 main。
