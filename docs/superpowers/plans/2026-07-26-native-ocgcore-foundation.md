# Native OCGCore Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS Godot 4 project whose C++ GDExtension links the real ocgcore, reports both engine versions, and safely creates and destroys an empty duel.

**Architecture:** Godot loads one `YgoCoreBridge` GDExtension class. The class delegates lifecycle work to a plain C++ `DuelSession`, keeping Godot `Variant` types out of the core wrapper. CMake builds the extension and a native test executable from the same wrapper sources.

**Tech Stack:** Godot 4.6.3, GDScript, C++17, CMake 3.24+, a pinned godot-cpp `master` commit compatible with Godot 4.6, edo9300/ygopro-core, CTest.

## Global Constraints

- Target macOS only for this plan.
- Use Godot 4.6.3 stable and require Godot 4.4 or newer.
- ocgcore is the only rules authority; do not implement card rules in GDScript.
- Keep the GDExtension API narrow and never expose raw ocgcore pointers to Godot.
- Do not add AI, networking, deck editing, 3D summons, card UI, or arbitrary deck loading.
- Pin third-party dependencies as Git submodules; retain all upstream licenses.
- Use C++ for core lifecycle, callbacks, binary protocol work, and validation.

---

## File Structure

```text
project.godot                         Godot project settings and main scene
src/main/main.tscn                    Native-link diagnostic scene
src/main/main.gd                      Displays bridge status and exits cleanly
native/CMakeLists.txt                 Native build graph
native/include/ygo/duel_session.hpp   Godot-independent ocgcore lifecycle API
native/src/duel_session.cpp           ocgcore callbacks and RAII implementation
native/include/ygo/ygo_core_bridge.hpp Godot-facing class declaration
native/src/ygo_core_bridge.cpp        Bound methods and Dictionary conversion
native/src/register_types.cpp         GDExtension initialization entry point
native/ygo_core.gdextension           macOS library mapping
native/tests/test_duel_session.cpp    Native lifecycle tests
scripts/build_native.sh               Reproducible local debug build
third_party/godot-cpp                 Pinned GDExtension bindings
third_party/ygopro-core               Pinned rules core
third_party/CardScripts               Pinned Lua scripts
third_party/BabelCDB                  Pinned card database
LICENSES/THIRD_PARTY.md               Dependency origins and licenses
```

### Task 1: Pin dependencies and create the diagnostic Godot project

**Files:**
- Create: `.gitmodules`
- Create: `project.godot`
- Create: `src/main/main.tscn`
- Create: `src/main/main.gd`
- Create: `LICENSES/THIRD_PARTY.md`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `res://src/main/main.tscn` as the project main scene.
- Produces: pinned submodules consumed by the native build.

- [ ] **Step 1: Add pinned dependency repositories**

Run:

```bash
git submodule add https://github.com/godotengine/godot-cpp.git third_party/godot-cpp
git submodule add https://github.com/edo9300/ygopro-core.git third_party/ygopro-core
git submodule add https://github.com/ProjectIgnis/CardScripts.git third_party/CardScripts
git submodule add https://github.com/ProjectIgnis/BabelCDB.git third_party/BabelCDB
git submodule update --init --recursive
```

Expected: all four paths are recorded in `.gitmodules`; `git submodule status --recursive` has no line beginning with `-` or `+`.

- [ ] **Step 2: Write the minimal Godot project**

Create `project.godot`:

```ini
[application]
config/name="YGO Offline"
run/main_scene="res://src/main/main.tscn"

[display]
window/size/viewport_width=1280
window/size/viewport_height=720
window/stretch/mode="canvas_items"

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
```

Create `src/main/main.tscn` with a `Control` root, centered `VBoxContainer`, title `Label`, status `Label` named `Status`, and script `res://src/main/main.gd`.

Create `src/main/main.gd`:

```gdscript
extends Control

@onready var status: Label = %Status

func _ready() -> void:
    status.text = "Native bridge not loaded"
```

- [ ] **Step 3: Document dependency licenses**

Write `LICENSES/THIRD_PARTY.md` with repository URLs, the pinned submodule commit shown by `git submodule status`, and these license labels: godot-cpp MIT, ygopro-core AGPL-3.0-or-later, CardScripts GPL-compatible upstream terms from its `COPYING`, and BabelCDB terms from its repository.

