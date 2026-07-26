# 卡片数据库与正式卡脚本加载实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 C++ 中建立只包含有效卡片与卡图交集的卡片数据库、可校验的项目内二进制缓存和安全的正式卡 Lua 加载器，并让 Godot 与真实 OCGCore 决斗共用该数据层。

**Architecture:** `CardDatabase` 负责 JSON 到稳定运行时记录的转换，`CardCache` 负责无指针二进制序列化，`CardRepository` 负责数据源指纹与缓存命中/重建，`OfficialScriptLoader` 负责基础脚本和 `official/c<id>.lua` 的安全加载。`DuelSession` 通过共享所有权保证数据库和脚本加载器覆盖 OCGCore 句柄生命周期，`YgoCoreBridge` 只向 Godot 暴露初始化状态、展示查询和真实决斗创建。

**Tech Stack:** Godot 4.6.3、C++17、CMake 3.24+、godot-cpp 4.6-stable、ygopro-core 11.0、ProjectIgnis CardScripts、nlohmann/json、CTest。

## Global Constraints

- 仅支持 macOS Apple Silicon 和 Godot 4.6.x；不得把项目文件写到 `/Volumes/WD/YGO` 之外。
- 开发缓存固定为 `/Volumes/WD/YGO/.cache/cards/card_database.bin`，并继续由现有 `.gitignore` 的 `.cache/` 规则忽略。
- 首版 Lua 只使用 `third_party/CardScripts` 根目录基础脚本和 `third_party/CardScripts/official/`，不得读取其他规则目录。
- 缓存数据库主键固定使用 JSON 记录内的 `id`；`cid` 仅作为来源信息保留。
- 展示名称固定使用 `cn_name`，不得使用 `md_name`、`sc_name` 等字段覆盖。
- 当前完整素材集应得到 14,110 张交集卡、42 条无效记录和 96 张缺图卡；数量只能作为集成测试期望，不能写死为运行逻辑。
- 项目自有打印、日志、警告、错误、断言说明和诊断文字必须使用简体中文。
- 新增核心接口、字段拆解、内存所有权、安全边界和异常路径必须有详细中文注释。
- 每个 Git 提交使用规范化中文标题和详细中文正文，说明原因、关键修改和验证方式。
- 不修改 `third_party/` 内的第三方源码；新增依赖必须作为锁定提交的子模块保存在项目内，并补充许可证说明。

---

## 文件结构

本计划新增或修改的自有文件职责如下：

```text
native/include/ygo/card_record.hpp
    稳定的卡片展示字段和 OCGCore 字段值；不包含文件格式或 Godot 类型。

native/include/ygo/card_database.hpp
native/src/card_database.cpp
    解析 JSON、检查卡图交集、建立 id 索引、查询记录和生成统计。

native/include/ygo/card_cache.hpp
native/src/card_cache.cpp
    定义缓存头、源指纹、二进制读写和损坏检测。

native/include/ygo/card_repository.hpp
native/src/card_repository.cpp
    组合源数据、缓存和项目路径，决定命中或安全重建。

native/include/ygo/official_script_loader.hpp
native/src/official_script_loader.cpp
    规范化 OCGCore 脚本名、限制允许目录、读取脚本并调用 OCG_LoadScript。

native/include/ygo/ocg_card_data_adapter.hpp
native/src/ocg_card_data_adapter.cpp
    把 CardRecord 转换为 OCG_CardData，并管理 setcodes 终止数组的生命周期。

native/include/ygo/duel_session.hpp
native/src/duel_session.cpp
    使用真实 CardDatabase 和 OfficialScriptLoader 回调管理 OCGCore 句柄。

native/include/ygo/ygo_core_bridge.hpp
native/src/ygo_core_bridge.cpp
    把卡库初始化、状态和展示查询转换为 Godot Dictionary。

native/tests/test_card_database.cpp
native/tests/test_card_cache.cpp
native/tests/test_card_repository.cpp
native/tests/test_official_script_loader.cpp
native/tests/test_duel_session.cpp
    分别覆盖解析、缓存、编排、脚本安全和 OCGCore 集成。

native/tests/test_support.hpp
    测试临时目录、文本/占位图片写入和断言辅助函数。

src/main/main.gd
src/main/main.tscn
    展示真实数据库、缓存、测试卡片和 Lua 连接状态。
```

---

### Task 1: 固定 JSON 依赖并定义卡片记录

**Files:**
- Modify: `.gitmodules`
- Modify: `LICENSES/THIRD_PARTY.md`
- Modify: `native/CMakeLists.txt`
- Create: `native/include/ygo/card_record.hpp`
- Create: `native/tests/test_card_record.cpp`
- Create: `native/tests/test_support.hpp`
- Add submodule: `third_party/json`

**Interfaces:**
- Consumes: `cards.json` 中的 `id`、`cid`、`cn_name`、`text` 和 `data` 字段。
- Produces: `ygo::CardRecord`、`ygo::CardRuleData`、`ygo::CardDisplayData`，供所有后续任务使用。

- [ ] **Step 1: 添加锁定版本的 nlohmann/json 子模块**

运行：

```bash
git submodule add https://github.com/nlohmann/json.git third_party/json
git -C third_party/json checkout --detach v3.12.0
find .git third_party/json -type f -name '._*' -delete
```

确认：

```bash
git -C third_party/json rev-parse HEAD
git submodule status third_party/json
```

预期：子模块处于 `v3.12.0` 对应的固定提交，不跟随分支漂移。

- [ ] **Step 2: 写入会失败的记录模型测试**

在 `native/tests/test_card_record.cpp` 中先写：

