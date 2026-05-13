# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

bitfix is a Lua-scriptable runtime binary patcher for Windows games. It builds as a `cdylib` that gets dropped next to the target `.exe` under a name the game's loader will pull in. We hijack `winmm.dll` because UE4 imports it eagerly for multimedia timing. We initially tried `xinput1_3.dll` but DRG's xinput load is lazy and the DLL never got loaded; `winmm` loads at exe-init time and works reliably. This also keeps us out of mint's way — mint (the DRG mod loader) deploys its hook at `x3daudio1_7.dll` on Steam / `d3d9.dll` on Xbox (see `mint_lib/src/lib.rs:71` in trumank/mint). mint's hook is built on the same `proxy_dll` + `patternsleuth` stack by the same author but is a separate binary configured for engine-function detours, not for our Lua patches. Proxy DLL forwarding to the real system DLL is handled by the `proxy_dll` crate.

## Build / test

Rust toolchain is pinned to **nightly** via `rust-toolchain.toml` — `rustup` will fetch it automatically.

```shell
cargo build --release                                  # local Windows build
cargo build --release --target x86_64-pc-windows-gnu   # what CI builds (release.yml)
cargo test                                             # runs the in-tree tests
cargo test test_lua -- --nocapture                     # see println/log output from the lua test
```

Releases: pushing to `master` triggers `.github/workflows/release.yml`, which cross-compiles via mingw-w64 and publishes a release tagged `v{cargo_version}-{sha7}`. The zip contains `winmm.dll` (renamed from `bitfix.dll`), `fixes/`, `README.md`, `LICENSE`, and is uploaded under the stable filename `bitfix.zip` so `releases/latest/download/bitfix.zip` always points to the newest build.

## Architecture

Single crate, all code in `src/lib.rs`. Flow:

1. **Entry:** `proxy_dll::proxy_dll!([winmm], init)` generates the `DllMain` and the forwarder exports for `winmm`. The macro arranges for `init()` to fire on attach. If a future game needs a different hijack name, the macro's first arg is the list; `proxy_dll` ships def files for `d3d9`, `d3d11`, `x3daudio1_7`, `xinput1_3`, `winmm`, `version`, `msvcp140`, `vcruntime140`.
2. **`setup()`** initializes a rolling file logger at `<exe_dir>/bitfix.txt` (no console — the host process is the game).
3. **`patch()`** uses `GetModuleHandleA(None)` + `GetModuleInformation` to grab the main module's base/size, wraps it in a `RawMemory` (one page covering the whole image), then loads every `*.lua` file from `<exe_dir>/fixes/`.
4. **`exec_patches()`** is the Lua engine. Each `.lua` returns a table of the form `{ name, description, category, default, patches = { ... } }`. The metadata fields drive the config UX; `patches` is an array (or map) of `{ pattern, match }` entries. Patterns are AOB strings (hex bytes + `??` wildcards) parsed by `patternsleuth_scanner`. After all configs are collected and the enabled-set is resolved (see below), every page is scanned once with the full pattern set; for each match the corresponding `match` closure is called with a `MatchContext` userdata.
5. **`MatchContext`** exposes `ctx:address()` (match address), `ctx:index()` (which occurrence), and `__index` / `__newindex` metamethods so Lua can read/write bytes at absolute addresses: `ctx[ctx:address() + N] = 0xEB`.
6. **Writes** go through `RawMemory::write`, which flips the page to `PAGE_EXECUTE_READWRITE` via `VirtualProtect`, writes one byte, then restores the original protection.

### Config-driven enable/disable

`<exe_dir>/bitfix.cfg` is the user-facing toggle file. It's auto-managed:

- Read on launch (missing is fine — defaults apply).
- Each fix's enabled state = `cfg.get(file_stem).unwrap_or(meta.default)`.
- Rewritten on every launch in canonical form: grouped by `category` (`crash` → `gameplay` → `visual` → `other` → others alphabetical), sorted alphabetically within category, descriptions emitted as inline `# comment`s.
- User-set values are preserved across the rewrite; layout/comments are not — header comment warns about this.
- Cfg entries with no matching `.lua` get parked in a `# === Removed / not found ===` section, commented out, so re-adding the `.lua` restores the toggle.

Default category is `other`; default `enabled` is `false`. Crash fixes opt into `default = true` so non-technical users get them without editing anything.

### The `Memory` trait

`trait Memory` abstracts page storage so the patching logic is testable. `RawMemory` is the production impl (calls `VirtualProtect`); `VirtualMemory` in `mod test` is an in-memory equivalent used by `test_lua`. When changing the patching pipeline, keep both impls in sync or the test will silently diverge from production.

### Pattern dependencies

`patternsleuth_scanner` and `proxy_dll` are pulled directly from `trumank`'s GitHub. There is no published crates.io version — `cargo update -p patternsleuth_scanner` re-pulls from git.

### Build-time git hash

`build.rs` shells out to `git rev-parse HEAD` and exposes it as `GIT_HASH`. If git is unavailable the value falls back to a placeholder string (see commit `80af6c2` — the previous panic-on-missing was fixed).
