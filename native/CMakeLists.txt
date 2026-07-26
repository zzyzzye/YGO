cmake_minimum_required(VERSION 3.24)

project(ygo_native LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

enable_testing()

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

add_library(ygo_duel_session STATIC src/duel_session.cpp)
target_include_directories(ygo_duel_session PUBLIC include)
target_link_libraries(ygo_duel_session PUBLIC ocgcore)

add_executable(test_duel_session tests/test_duel_session.cpp)
target_link_libraries(test_duel_session PRIVATE ygo_duel_session)

add_test(NAME duel_session_lifecycle COMMAND test_duel_session)