```cpp
#include "ygo/card_record.hpp"

#include <cassert>

int main() {
	ygo::CardRecord record;
	record.display.cid = 4007;
	record.display.cn_name = "青眼白龙";
	record.rule.code = 89631139;
	record.rule.attack = 3000;
	record.rule.setcodes = {0x10f3};

	assert(record.display.cid == 4007);
	assert(record.display.cn_name == "青眼白龙");
	assert(record.rule.code == 89631139);
	assert(record.rule.setcodes.front() == 0x10f3);
}
```

- [ ] **Step 3: 运行测试确认因接口不存在而失败**

运行：

```bash
cmake -S native -B build/native -DCMAKE_BUILD_TYPE=Debug
cmake --build build/native --target test_card_record -j4
```

预期：编译失败，明确提示 `ygo/card_record.hpp` 或 `CardRecord` 尚不存在。

- [ ] **Step 4: 定义不依赖 Godot 的稳定记录类型**

在 `native/include/ygo/card_record.hpp` 定义：

```cpp
namespace ygo {

struct CardDisplayData {
	std::uint32_t cid = 0;
	std::string cn_name;
	std::string types_text;
	std::string pendulum_description;
	std::string description;
	std::string image_relative_path;
};

struct CardRuleData {
	std::uint32_t code = 0;
	std::uint32_t alias = 0;
	std::uint32_t type = 0;
	std::uint32_t level = 0;
	std::uint32_t attribute = 0;
	std::uint64_t race = 0;
	std::int32_t attack = 0;
	std::int32_t defense = 0;
	std::uint32_t left_scale = 0;
	std::uint32_t right_scale = 0;
	std::uint32_t link_marker = 0;
	std::vector<std::uint16_t> setcodes;
};

struct CardRecord {
	CardDisplayData display;
	CardRuleData rule;
};

} // namespace ygo
```

在类型上方用中文说明：这些类型只保存值，不保存 JSON 节点、文件句柄或 OCGCore 指针，因此可安全跨越缓存、数据库和决斗层。

- [ ] **Step 5: 把依赖和测试目标接入 CMake**

在 `native/CMakeLists.txt` 中：

```cmake
add_subdirectory(
	"${CMAKE_CURRENT_SOURCE_DIR}/../third_party/json"
	"${CMAKE_CURRENT_BINARY_DIR}/json"
	EXCLUDE_FROM_ALL
)

add_executable(test_card_record tests/test_card_record.cpp)
target_include_directories(test_card_record PRIVATE include)
add_test(NAME card_record COMMAND test_card_record)
```

同时在 `LICENSES/THIRD_PARTY.md` 记录 nlohmann/json、MIT 许可证、仓库 URL 和固定版本。

- [ ] **Step 6: 运行记录模型测试**

运行：

```bash
cmake -S native -B build/native -DCMAKE_BUILD_TYPE=Debug
cmake --build build/native --target test_card_record -j4
./build/native/test_card_record
```

预期：退出码 0；JSON 子模块和记录模型均可被现有 CMake 工程使用。

- [ ] **Step 7: 提交依赖与记录骨架**

```bash
git add .gitmodules third_party/json LICENSES/THIRD_PARTY.md \
  native/CMakeLists.txt native/include/ygo/card_record.hpp \
  native/tests/test_card_record.cpp
git commit \
  -m "build(卡片): 固定 JSON 解析依赖并定义记录模型" \
  -m "为 C++ 卡片数据库提供项目内可复现的 JSON 解析能力，并建立不依赖 Godot 或文件格式的稳定卡片值类型。" \
  -m "新增记录模型测试，固定中文展示字段、规则卡号和 setcode 容器的基本用法；同时补充第三方许可证记录。" \
  -m "验证：CMake 已识别新依赖和记录测试目标，test_card_record 构建并运行通过。"
```

---

### Task 2: 解析 JSON 并建立卡图交集数据库

**Files:**
- Create: `native/include/ygo/card_database.hpp`
- Create: `native/src/card_database.cpp`
- Create: `native/tests/test_card_database.cpp`
- Create: `native/tests/test_support.hpp`
- Modify: `native/CMakeLists.txt`

**Interfaces:**
- Consumes: `CardRecord`；`std::filesystem::path cards_json`；`std::filesystem::path images_dir`。
- Produces:
  - `static CardDatabaseLoadResult CardDatabase::load_json_intersection(const path &, const path &)`
  - `const CardRecord *CardDatabase::find(std::uint32_t id) const noexcept`
  - `std::size_t CardDatabase::size() const noexcept`
  - `const CardDatabaseStats &CardDatabase::stats() const noexcept`
  - `const std::map<std::uint32_t, CardRecord> &CardDatabase::records() const noexcept`
  - `static CardDatabaseBuildResult CardDatabase::from_records(std::vector<CardRecord>, CardDatabaseStats)`

- [ ] **Step 1: 创建失败测试，固定筛选与字段拆解**

在 `native/tests/test_card_database.cpp` 中使用 `TemporaryDirectory` 写入两张
有效卡、一条无效记录和以下缺图记录。`TemporaryDirectory` 必须在析构
时只删除它自己创建的系统临时子目录；中文注释说明所有权和清理边界。

测试主体先创建以下数据：