- [ ] **Step 4: Verify the project opens before native code exists**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Volumes/WD/YGO --editor --quit
```

Expected: exit code 0 and no parse error for `project.godot`, `main.tscn`, or `main.gd`.

- [ ] **Step 5: Commit**

```bash
git add .gitmodules .gitignore project.godot src/main LICENSES third_party
git commit -m "build: initialize Godot project and pinned dependencies"
```

### Task 2: Build a Godot-independent ocgcore lifecycle wrapper

**Files:**
- Create: `native/CMakeLists.txt`
- Create: `native/include/ygo/duel_session.hpp`
- Create: `native/src/duel_session.cpp`
- Create: `native/tests/test_duel_session.cpp`
- Create: `scripts/build_native.sh`

**Interfaces:**
- Consumes: ocgcore C API from `third_party/ygopro-core/ocgapi.h`.
- Produces: `ygo::DuelSession::core_version() -> std::pair<int, int>`.
- Produces: `ygo::DuelSession::create(uint64_t seed) -> CreateResult`.
- Produces: `ygo::DuelSession::destroy() noexcept` and `is_active() const noexcept`.

- [ ] **Step 1: Write the failing native lifecycle test**

Create `native/tests/test_duel_session.cpp`:

```cpp
#include "ygo/duel_session.hpp"
#include <cassert>

int main() {
    const auto [major, minor] = ygo::DuelSession::core_version();
    assert(major >= 0);
    assert(minor >= 0);

    ygo::DuelSession session;
    assert(!session.is_active());
    const auto result = session.create(0x59474fULL);
    assert(result.ok);
    assert(session.is_active());
    session.destroy();
    assert(!session.is_active());
    session.destroy();
    assert(!session.is_active());
}
```

- [ ] **Step 2: Configure and run the test to verify it fails**

Run:

```bash
cmake -S native -B build/native -DCMAKE_BUILD_TYPE=Debug
cmake --build build/native --target test_duel_session
```

Expected: FAIL because `ygo/duel_session.hpp` or `DuelSession` does not exist.

- [ ] **Step 3: Declare the narrow lifecycle interface**

Create `native/include/ygo/duel_session.hpp`:

```cpp
#pragma once
#include <cstdint>
#include <string>
#include <utility>

namespace ygo {
struct CreateResult {
    bool ok = false;
    int status = -1;
    std::string message;
};

class DuelSession final {
public:
    DuelSession() = default;
    ~DuelSession();
    DuelSession(const DuelSession&) = delete;
    DuelSession& operator=(const DuelSession&) = delete;

    static std::pair<int, int> core_version();
    CreateResult create(std::uint64_t seed);
    void destroy() noexcept;
    bool is_active() const noexcept;

private:
    void* duel_ = nullptr;
};
}
```

- [ ] **Step 4: Implement RAII and required callbacks**

In `native/src/duel_session.cpp`, include `ocgapi.h`, implement `OCG_GetVersion`, fill every required `OCG_DuelOptions` callback with deterministic test callbacks, seed all required RNG fields from the supplied `uint64_t`, call `OCG_CreateDuel`, and store the returned handle only on success. `destroy()` must call `OCG_DestroyDuel` once and set `duel_` to null. Return the exact ocgcore status code in `CreateResult.status`.

- [ ] **Step 5: Build and run the native test**

Run:

```bash
cmake -S native -B build/native -DCMAKE_BUILD_TYPE=Debug
cmake --build build/native --target test_duel_session -j4
ctest --test-dir build/native --output-on-failure
```

Expected: `100% tests passed, 0 tests failed`.

- [ ] **Step 6: Add the repeatable build script**

Create executable `scripts/build_native.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cmake -S "$repo_root/native" -B "$repo_root/build/native" -DCMAKE_BUILD_TYPE=Debug
cmake --build "$repo_root/build/native" -j4
ctest --test-dir "$repo_root/build/native" --output-on-failure
```

- [ ] **Step 7: Commit**

```bash
git add native scripts/build_native.sh
git commit -m "feat: add RAII wrapper for ocgcore duel lifecycle"
```

### Task 3: Expose the lifecycle wrapper through GDExtension

**Files:**
- Create: `native/include/ygo/ygo_core_bridge.hpp`
- Create: `native/src/ygo_core_bridge.cpp`
- Create: `native/src/register_types.cpp`
- Create: `native/ygo_core.gdextension`
- Modify: `native/CMakeLists.txt`

**Interfaces:**
- Consumes: `ygo::DuelSession`.
- Produces Godot class: `YgoCoreBridge`.
- Produces methods: `get_core_version() -> Dictionary`, `create_duel(seed: int) -> Dictionary`, `destroy_duel() -> void`, `is_duel_active() -> bool`.

- [ ] **Step 1: Write the failing Godot smoke script**

Temporarily replace `src/main/main.gd` with:

```gdscript
extends Control

