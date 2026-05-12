# Developing bitfix

For contributors and folks writing their own fixes.

## Writing your own fix

Each `.lua` in `fixes/` returns a single table:

```lua
return {
    name = "My Fix",
    description = "what the fix does (shown as a comment in bitfix.cfg)",
    category = "crash",   -- "crash", "gameplay", "visual", or any custom category
    role = "host",        -- "host" or "client" (defaults to "host" if omitted)
    default = false,      -- on by default if true; user can still override in bitfix.cfg
    patches = {
        {
            pattern = '48 89 5C 24 ?? ...',   -- AOB; '??' is a wildcard byte
            match = function(ctx)
                -- ctx:address() = address of this match
                -- ctx:index() = which occurrence (0-based) within this scan
                -- ctx[addr] = byte at addr (read or write)
                ctx[ctx:address() + 0x10] = 0xEB
            end
        },
    }
}
```

See the existing files in `fixes/` for working examples covering nop, jmp, immediate-byte, and conditional-branch patches.

### Metadata fields

| field | type | required | notes |
|---|---|---|---|
| `name` | string | no | display name; defaults to filename if omitted |
| `description` | string | no | shown as inline comment in `bitfix.cfg` |
| `category` | string | no | groups in `bitfix.cfg`. Conventions: `crash`, `gameplay`, `visual`, `other` |
| `role` | string | no | `host` or `client`; renders as `[host-side]` / `[client-side]` tag in `bitfix.cfg`. Defaults to `host`. |
| `default` | bool | no | initial enabled state when the user has no `bitfix.cfg` entry for this fix yet. Defaults to `false`. |
| `patches` | table | **yes** | sequence of `{ pattern, match }` entries |

### MatchContext methods

The single argument passed to each `match = function(ctx) ... end` exposes:

- `ctx:address()` — the absolute virtual address of the pattern match
- `ctx:index()` — which occurrence this is (0-based) within the current scan
- `ctx[addr]` — read or write the byte at `addr` (uses Lua `__index` / `__newindex` metamethods)

## Building

Rust nightly (pinned via `rust-toolchain.toml`).

```shell
cargo build --release
cargo test                              # runs the in-tree test suite
cargo test test_lua -- --nocapture      # see println/log output from the lua test
```

Output is `target/release/bitfix.dll`. CI cross-compiles for `x86_64-pc-windows-gnu` on every push to `master` and publishes a release zip with the DLL renamed to `winmm.dll`.

## Continuous releases

Every push to `master` triggers `.github/workflows/release.yml` and produces a new release tagged `v{cargo_version}-{sha7}`. The zip is uploaded under the stable filename `bitfix.zip` so the URL `releases/latest/download/bitfix.zip` always points to the newest build. Old releases are retained as backups.

## Why winmm.dll

bitfix is a proxy DLL that gets loaded by the game in place of a real system DLL. The proxy forwards every export call to the real system DLL, so the game runs normally while bitfix's `DllMain` gets to run code at startup.

We hijack `winmm.dll` because:

1. UE4 imports `winmm` eagerly for multimedia timing (`timeGetTime`, etc.), so it loads early and reliably. We tested `xinput1_3.dll` first because UE4 does also use xinput; turns out DRG's xinput load is lazy/conditional and our DLL never got pulled in. `winmm` loads at exe-init time, which is what we need.
2. [mint](https://github.com/trumank/mint), the third-party DRG mod manager, deploys its own combined loader at `d3d11.dll` (which also embeds an old bitfix v0.1.0 inside it). Using `winmm.dll` keeps us out of mint's way and lets both run together: mint's embedded v0.1.0 sees no `bitfix/` directory and exits cleanly, then our v0.2.0 runs from `fixes/`.

`proxy_dll` ships def files for `d3d9`, `d3d11`, `x3daudio1_7`, `xinput1_3`, `winmm`, `version`, `msvcp140`, `vcruntime140`. To change which one bitfix hijacks, edit the macro invocation in `src/lib.rs`.

## Patternsleuth scanner

Patterns are compiled and scanned by [`patternsleuth_scanner`](https://github.com/trumank/patternsleuth) (also trumank's). The syntax is AOB: hex bytes plus `??` wildcards. The whole game image (one mapped page covering the full module) is scanned once with all enabled patterns at startup.

## Crate dependencies

`patternsleuth_scanner` and `proxy_dll` are pulled directly from `trumank`'s GitHub. There is no published crates.io version. `cargo update -p patternsleuth_scanner` re-pulls from git.