```cpp
ygo::test::TemporaryDirectory fixture;
fixture.write_text("cards.json", R"JSON({
  "4007": {
    "cid": 4007, "id": 89631139, "cn_name": "青眼白龙",
    "text": {"types": "[怪兽|通常]", "pdesc": "", "desc": "传说中的龙。"},
    "data": {"ot": 3, "setcode": 0, "type": 17, "atk": 3000, "def": 2500,
             "level": 8, "race": 8192, "attribute": 16}
  },
  "link": {
    "cid": 13085, "id": 41999284, "cn_name": "解码语者",
    "text": {"types": "[怪兽|效果|连接]", "pdesc": "", "desc": "测试文本"},
    "data": {"ot": 3, "setcode": 0, "type": 67108897, "atk": 2300, "def": 42,
             "level": 3, "race": 16777216, "attribute": 32}
  },
  "invalid": {"cid": 999, "id": 0, "cn_name": "无效记录", "data": {}},
  "missing_image": {
    "cid": 5000, "id": 12345678, "cn_name": "缺图测试卡",
    "text": {"types": "", "pdesc": "", "desc": ""},
    "data": {"ot": 3, "setcode": 1103806669639, "type": 16777249,
             "atk": -2, "def": 1000, "level": 84017156,
             "race": 1, "attribute": 4}
  }
})JSON");
fixture.touch("images/89631139.webp");
fixture.touch("images/41999284.webp");

const auto result = ygo::CardDatabase::load_json_intersection(
		fixture.path("cards.json"), fixture.path("images"));
assert(result.ok);
assert(result.database->size() == 2);
assert(result.stats.invalid_records == 1);

const auto *blue_eyes = result.database->find(89631139);
assert(blue_eyes != nullptr);
assert(blue_eyes->display.cn_name == "青眼白龙");
assert(blue_eyes->rule.level == 8);
assert(blue_eyes->rule.attack == 3000);

const auto *decode_talker = result.database->find(41999284);
assert(decode_talker != nullptr);
assert(decode_talker->rule.defense == 0);
assert(decode_talker->rule.link_marker == 42);
```

其中缺图记录的 JSON 结构为：

```json
"missing_image": {
  "cid": 5000,
  "id": 12345678,
  "cn_name": "缺图测试卡",
  "text": {"types": "", "pdesc": "", "desc": ""},
  "data": {"ot": 3, "setcode": 1103806669639, "type": 16777249,
           "atk": -2, "def": 1000, "level": 84017156,
           "race": 1, "attribute": 4}
}
```

不创建对应图片，并断言：

```cpp
assert(result.stats.missing_image_records == 1);
assert(result.database->find(12345678) == nullptr);
assert(blue_eyes->display.image_relative_path == "images/89631139.webp");
```

为灵摆测试记录使用明确的打包值，并断言：

```cpp
assert(pendulum.rule.level == (packed_level & 0xffU));
assert(pendulum.rule.left_scale == ((packed_level >> 24U) & 0xffU));
assert(pendulum.rule.right_scale == ((packed_level >> 16U) & 0xffU));
```

为 `setcode` 断言每 16 位非零值按低位到高位拆入数组，数组本身不包含终止零；OCGCore 适配层再提供终止零。

同时先在 CMake 中建立目标：

```cmake
add_library(ygo_card_database STATIC src/card_database.cpp)
target_include_directories(ygo_card_database PUBLIC include)
target_link_libraries(ygo_card_database PUBLIC nlohmann_json::nlohmann_json)

add_executable(test_card_database tests/test_card_database.cpp)
target_include_directories(test_card_database PRIVATE tests)
target_link_libraries(test_card_database PRIVATE ygo_card_database)
add_test(NAME card_database COMMAND test_card_database)
```

- [ ] **Step 2: 运行测试确认失败**

运行：

```bash
cmake --build build/native --target test_card_database -j4
./build/native/test_card_database
```

预期：编译失败，提示 `card_database.hpp`、数据库类型或加载函数尚未实现。

- [ ] **Step 3: 实现最小 JSON 交集加载**

`CardDatabaseLoadResult` 使用显式状态：

```cpp
struct CardDatabaseStats {
	std::size_t json_records = 0;
	std::size_t accepted_records = 0;
	std::size_t invalid_records = 0;
	std::size_t missing_image_records = 0;
};

struct CardDatabaseLoadResult {
	bool ok = false;
	std::string message;
	std::shared_ptr<CardDatabase> database;
	CardDatabaseStats stats;
};
```

实现要求：

1. 以二进制模式读取完整 JSON。
2. 捕获 nlohmann/json 解析异常并转换为中文 `message`。
3. 每条记录先验证 `id`、`cn_name` 和必要 `data` 数值字段。
4. 用 `images/<id>.webp` 的存在性筛选交集。
5. 发现重复有效 `id` 时整次加载失败，错误包含卡号。
6. `TYPE_LINK = 0x4000000` 时把 `data.def` 写入 `link_marker`，并把 `defense` 设为 `0`。
7. `level`、左右刻度和 `setcode` 按测试中的位规则拆分。

核心字段转换用独立私有函数：

```cpp
std::optional<CardRecord> parse_record(
		const nlohmann::json &source,
		const std::filesystem::path &images_dir,
		CardDatabaseStats &stats,
		std::string &error);
```

用详细中文注释解释 Link、灵摆打包字段和 `setcode` 的来源格式。

- [ ] **Step 4: 运行单元测试确认通过**

运行：

```bash
cmake --build build/native --target test_card_database -j4
./build/native/test_card_database
```

预期：退出码 0。

- [ ] **Step 5: 添加完整素材集成断言**

测试仅在环境变量 `YGO_TEST_ASSET_ROOT` 存在时执行：

```cpp
if (const char *root = std::getenv("YGO_TEST_ASSET_ROOT")) {
	const auto full = CardDatabase::load_json_intersection(
			std::filesystem::path(root) / "data/cards.json",
			std::filesystem::path(root) / "images");
	assert(full.ok);
	assert(full.database->size() == 14110);
	assert(full.stats.invalid_records == 42);
	assert(full.stats.missing_image_records == 96);
	assert(full.database->find(89631139)->display.cn_name == "青眼白龙");
}
```

- [ ] **Step 6: 运行单元和完整素材测试**

运行：

```bash
YGO_TEST_ASSET_ROOT=/Volumes/WD/YGO ./build/native/test_card_database
ctest --test-dir build/native --output-on-failure
```

