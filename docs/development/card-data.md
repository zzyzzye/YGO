# 卡片数据与规则脚本

当前数据层只接纳同时满足以下条件的卡片：

1. `data/cards.json` 中存在格式有效的记录；
2. 记录的 `id` 能转换为 32 位无符号整数；
3. `images/<id>.webp` 卡图真实存在。

这意味着运行时卡库是 JSON 与卡图的交集。单独存在于 JSON 中但缺少卡图的记录不会进入
数据库，只有卡图但没有 JSON 记录的文件也不会凭空生成卡片。当前素材集的完整验证结果为
14,110 张有效卡片、42 条无效 JSON 记录和 96 条缺图记录。

## 字段对应关系

- `id` 是卡片数据库、卡图文件和 `official/c<id>.lua` 的共同主键，也是传给 OCGCore
  的 `code`。
- `cid` 只保留为上游来源元数据，不参与卡片查找，也不用于匹配图片或 Lua。
- `cn_name` 是界面固定使用的中文展示名；`md_name`、`sc_name` 等字段不会覆盖它。
- 卡图在数据库中保存为 `images/<id>.webp`，Godot 桥接层查询时转换为
  `res://images/<id>.webp`。
- 普通怪兽的 `def` 对应 OCGCore 防御力；连接怪兽的同一来源字段对应连接标记，
  防御力固定为 0。
- 来源数据打包在 `level` 高位的左右灵摆刻度会拆成 OCGCore 所需的独立字段。
- `setcode` 按低位到高位拆成 16 位数组，并由适配器追加 OCGCore 要求的结尾 0。

## 二进制缓存

开发缓存固定保存在 `.cache/cards/card_database.bin`，属于可重建文件，不提交 Git。
缓存采用固定小端格式，不写入指针、JSON 节点或文件句柄。它同时记录：

- 缓存格式版本；
- `cards.json` 内容指纹；
- 排序后的 `.webp` 文件名与大小指纹；
- 有效、无效和缺图记录统计。

JSON 内容、卡图文件名或卡图大小发生变化后，下次启动会自动重建缓存。缓存损坏、版本不匹配
或读取越界同样会回退到 JSON 解析，并使用同目录临时文件完成原子替换。需要手动强制重建时，
关闭正在运行的游戏后删除 `.cache/cards/card_database.bin` 即可；原始 JSON 和卡图不会受影响。

## Lua 规则目录

规则加载器只允许读取 `third_party/CardScripts` 根目录的基础 `.lua` 文件，以及
`third_party/CardScripts/official/c<数字>.lua`。首版明确拒绝路径穿越、子目录伪装、
非数字卡片脚本和其他规则目录。

初始化时会先检查 `constant.lua` 与 `utility.lua`。常见中文诊断含义如下：

- `项目根目录无效`：Godot 传入的项目路径不存在或不是目录。
- 卡片 JSON、卡图或缓存相关错误：检查 `data/cards.json`、`images/` 的完整性及目录写权限。
- 正式脚本目录或基础脚本错误：执行 `git submodule update --init --recursive`，并确认
  `third_party/CardScripts` 没有被移动。
- `未找到卡片：<id>`：该编号不存在，或因 JSON 无效、缺少同编号卡图而未进入交集数据库。
