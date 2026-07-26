# Native build

The project uses a Godot 4.6 GDExtension to expose the real `ygopro-core`
duel lifecycle to GDScript.

## Requirements

- macOS on Apple Silicon
- Godot 4.6.x at `/Applications/Godot.app`
- CMake 3.24 or newer
- An Apple Clang toolchain

## Clone

Initialize every pinned dependency, including the Lua submodule nested inside
`ygopro-core`:

```bash
git submodule update --init --recursive
```

`third_party/godot-cpp` is intentionally pinned to its Godot 4.6-stable API
commit. Do not update it to `master` without also upgrading the project and
installed Godot version.

## Build and test

From the repository root:

```bash
./scripts/build_native.sh
```

The script configures a Debug build in `build/native`, builds the C++ wrapper
and GDExtension, and runs the native lifecycle test. The resulting library is:

```text
bin/macos/libygo_core.dylib
```

## Run

Open `project.godot` in Godot, or run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path /absolute/path/to/YGO
```

The diagnostic screen should report the Godot version, OCGCore version, and
`duel lifecycle OK`.

For a headless smoke test:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless \
  --path /absolute/path/to/YGO \
  --quit-after 2
```

## Local card assets

Large card data and artwork remain local and are ignored by Git:

- `data/cards.json`
- `images/`
- `vendor/`
- `tools/`

Their `.gdignore` marker files are tracked so Godot does not import or scan
those large source trees.
