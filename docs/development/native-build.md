# 原生模块构建

项目通过 Godot 4.6 GDExtension 向 GDScript 暴露真实 `ygopro-core` 决斗生命周期、
卡片数据库与 ProjectIgnis Lua 规则加载器。

## 环境要求

- Apple Silicon Mac；
- `/Applications/Godot.app` 中安装 Godot 4.6.x；
- CMake 3.24 或更高版本；
- Apple Clang 工具链。

## 初始化依赖

克隆仓库后初始化全部锁定的子模块，包括 `ygopro-core` 内嵌的 Lua：

```bash
git submodule update --init --recursive
```

`third_party/godot-cpp` 固定在兼容 Godot 4.6 的提交。除非同时升级项目与本机 Godot，
否则不要把它切换到 `master`。依赖版本和许可证见 `LICENSES/THIRD_PARTY.md`。

## 构建与测试

在仓库根目录执行：

```bash
./scripts/build_native.sh
```

脚本会在 `build/native` 配置 Debug 构建，编译 C++ 数据层、OCGCore 包装和 GDExtension，
随后运行全部原生测试。生成的动态库为：

```text
bin/macos/libygo_core.dylib
```

需要对本机完整素材做严格集成验证时，显式提供资源目录：

```bash
YGO_TEST_ASSET_ROOT="$PWD" \
YGO_TEST_SCRIPT_ROOT="$PWD/third_party/CardScripts" \
ctest --test-dir build/native --output-on-failure
```

未提供这两个环境变量时，依赖大型本地素材的用例会跳过，轻量单元测试仍正常运行。

## 启动 Godot

用 Godot 打开 `project.godot`，或执行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path "$PWD"
```

诊断界面应显示 Godot 与 OCGCore 版本、正式卡片数量、缓存状态、青眼白龙查询结果和
Lua 规则连接状态。

无头冒烟测试：

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless \
  --path "$PWD" \
  --quit-after 2
```

## 本地素材与缓存

大型卡片数据、卡图、工具和缓存保留在项目目录内，但由 Git 忽略：

- `data/cards.json`
- `images/`
- `.cache/`
- `vendor/`
- `tools/`

对应目录的 `.gdignore` 标记会阻止 Godot 导入或扫描大型源数据。卡片字段、交集规则、
缓存失效方式和 Lua 白名单详见 `docs/development/card-data.md`。