预期：全部通过，完整素材统计精确匹配已确认数字。

- [ ] **Step 7: 提交数据库解析器**

```bash
git add native/include/ygo/card_database.hpp native/src/card_database.cpp \
  native/tests/test_card_database.cpp native/CMakeLists.txt
git commit \
  -m "feat(卡片): 建立 JSON 与卡图交集数据库" \
  -m "实现以规则卡号 id 为主键的 C++ 卡片数据库，只收录有效规则记录与现有卡图的交集。" \
  -m "字段转换覆盖中文展示信息、普通怪兽、Link、灵摆和 setcode，并对无效记录、缺图记录及重复卡号提供中文统计或错误。" \
  -m "验证：单元夹具测试通过；完整本地素材得到 14110 张交集卡、42 条无效记录和 96 张缺图卡。"
```

---

### Task 3: 实现可校验的无指针二进制缓存

**Files:**
- Create: `native/include/ygo/card_cache.hpp`
- Create: `native/src/card_cache.cpp`
- Create: `native/tests/test_card_cache.cpp`
- Modify: `native/CMakeLists.txt`

**Interfaces:**
- Consumes: `const CardDatabase &`、`CardSourceFingerprint`、缓存文件路径。
- Produces:
  - `CardCache::write_atomic(...) -> CacheWriteResult`
  - `CardCache::read(...) -> CacheReadResult`
  - `CardSourceFingerprint {json_hash, image_list_hash}`

- [ ] **Step 1: 写入缓存往返与损坏测试**

测试必须覆盖：

```cpp
const CardSourceFingerprint fingerprint{0x1122334455667788ULL, 0x8877665544332211ULL};
const auto write = CardCache::write_atomic(cache_path, database, fingerprint);
assert(write.ok);

const auto read = CardCache::read(cache_path, fingerprint);
assert(read.ok);
assert(read.database->size() == database.size());
assert(read.database->find(89631139)->display.cn_name == "青眼白龙");
```

然后依次构造并断言中文失败信息：

- 截断到只剩 8 字节。
- 修改魔数。
- 修改格式版本。
- 写入超出文件剩余长度的字符串长度。
- 使用不同 `json_hash`。
- 使用不同 `image_list_hash`。

- [ ] **Step 2: 运行测试确认接口不存在**

```bash
cmake -S native -B build/native -DCMAKE_BUILD_TYPE=Debug
cmake --build build/native --target test_card_cache -j4
```

预期：编译失败，提示 `ygo/card_cache.hpp` 不存在。

- [ ] **Step 3: 实现明确版本的缓存编码**

缓存格式按小端逐字段编码：

```text
8 bytes  魔数 "YGOCARD\0"
u32      格式版本（初始为 1）
u64      JSON 内容哈希
u64      排序后图片文件名清单哈希
u32      记录数量
u32      JSON 原始记录数量
u32      无效记录数量
u32      缺图记录数量
records  按 id 升序编码
```

每条记录按固定字段顺序写整数；每个字符串写 `u32` 字节长度后跟 UTF-8
字节；`setcodes` 写 `u32` 数量后跟 `u16` 值。读取时使用：

```cpp
class CheckedReader {
public:
	bool read_u16(std::uint16_t &value);
	bool read_u32(std::uint32_t &value);
	bool read_u64(std::uint64_t &value);
	bool read_string(std::string &value, std::uint32_t max_bytes);
	[[nodiscard]] bool finished() const noexcept;
};
```

限制：记录不超过 100,000，单字符串不超过 4 MiB，单卡 `setcodes` 不超过
256。所有乘法或加法在读取前检查溢出。

- [ ] **Step 4: 实现同目录原子写入**

写入 `<cache>.tmp`，刷新并关闭成功后再用 `std::filesystem::rename` 替换。
失败时只清理本次创建的临时文件。中文注释说明为什么临时文件必须和
目标文件位于同一目录。

- [ ] **Step 5: 运行缓存测试**

```bash
cmake --build build/native --target test_card_cache -j4
./build/native/test_card_cache
```

预期：全部通过，损坏输入只返回失败，不崩溃。

- [ ] **Step 6: 提交缓存实现**

```bash
git add native/include/ygo/card_cache.hpp native/src/card_cache.cpp \
  native/tests/test_card_cache.cpp native/CMakeLists.txt
git commit \
  -m "feat(缓存): 实现安全的卡片二进制缓存" \
  -m "新增带魔数、版本、双数据源指纹和长度检查的无指针缓存格式，并按规则卡号稳定排序写入。" \
  -m "缓存写入采用同目录临时文件替换，读取器限制记录、字符串和数组长度；截断、版本错误、指纹变化和恶意长度均返回中文错误。" \
  -m "验证：缓存往返、损坏文件和指纹失效测试全部通过。"
```

---

### Task 4: 编排缓存命中、失效和自动重建

**Files:**
- Create: `native/include/ygo/card_repository.hpp`
- Create: `native/src/card_repository.cpp`
- Create: `native/tests/test_card_repository.cpp`
- Modify: `native/CMakeLists.txt`

**Interfaces:**
- Consumes:
  - `CardRepositoryPaths {cards_json, images_dir, cache_file}`
  - `CardDatabase::load_json_intersection`
  - `CardCache::read/write_atomic`
- Produces:
  - `CardRepository::initialize(paths) -> RepositoryInitResult`
  - `RepositoryInitResult {ok, cache_state, message, database, stats}`
  - `CacheState::{Hit, Rebuilt}`

- [ ] **Step 1: 写入缓存编排失败测试**

使用临时夹具验证：

