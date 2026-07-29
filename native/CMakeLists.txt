cmake_minimum_required(VERSION 3.24)

project(ygo_native LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

enable_testing()

add_subdirectory(
	"${CMAKE_CURRENT_SOURCE_DIR}/../third_party/json"
	"${CMAKE_CURRENT_BINARY_DIR}/json"
	EXCLUDE_FROM_ALL
)

add_executable(test_card_record tests/test_card_record.cpp)
target_include_directories(test_card_record PRIVATE include)
add_test(NAME card_record COMMAND test_card_record)

add_library(ygo_card_database STATIC src/card_database.cpp)
target_include_directories(ygo_card_database PUBLIC include)
target_link_libraries(ygo_card_database PUBLIC nlohmann_json::nlohmann_json)

add_library(ygo_card_cache STATIC src/card_cache.cpp)
target_include_directories(ygo_card_cache PUBLIC include)
target_link_libraries(ygo_card_cache PUBLIC ygo_card_database)

add_library(ygo_card_repository STATIC src/card_repository.cpp)
target_include_directories(ygo_card_repository PUBLIC include)
target_link_libraries(ygo_card_repository PUBLIC ygo_card_cache)

add_executable(test_card_database tests/test_card_database.cpp)
target_include_directories(test_card_database PRIVATE tests)
target_link_libraries(test_card_database PRIVATE ygo_card_database)
add_test(NAME card_database COMMAND test_card_database)

add_executable(test_card_cache tests/test_card_cache.cpp)
target_include_directories(test_card_cache PRIVATE tests)
target_link_libraries(test_card_cache PRIVATE ygo_card_cache)
add_test(NAME card_cache COMMAND test_card_cache)

add_executable(test_card_repository tests/test_card_repository.cpp)
target_include_directories(test_card_repository PRIVATE tests)
target_link_libraries(test_card_repository PRIVATE ygo_card_repository)
add_test(NAME card_repository COMMAND test_card_repository)

set(OCGCORE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/ygopro-core")
set(LUA_DIR "${OCGCORE_DIR}/lua")
set(LUA_SRC_DIR "${LUA_DIR}/src")

set(OCGCORE_SOURCES
	"${OCGCORE_DIR}/card.cpp"
	"${OCGCORE_DIR}/duel.cpp"
	"${OCGCORE_DIR}/effect.cpp"
	"${OCGCORE_DIR}/field.cpp"
	"${OCGCORE_DIR}/interpreter.cpp"
	"${OCGCORE_DIR}/libcard.cpp"
	"${OCGCORE_DIR}/libdebug.cpp"
	"${OCGCORE_DIR}/libduel.cpp"
	"${OCGCORE_DIR}/libeffect.cpp"
	"${OCGCORE_DIR}/libgroup.cpp"
	"${OCGCORE_DIR}/ocgapi.cpp"
	"${OCGCORE_DIR}/operations.cpp"
	"${OCGCORE_DIR}/playerop.cpp"
	"${OCGCORE_DIR}/processor.cpp"
	"${OCGCORE_DIR}/processor_visit.cpp"
	"${OCGCORE_DIR}/scriptlib.cpp"
)

file(GLOB LUA_SOURCES CONFIGURE_DEPENDS "${LUA_SRC_DIR}/*.c")
list(FILTER LUA_SOURCES EXCLUDE REGEX "/(lcorolib|ldblib|linit|loadlib|loslib|ltests|lua|luac|lutf8lib|onelua)\\.c$")
set_source_files_properties(${LUA_SOURCES} PROPERTIES
	LANGUAGE CXX
	COMPILE_OPTIONS "-include;${LUA_DIR}/luaconf-customize.h"
)

add_library(ocgcore STATIC ${OCGCORE_SOURCES} ${LUA_SOURCES})
set_target_properties(ocgcore PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(ocgcore PUBLIC "${OCGCORE_DIR}" "${LUA_SRC_DIR}")
target_compile_options(ocgcore PRIVATE
	$<$<CXX_COMPILER_ID:AppleClang,Clang,GNU>:-Wno-unused-parameter>
)
set_source_files_properties("${OCGCORE_DIR}/processor_visit.cpp" PROPERTIES
	COMPILE_OPTIONS "-fno-exceptions"
)

add_library(ygo_duel_session STATIC
	src/duel_response.cpp
	src/duel_session.cpp
)
target_include_directories(ygo_duel_session PUBLIC include)
target_link_libraries(ygo_duel_session PUBLIC
	ocgcore
	ygo_duel_message_parser
	ygo_ocg_card_data_adapter
	ygo_official_script_loader
)

add_library(ygo_official_script_loader STATIC src/official_script_loader.cpp)
target_include_directories(ygo_official_script_loader PUBLIC include)
target_link_libraries(ygo_official_script_loader PUBLIC ocgcore)

add_library(ygo_ocg_card_data_adapter STATIC src/ocg_card_data_adapter.cpp)
target_include_directories(ygo_ocg_card_data_adapter PUBLIC include)
target_link_libraries(ygo_ocg_card_data_adapter PUBLIC ygo_card_database ocgcore)

add_executable(test_official_script_loader tests/test_official_script_loader.cpp)
target_include_directories(test_official_script_loader PRIVATE tests)
target_link_libraries(test_official_script_loader PRIVATE ygo_official_script_loader)
add_test(NAME official_script_loader COMMAND test_official_script_loader)

add_executable(test_ocg_card_data_adapter tests/test_ocg_card_data_adapter.cpp)
target_link_libraries(test_ocg_card_data_adapter PRIVATE ygo_ocg_card_data_adapter)
add_test(NAME ocg_card_data_adapter COMMAND test_ocg_card_data_adapter)

add_executable(test_duel_session tests/test_duel_session.cpp)
target_include_directories(test_duel_session PRIVATE tests)
target_link_libraries(test_duel_session PRIVATE
	ygo_duel_session
	ygo_card_repository
)

add_test(NAME duel_session_lifecycle COMMAND test_duel_session)

add_library(ygo_duel_message_parser STATIC src/duel_message_parser.cpp)
target_include_directories(ygo_duel_message_parser PUBLIC include)
target_link_libraries(ygo_duel_message_parser PUBLIC ocgcore)

add_executable(test_duel_response tests/test_duel_response.cpp)
target_link_libraries(test_duel_response PRIVATE ygo_duel_session)
add_test(NAME duel_response COMMAND test_duel_response)

add_executable(test_duel_message_parser tests/test_duel_message_parser.cpp)
target_link_libraries(test_duel_message_parser PRIVATE ygo_duel_message_parser)
add_test(NAME duel_message_parser COMMAND test_duel_message_parser)

set(GODOT_CPP_SYSTEM_HEADERS ON CACHE BOOL "" FORCE)
add_subdirectory(
	"${CMAKE_CURRENT_SOURCE_DIR}/../third_party/godot-cpp"
	"${CMAKE_CURRENT_BINARY_DIR}/godot-cpp"
	EXCLUDE_FROM_ALL
)

add_library(ygo_core SHARED
	src/register_types.cpp
	src/pending_action_godot_adapter.cpp
	src/process_result_godot_adapter.cpp
	src/ygo_core_bridge.cpp
)
target_include_directories(ygo_core PRIVATE include)
target_link_libraries(ygo_core PRIVATE
	godot::cpp
	ygo_duel_session
	ygo_card_repository
)
set_target_properties(ygo_core PROPERTIES
	OUTPUT_NAME "ygo_core"
	LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin/macos"
	RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin/macos"
)

# 该测试必须在 Godot 进程内运行，才能使用真实的 Variant/Dictionary ABI。
# CMake 在 build/ 内生成最小测试工程，CTest 启动一次无界面运行时并加载专用
# GDExtension；测试源码不会进入正式 ygo_core 动态库。
set(PENDING_ACTION_ADAPTER_TEST_PROJECT
	"${CMAKE_CURRENT_BINARY_DIR}/pending_action_adapter_test_project"
)
set(PENDING_ACTION_ADAPTER_TEST_RUNNER
"extends SceneTree


func _initialize() -> void:
	# Godot 即使加载 GDExtension 失败也可能继续执行脚本并返回 0。
	# 以正式绑定类作为契约哨兵，防止 CTest 把“测试根本没运行”误判为通过。
	if !ClassDB.class_exists(\"YgoCoreBridge\"):
		push_error(\"PendingAction Godot 适配器契约未运行：YgoCoreBridge 未注册\")
		quit(1)
		return
	quit()
"
)
file(MAKE_DIRECTORY "${PENDING_ACTION_ADAPTER_TEST_PROJECT}/.godot")
add_library(test_pending_action_godot_adapter SHARED
	src/pending_action_godot_adapter.cpp
	src/process_result_godot_adapter.cpp
	src/ygo_core_bridge.cpp
	tests/test_pending_action_godot_adapter.cpp
)
target_include_directories(test_pending_action_godot_adapter PRIVATE include)
target_link_libraries(test_pending_action_godot_adapter PRIVATE
	godot::cpp
	ygo_duel_session
	ygo_card_repository
)
set_target_properties(test_pending_action_godot_adapter PROPERTIES
	OUTPUT_NAME "test_pending_action_godot_adapter"
	LIBRARY_OUTPUT_DIRECTORY "${PENDING_ACTION_ADAPTER_TEST_PROJECT}/bin"
	RUNTIME_OUTPUT_DIRECTORY "${PENDING_ACTION_ADAPTER_TEST_PROJECT}/bin"
)
file(GENERATE
	OUTPUT "${PENDING_ACTION_ADAPTER_TEST_PROJECT}/project.godot"
	CONTENT
"[application]

config/name=\"PendingAction Godot 适配器契约测试\"

[rendering]

renderer/rendering_method=\"gl_compatibility\"
"
)
file(GENERATE
	OUTPUT "${PENDING_ACTION_ADAPTER_TEST_PROJECT}/test_pending_action_godot_adapter.gdextension"
	CONTENT
"[configuration]

entry_symbol=\"ygo_pending_action_adapter_test_init\"
compatibility_minimum=\"4.6\"

[libraries]

macos.debug=\"res://bin/$<TARGET_FILE_NAME:test_pending_action_godot_adapter>\"
macos.release=\"res://bin/$<TARGET_FILE_NAME:test_pending_action_godot_adapter>\"
"
)
file(GENERATE
	OUTPUT "${PENDING_ACTION_ADAPTER_TEST_PROJECT}/.godot/extension_list.cfg"
	CONTENT "res://test_pending_action_godot_adapter.gdextension\n"
)
file(GENERATE
	OUTPUT "${PENDING_ACTION_ADAPTER_TEST_PROJECT}/adapter_test_runner.gd"
	CONTENT "${PENDING_ACTION_ADAPTER_TEST_RUNNER}"
)

# 负向测试工程故意引用不存在的动态库。它与正式契约测试共用 runner，
# 用于证明“扩展没有加载”会成为非零退出，而不是被无条件 quit() 掩盖。
set(PENDING_ACTION_ADAPTER_MISSING_EXTENSION_TEST_PROJECT
	"${CMAKE_CURRENT_BINARY_DIR}/pending_action_adapter_missing_extension_test_project"
)
file(MAKE_DIRECTORY
	"${PENDING_ACTION_ADAPTER_MISSING_EXTENSION_TEST_PROJECT}/.godot"
)
file(GENERATE
	OUTPUT "${PENDING_ACTION_ADAPTER_MISSING_EXTENSION_TEST_PROJECT}/project.godot"
	CONTENT
"[application]

config/name=\"PendingAction 缺失扩展负向测试\"
"
)
file(GENERATE
	OUTPUT "${PENDING_ACTION_ADAPTER_MISSING_EXTENSION_TEST_PROJECT}/missing.gdextension"
	CONTENT
"[configuration]

entry_symbol=\"ygo_pending_action_adapter_test_init\"
compatibility_minimum=\"4.6\"

[libraries]

macos.debug=\"res://bin/libmissing_pending_action_adapter.dylib\"
macos.release=\"res://bin/libmissing_pending_action_adapter.dylib\"
"
)
file(GENERATE
	OUTPUT
		"${PENDING_ACTION_ADAPTER_MISSING_EXTENSION_TEST_PROJECT}/.godot/extension_list.cfg"
	CONTENT "res://missing.gdextension\n"
)
file(GENERATE
	OUTPUT
		"${PENDING_ACTION_ADAPTER_MISSING_EXTENSION_TEST_PROJECT}/adapter_test_runner.gd"
	CONTENT "${PENDING_ACTION_ADAPTER_TEST_RUNNER}"
)
find_program(YGO_GODOT_EXECUTABLE
	NAMES godot Godot
	HINTS "/Applications/Godot.app/Contents/MacOS"
)
if(NOT YGO_GODOT_EXECUTABLE
		OR NOT EXISTS "${YGO_GODOT_EXECUTABLE}"
		OR IS_DIRECTORY "${YGO_GODOT_EXECUTABLE}")
	message(FATAL_ERROR
		"未找到可执行的 Godot，无法运行 PendingAction 适配器契约测试"
	)
endif()
add_test(
	NAME pending_action_godot_adapter
	COMMAND
		"${YGO_GODOT_EXECUTABLE}"
		--headless
		--path "${PENDING_ACTION_ADAPTER_TEST_PROJECT}"
		--script res://adapter_test_runner.gd
)
add_test(
	NAME pending_action_godot_adapter_requires_extension
	COMMAND
		"${YGO_GODOT_EXECUTABLE}"
		--headless
		--path "${PENDING_ACTION_ADAPTER_MISSING_EXTENSION_TEST_PROJECT}"
		--script res://adapter_test_runner.gd
)
set_tests_properties(
	pending_action_godot_adapter_requires_extension
	PROPERTIES WILL_FAIL TRUE
)

# 显式传入不存在的 Godot 路径来验证默认构建不会静默跳过契约测试。
# 修复后的内层 configure 必须失败，因此该 CTest 使用 WILL_FAIL 反转预期。
add_test(
	NAME pending_action_godot_adapter_requires_godot
	COMMAND
		"${CMAKE_COMMAND}"
		-S "${CMAKE_CURRENT_SOURCE_DIR}"
		-B "${CMAKE_CURRENT_BINARY_DIR}/missing_godot_configure_test"
		-DYGO_GODOT_EXECUTABLE=${CMAKE_CURRENT_BINARY_DIR}/不存在的_godot
)
set_tests_properties(
	pending_action_godot_adapter_requires_godot
	PROPERTIES WILL_FAIL TRUE
)