func _ready() -> void:
    assert(ClassDB.class_exists("YgoCoreBridge"))
    var bridge := YgoCoreBridge.new()
    var version: Dictionary = bridge.get_core_version()
    assert(version.has("major"))
    assert(version.has("minor"))
    var created: Dictionary = bridge.create_duel(0x59474f)
    assert(created.ok)
    assert(bridge.is_duel_active())
    bridge.destroy_duel()
    assert(not bridge.is_duel_active())
    get_tree().quit()
```

- [ ] **Step 2: Run to verify the extension is absent**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Volumes/WD/YGO
```

Expected: FAIL with `YgoCoreBridge` not declared or class not found.

- [ ] **Step 3: Implement and bind `YgoCoreBridge`**

Derive from `godot::RefCounted`. Own one `std::unique_ptr<ygo::DuelSession>`. Bind all four methods with `ClassDB::bind_method`. Convert `CreateResult` to:

```gdscript
{"ok": bool, "status": int, "message": String}
```

Return version as:

```gdscript
{"major": int, "minor": int}
```

Register the class at `MODULE_INITIALIZATION_LEVEL_SCENE` in `register_types.cpp`.

- [ ] **Step 4: Build a universal macOS debug library**

Configure `native/CMakeLists.txt` to build `libygo_core.macos.template_debug.framework` or the exact `.dylib` naming referenced by `native/ygo_core.gdextension`. Build for the current Apple architecture first; do not add Windows targets in this plan.

Run:

```bash
./scripts/build_native.sh
```

Expected: native tests pass and the extension library exists under `bin/macos/`.

- [ ] **Step 5: Run the Godot lifecycle smoke test**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Volumes/WD/YGO
```

Expected: exit code 0 with no GDExtension load, assertion, or memory-lifecycle error.

- [ ] **Step 6: Commit**

```bash
git add native src/main/main.gd
git commit -m "feat: expose ocgcore lifecycle to Godot"
```

### Task 4: Replace the assertion script with a visible diagnostic

**Files:**
- Modify: `src/main/main.gd`
- Test: `src/main/main.gd`

**Interfaces:**
- Consumes: `YgoCoreBridge` methods from Task 3.
- Produces: visible diagnostic text and a clean shutdown lifecycle.

- [ ] **Step 1: Implement the visible diagnostic**

Set the status label to `Godot <engine version> · OCGCore <major>.<minor>`. Create a duel with seed `0x59474f`, append `· duel lifecycle OK` when successful, then destroy it. On failure, display the returned status and message and call `push_error`.

- [ ] **Step 2: Add shutdown safety**

Keep the bridge as a member variable. In `_exit_tree()`, call `destroy_duel()` when `is_duel_active()` returns true.

- [ ] **Step 3: Run headless verification**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Volumes/WD/YGO --quit-after 2
```

Expected: exit code 0 and no `ERROR`, assertion failure, or leaked active duel.

- [ ] **Step 4: Run visual verification through Godot MCP**

Use the Godot MCP to launch `/Volumes/WD/YGO`, capture one screenshot, and read debug output. Verify the window contains `OCGCore` and `duel lifecycle OK`, with no runtime error.

- [ ] **Step 5: Commit**

```bash
git add src/main
git commit -m "test: add visible native bridge diagnostic"
```

### Task 5: Final foundation verification and handoff

**Files:**
- Create: `docs/development/native-build.md`

**Interfaces:**
- Produces: reproducible setup instructions for the next data-provider plan.

- [ ] **Step 1: Document exact setup and build commands**

Document submodule initialization, Godot 4.6.3 path, `./scripts/build_native.sh`, headless launch, and common failures for missing submodules, wrong architecture, missing dynamic libraries, and AGPL license retention.

- [ ] **Step 2: Run the full verification suite from a clean build directory**

Move only `build/native` to a temporary backup, then run:

```bash
git submodule status --recursive
./scripts/build_native.sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Volumes/WD/YGO --quit-after 2
git diff --check
```

Expected: initialized pinned submodules, `100% tests passed`, Godot exit code 0, and no whitespace errors.

- [ ] **Step 3: Confirm working-tree scope**

Run:

```bash
git status --short
```

Expected: only intentional documentation changes remain; pre-existing user deletions must not be restored or staged without explicit approval.

- [ ] **Step 4: Commit**

```bash
git add docs/development/native-build.md
git commit -m "docs: document native OCGCore foundation"
```

- [ ] **Step 5: Record the next planning boundary**

The next plan begins only after this foundation passes. Its scope is `cards.cdb` data callbacks, Lua script loading, dependency/version validation, and one deterministic scripted duel processed without UI.