1. 第一次初始化返回 `CacheState::Rebuilt`。
2. 第二次初始化返回 `CacheState::Hit`。
3. 修改 JSON 内容后返回 `Rebuilt`。
4. 增加或删除一个 `.webp` 文件后返回 `Rebuilt`。
5. 截断缓存后返回 `Rebuilt`，且数据库仍可查询。
6. `cards.json` 不存在时返回中文错误。
7. `images/` 不存在时返回中文错误。

- [ ] **Step 2: 运行测试确认失败**

```bash
cmake --build build/native --target test_card_repository -j4
```

预期：编译失败，提示 `CardRepository` 尚不存在。

- [ ] **Step 3: 实现稳定数据源指纹**

JSON 指纹使用整个文件字节的 64 位 FNV-1a；图片指纹只使用排序后的
`*.webp` 文件名和文件大小，不读取图片内容。算法固定为：

```cpp
constexpr std::uint64_t FNV_OFFSET = 14695981039346656037ULL;
constexpr std::uint64_t FNV_PRIME = 1099511628211ULL;
```

每个文件名按 UTF-8 字节散列，随后散列一个零分隔字节和 64 位文件
大小，确保清单边界无歧义。忽略 `._*` 和非 `.webp` 文件。

- [ ] **Step 4: 实现初始化状态机**

严格顺序：

```text
验证源路径
→ 计算指纹
→ 尝试读取缓存
→ 命中则返回
→ 未命中或损坏则解析 JSON
→ 创建缓存目录
→ 原子写入缓存
→ 返回重建结果
```

损坏缓存的中文警告保存在结果的 `warnings` 数组中；源 JSON 无效属于
致命错误，不返回空数据库。

- [ ] **Step 5: 运行编排测试**

```bash
cmake --build build/native --target test_card_repository -j4
./build/native/test_card_repository
```

预期：全部通过。

- [ ] **Step 6: 运行项目真实缓存的两次初始化检查**

为测试程序增加 `YGO_TEST_ASSET_ROOT` 集成分支，缓存输出改到测试临时
目录，禁止覆盖项目正式缓存。运行：

```bash
YGO_TEST_ASSET_ROOT=/Volumes/WD/YGO ./build/native/test_card_repository
```

预期：第一次重建、第二次命中，数据库均为 14,110 张。

- [ ] **Step 7: 提交仓库编排器**

```bash
git add native/include/ygo/card_repository.hpp native/src/card_repository.cpp \
  native/tests/test_card_repository.cpp native/CMakeLists.txt
git commit \
  -m "feat(缓存): 编排卡片缓存命中与自动重建" \
  -m "新增卡片仓库初始化状态机，以 JSON 内容和排序后的卡图清单生成稳定指纹，统一处理缓存命中、源变化和损坏恢复。" \
  -m "源路径错误会返回中文致命错误；损坏缓存会记录中文警告并从源数据安全重建，测试不会覆盖项目正式缓存。" \
  -m "验证：首次重建、二次命中、JSON 变化、卡图变化、缓存截断和缺失路径测试全部通过。"
```

---

### Task 5: 安全加载基础 Lua 与正式卡脚本

**Files:**
- Create: `native/include/ygo/official_script_loader.hpp`
- Create: `native/src/official_script_loader.cpp`
- Create: `native/tests/test_official_script_loader.cpp`
- Modify: `native/CMakeLists.txt`

**Interfaces:**
- Consumes: CardScripts 根路径、OCGCore 请求名（如 `c89631139.lua` 或 `proc_link.lua`）、`OCG_Duel`。
- Produces:
  - `OfficialScriptLoader::validate() -> ScriptLoadResult`
  - `OfficialScriptLoader::read_requested(std::string_view) -> ScriptLoadResult`
  - `OfficialScriptLoader::load_requested(OCG_Duel, std::string_view) -> int`
  - `OfficialScriptLoader::load_bootstrap(OCG_Duel) -> ScriptLoadResult`

- [ ] **Step 1: 写入路径安全失败测试**

创建临时脚本根目录和文件：

```text
constant.lua
utility.lua
proc_link.lua
official/c89631139.lua
unofficial/c1.lua
```

通过正式的读取接口断言：

```cpp
assert(loader.read_requested("constant.lua").bytes == "CONST");
assert(loader.read_requested("proc_link.lua").bytes == "LINK");
assert(loader.read_requested("c89631139.lua").bytes == "BLUE_EYES");
assert(!loader.read_requested("../constant.lua").ok);
assert(!loader.read_requested("/tmp/c1.lua").ok);
assert(!loader.read_requested("unofficial/c1.lua").ok);
assert(!loader.read_requested("official/../unofficial/c1.lua").ok);
```

测试直接验证生产读取行为，不增加测试专用方法，也不向调用方暴露任意
文件系统路径。

- [ ] **Step 2: 运行测试确认失败**

```bash
cmake --build build/native --target test_official_script_loader -j4
```

预期：编译失败，提示脚本加载器不存在。

- [ ] **Step 3: 实现白名单路径解析**

允许两类请求：

1. 精确匹配 `[A-Za-z0-9_]+\.lua` 且不含路径分隔符的根目录基础脚本
   名，映射到 CardScripts 根目录同名文件。
2. 精确匹配 `c[0-9]+.lua`，映射到 `official/<原文件名>`。

任何包含反斜杠、冒号、空字节、路径分隔符或 `..` 的请求直接拒绝。
不得依靠先拼接再 `canonical()` 来补救危险输入。

`utility.lua` 会加载根目录中的 `proc_unofficial.lua`；它是 CardScripts
公共基础设施，因此允许加载。该规则不允许访问 `unofficial/` 子目录，
也不会把非正式卡加入数据库。

- [ ] **Step 4: 实现 OCGCore 脚本读取**

```cpp
int OfficialScriptLoader::load_requested(OCG_Duel duel, std::string_view name) {
	const auto path = resolve_allowed(name);
	if (!path) {
		set_last_error("已拒绝越界或非正式卡脚本请求：" + std::string(name));
		return 0;
	}
	const auto bytes = read_file(*path);
	if (!bytes) {
		set_last_error("无法读取 Lua 脚本：" + path->string());
		return 0;
	}
	return OCG_LoadScript(duel, bytes->data(),
			static_cast<std::uint32_t>(bytes->size()), name.data());
}
```

实际实现必须检查文件长度不超过 `uint32_t`，并保证传给 OCGCore 的名称
以空字符结尾。

- [ ] **Step 5: 实现基础脚本启动顺序**

创建决斗后先显式加载：

```text
constant.lua
utility.lua
```

这两个脚本通过 `Duel.LoadScript` 再请求其基础依赖，所有递归请求继续走
同一个白名单回调。`validate()` 预检 `constant.lua` 和 `utility.lua`；
其余基础依赖由实际递归加载结果验证，缺失时返回包含脚本名的中文错误。

- [ ] **Step 6: 运行单元和真实目录验证**

```bash
cmake --build build/native --target test_official_script_loader -j4
./build/native/test_official_script_loader
YGO_TEST_SCRIPT_ROOT=/Volumes/WD/YGO/third_party/CardScripts \
  ./build/native/test_official_script_loader
```

预期：允许路径全部通过，越界路径全部拒绝，真实基础脚本校验成功。

- [ ] **Step 7: 提交脚本加载器**

```bash
git add native/include/ygo/official_script_loader.hpp \
  native/src/official_script_loader.cpp \
  native/tests/test_official_script_loader.cpp native/CMakeLists.txt
git commit \
  -m "feat(脚本): 安全加载正式卡 Lua 规则" \
  -m "新增 CardScripts 白名单加载器，只允许根目录基础脚本和 official 目录中的数字卡号脚本。" \
  -m "加载器拒绝绝对路径、父目录跳转和非正式卡目录，并在创建决斗后按顺序加载 constant.lua 与 utility.lua 及其依赖。" \
  -m "验证：允许路径、越界拒绝、缺失脚本、基础依赖和真实 CardScripts 目录测试全部通过。"
```

---

### Task 6: 把真实数据库与脚本回调接入 DuelSession

**Files:**
- Create: `native/include/ygo/ocg_card_data_adapter.hpp`
- Create: `native/src/ocg_card_data_adapter.cpp`
- Modify: `native/include/ygo/duel_session.hpp`
- Modify: `native/src/duel_session.cpp`
- Create: `native/tests/test_ocg_card_data_adapter.cpp`
- Modify: `native/tests/test_duel_session.cpp`
- Modify: `native/CMakeLists.txt`

**Interfaces:**
- Consumes:
  - `std::shared_ptr<const CardDatabase>`
  - `std::shared_ptr<OfficialScriptLoader>`
- Produces:
  - `OcgCardDataAdapter::read(std::uint32_t, OCG_CardData *)`
  - `OcgCardDataAdapter::done(OCG_CardData *)`
  - `DuelSession(database, scripts)`
  - 真实 `OCG_DataReader`、`OCG_DataReaderDone`、`OCG_ScriptReader`
  - `CreateResult::message` 中文化

- [ ] **Step 1: 写入字段适配器失败测试**

`native/tests/test_ocg_card_data_adapter.cpp` 使用真实 `CardDatabase` 记录：

```cpp
auto database = database_with_blue_eyes();
ygo::OcgCardDataAdapter adapter(database);
OCG_CardData data{};

adapter.read(89631139, &data);
assert(data.code == 89631139);
assert(data.attack == 3000);
assert(data.defense == 2500);
assert(data.setcodes != nullptr);
assert(data.setcodes[0] == 0x10f3);
assert(data.setcodes[1] == 0);

adapter.done(&data);
assert(data.setcodes == nullptr);
```

再读取不存在的卡号，断言结构体除请求 `code` 外为零且不会崩溃。

- [ ] **Step 2: 运行测试确认适配器不存在**

```bash
cmake --build build/native --target test_ocg_card_data_adapter -j4
```

预期：编译失败，提示 `ocg_card_data_adapter.hpp` 或类型尚不存在。

- [ ] **Step 3: 实现正式字段适配组件**

`OcgCardDataAdapter` 是生产组件，不包含任何测试专用接口。它保存
`std::shared_ptr<const CardDatabase>` 和每个决斗实例独占的
`std::vector<std::uint16_t> callback_setcodes_`。

`read()` 按以下流程：

1. 查找 `code`。
2. 未找到时返回全零结构并把 `code` 保留为请求值。
3. 找到时逐字段填充 `OCG_CardData`。
4. 把记录的 `setcodes` 复制到 `callback_setcodes_` 并追加终止零。
5. 把 `data->setcodes` 指向该数组。

`done()` 把传入结构的 `setcodes` 指针清空，并清理临时数组。中文注释
明确当前 OCGCore 在 `card_data` 构造期间同步复制该数组，完成回调后不
得继续使用指针。

- [ ] **Step 4: 运行字段适配器测试**

```bash
cmake --build build/native --target test_ocg_card_data_adapter -j4
./build/native/test_ocg_card_data_adapter
```

预期：退出码 0。

- [ ] **Step 5: 修改生命周期测试，要求真实依赖**

测试先创建最小数据库和脚本夹具：

```cpp
auto database = load_fixture_database();
auto scripts = std::make_shared<OfficialScriptLoader>(fixture.path("scripts"));
DuelSession session(database, scripts);

const auto created = session.create(0x59474f);
assert(created.ok);
assert(created.message == "决斗创建成功");
assert(session.is_active());
session.destroy();
assert(!session.is_active());
```

- [ ] **Step 6: 运行测试确认旧构造接口失败**

```bash
cmake --build build/native --target test_duel_session -j4
./build/native/test_duel_session
```

预期：编译失败，提示新构造函数或测试适配接口不存在。

- [ ] **Step 7: 实现共享所有权和真实卡片回调**

`DuelSession` 保存：

```cpp
std::shared_ptr<const CardDatabase> database_;
std::shared_ptr<OfficialScriptLoader> scripts_;
OcgCardDataAdapter card_data_adapter_;
```

`cardReader` 和 `cardReaderDone` 只负责把 C 回调转发到
`OcgCardDataAdapter::read/done`。为避免未来并发误用，回调和创建/处理
决斗保持同一线程；后续若引入并行决斗，每个 `DuelSession` 独占自己的
适配器和回调缓冲区。

- [ ] **Step 8: 接入脚本回调与基础脚本**

`options.scriptReader` 转发到 `OfficialScriptLoader::load_requested`。
`OCG_CreateDuel` 成功后立即调用 `load_bootstrap`；基础脚本失败时销毁
刚创建的句柄并返回失败，不留下半初始化决斗。

所有 `creation_message` 文本改为中文，例如：

```cpp
case OCG_DUEL_CREATION_SUCCESS:
	return "决斗创建成功";
case OCG_DUEL_CREATION_INCOMPATIBLE_LUA_API:
	return "OCGCore 使用的 Lua API 不兼容";
```

- [ ] **Step 9: 运行原生测试**

```bash
./scripts/build_native.sh
```

预期：所有 CTest 测试通过，原有幂等销毁和重复创建保护仍通过。

- [ ] **Step 10: 运行真实数据决斗创建测试**

测试在 `YGO_TEST_ASSET_ROOT` 存在时初始化完整数据库和真实
CardScripts，再创建决斗：

```bash
YGO_TEST_ASSET_ROOT=/Volumes/WD/YGO \
YGO_TEST_SCRIPT_ROOT=/Volumes/WD/YGO/third_party/CardScripts \
  ./build/native/test_duel_session
```

预期：OCGCore 11.0 创建、加载基础 Lua 并销毁成功。

- [ ] **Step 11: 提交真实 OCGCore 回调**

```bash
git add native/include/ygo/ocg_card_data_adapter.hpp \
  native/src/ocg_card_data_adapter.cpp \
  native/include/ygo/duel_session.hpp native/src/duel_session.cpp \
  native/tests/test_ocg_card_data_adapter.cpp \
  native/tests/test_duel_session.cpp native/CMakeLists.txt
git commit \
  -m "feat(规则): 接入真实卡片与 Lua 回调" \
  -m "新增正式 OCG 卡片字段适配组件，集中管理 CardRecord 到 OCG_CardData 的转换和 setcode 终止缓冲区；DuelSession 共享持有卡片数据库和正式脚本加载器。" \
  -m "基础脚本在决斗创建后立即加载，失败时会销毁半初始化句柄；决斗创建状态和自有日志已统一为中文。" \
  -m "验证：原生生命周期、字段适配、基础脚本和完整本地素材决斗创建测试全部通过。"
```

---

### Task 7: 向 Godot 暴露初始化和卡片查询

**Files:**
- Modify: `native/include/ygo/ygo_core_bridge.hpp`
- Modify: `native/src/ygo_core_bridge.cpp`
- Modify: `src/main/main.gd`
- Modify: `src/main/main.tscn`
- Modify: `native/CMakeLists.txt`

**Interfaces:**
- Consumes: `CardRepository`、`OfficialScriptLoader`、`DuelSession`。
- Produces:
  - `YgoCoreBridge.initialize_card_database(project_root: String) -> Dictionary`
  - `YgoCoreBridge.get_card_count() -> int`
  - `YgoCoreBridge.get_card(id: int) -> Dictionary`
  - `YgoCoreBridge.get_cache_state() -> Dictionary`

- [ ] **Step 1: 修改 GDScript 诊断，先形成失败测试**

`src/main/main.gd` 在创建决斗前调用：

```gdscript
var initialized: Dictionary = bridge.call(
		"initialize_card_database",
		ProjectSettings.globalize_path("res://")
)
assert(initialized.ok)
assert(bridge.call("get_card_count") == 14110)

var blue_eyes: Dictionary = bridge.call("get_card", 89631139)
assert(blue_eyes.ok)
assert(blue_eyes.cn_name == "青眼白龙")
assert(blue_eyes.image_path == "res://images/89631139.webp")
```

界面状态必须使用中文。

- [ ] **Step 2: 运行 Godot 确认桥接方法不存在**

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Volumes/WD/YGO --quit-after 2
```

预期：脚本错误明确指出 `initialize_card_database` 尚不存在。

- [ ] **Step 3: 实现桥接初始化**

桥接层保存：

```cpp
std::shared_ptr<CardDatabase> database_;
std::shared_ptr<OfficialScriptLoader> scripts_;
std::unique_ptr<DuelSession> session_;
RepositoryInitResult repository_status_;
```

初始化路径从传入的项目根目录严格拼接：

```text
data/cards.json
images/
.cache/cards/card_database.bin
third_party/CardScripts/
```

不得在 C++ 中写死 `/Volumes/WD/YGO`，以便仓库整体移动。路径解析后必须
确认所有路径仍位于传入项目根目录。

- [ ] **Step 4: 实现 Godot Dictionary 转换**

初始化结果：

```text
ok: bool
message: String
cache_state: "命中" | "已重建"
card_count: int
invalid_records: int
missing_image_records: int
warnings: PackedStringArray
```

卡片查询结果：

```text
ok: bool
id: int
cid: int
cn_name: String
types: String
pendulum_description: String
description: String
image_path: String
```

未找到时返回 `{ok = false, message = "未找到卡片：<id>"}`，不返回部分
伪造字段。

- [ ] **Step 5: 更新诊断场景**

`main.tscn` 增加独立标签：

```text
GodotStatus
CoreStatus
CardStatus
CacheStatus
TestCardStatus
LuaStatus
```

`main.gd` 显示运行时真实值，并在 `_exit_tree()` 中销毁决斗。失败时调用
`push_error()` 的文本也必须为中文。

- [ ] **Step 6: 构建并运行 Godot 无头测试**

```bash
./scripts/build_native.sh
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Volumes/WD/YGO --quit-after 2
```

预期：退出码 0，无项目脚本错误。

- [ ] **Step 7: 使用 Godot MCP 做可见验证**

1. 用 `mcp__godot.run_project` 启动 `/Volumes/WD/YGO`。
2. 用本机只读界面检查确认显示：

```text
Godot 4.6.3
OCGCore 11.0
正式卡片：14110
缓存：已就绪（命中或已重建）
测试卡片：青眼白龙（89631139）
Lua 规则：已连接
```

3. 用 `mcp__godot.get_debug_output` 检查项目错误。
4. 用 `mcp__godot.stop_project` 停止。

MCP 注入脚本自身的警告必须与项目错误分开记录，不得误判为项目失败。

- [ ] **Step 8: 提交 Godot 集成**

```bash
git add native/include/ygo/ygo_core_bridge.hpp native/src/ygo_core_bridge.cpp \
  src/main/main.gd src/main/main.tscn native/CMakeLists.txt
git commit \
  -m "feat(Godot): 展示真实卡库与脚本状态" \
  -m "扩展 GDExtension 桥接接口，支持初始化项目内卡片缓存、查询卡片数量和按 id 返回 cn_name、描述及卡图路径。" \
  -m "诊断界面改为展示真实 OCGCore、卡片交集、缓存、青眼白龙和 Lua 连接状态，所有项目输出均使用中文。" \
  -m "验证：原生构建、CTest、Godot 无头启动和 Godot MCP 可见运行检查全部通过。"
```

---

### Task 8: 开发文档与全量验收

**Files:**
- Modify: `docs/development/native-build.md`
- Create: `docs/development/card-data.md`
- Modify: `LICENSES/THIRD_PARTY.md`

**Interfaces:**
- Consumes: 前七个任务的最终命令、路径、缓存状态和错误行为。
- Produces: 新开发者可复现的卡库初始化、缓存清理和脚本目录说明。

- [ ] **Step 1: 补充卡片数据文档**

`docs/development/card-data.md` 必须说明：

- `id`、`cid`、图片文件名和 Lua 文件名的对应关系。
- 只取有效 JSON 与卡图交集的原因。
- `cn_name` 是唯一默认展示名称。
- 缓存路径、指纹组成和自动重建条件。
- 手动删除 `.cache/cards/card_database.bin` 的影响只是下次启动重建。
- 正式卡脚本白名单和不支持的目录。
- 常见中文错误及排查路径。

- [ ] **Step 2: 更新原生构建与许可证文档**

在 `native-build.md` 增加：

```bash
git submodule update --init --recursive
./scripts/build_native.sh
YGO_TEST_ASSET_ROOT=/Volumes/WD/YGO ctest \
  --test-dir build/native --output-on-failure
```

确认 `LICENSES/THIRD_PARTY.md` 中 nlohmann/json 信息与实际子模块一致。

- [ ] **Step 3: 执行干净原生构建**

不使用破坏性删除。把旧构建目录移到系统临时目录：

```bash
verify_tmp_dir=$(mktemp -d /tmp/ygo-card-final.XXXXXX)
if [ -d build/native ]; then
  mv build/native "$verify_tmp_dir/native-previous"
fi
./scripts/build_native.sh
```

预期：完整编译成功，CTest 0 失败。

- [ ] **Step 4: 执行完整素材与 Godot 验证**

```bash
YGO_TEST_ASSET_ROOT=/Volumes/WD/YGO \
YGO_TEST_SCRIPT_ROOT=/Volumes/WD/YGO/third_party/CardScripts \
  ctest --test-dir build/native --output-on-failure

/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Volumes/WD/YGO --quit-after 2
```

预期：全部通过，Godot 无项目错误。

- [ ] **Step 5: 检查仓库与依赖完整性**

```bash
find .git third_party docs native src -type f -name '._*' -delete
git submodule status --recursive
git diff --check
git fsck --full
git status --short --branch
```

预期：

- 所有子模块前缀为空格，不是 `-`、`+` 或 `U`。
- `git diff --check` 无输出。
- `git fsck --full` 无损坏对象；允许仅报告不可达悬空对象。
- 除本任务文档外无未提交文件。

- [ ] **Step 6: 提交开发文档**

```bash
git add docs/development/native-build.md docs/development/card-data.md \
  LICENSES/THIRD_PARTY.md
git commit \
  -m "docs(卡片): 补充数据缓存与脚本开发说明" \
  -m "记录规则卡号、来源编号、卡图和 Lua 文件的对应关系，并说明交集筛选、中文名称、缓存失效和正式卡脚本白名单。" \
  -m "原生构建文档补充完整素材测试命令，许可证清单与固定的 JSON 依赖保持一致。" \
  -m "验证：干净原生构建、全部 CTest、完整素材集成、Godot 无头启动、子模块状态、Git 差异和仓库完整性检查通过。"
```

- [ ] **Step 7: 按完成分支流程处理 `main`**

重新运行当前提交树的：

```bash
./scripts/build_native.sh
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Volumes/WD/YGO --quit-after 2
test -z "$(git status --porcelain)"
```

用户已经指定直接在 `main` 开发。验证成功后，把当前 `main` 推送到既有
远端：

```bash
git push -u origin main
```

不得创建额外功能分支或 PR；推送失败时不得强推，应先检查远端状态并
向用户报告。
