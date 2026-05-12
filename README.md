# bitfix

A small Lua-scriptable runtime binary patcher for Windows games. Ships with a curated set of fixes for **Deep Rock Galactic** that load via a proxy DLL.

## Install

1. Download the latest `bitfix-<sha>.zip` from the [releases page](https://github.com/UberKitten/bitfix/releases).
2. Extract the zip somewhere temporary.
3. Find your game's main `.exe`. For Deep Rock Galactic on Steam this is usually:
   ```
   <Steam>\steamapps\common\Deep Rock Galactic\FSD\Binaries\Win64\FSD-Win64-Shipping.exe
   ```
4. Copy these next to that `.exe`:
   - `bitfix.dll` — **rename it to one of:** `d3d9.dll`, `d3d11.dll`, or `x3daudio1_7.dll` (whichever the game loads; for DRG, `x3daudio1_7.dll` works).
   - The `fixes/` folder.
5. Launch the game. bitfix will run, create `bitfix.cfg` next to the game `.exe`, and apply any enabled fixes. A log is written to `bitfix.txt`.

## Enabling / disabling fixes

After the first launch you'll have a `bitfix.cfg` file next to the game `.exe`. Open it in Notepad. It looks like:

```
# Role tags:
#   [host-side]   = effective only when you host the lobby
#   [client-side] = effective on your machine regardless of host

# === Crash Fixes ===
increased_players_crash_fix              = true  # [host-side] Fix crash when >8 players in lobby...
increased_players_difficulty_scaling_fix = true  # [host-side] Allow difficulty scaling beyond 4 players...

# === Gameplay ===
max_attackers                = false  # [host-side] Raise simultaneous-attacker cap to 200
no_scatter                   = false  # [host-side] Prevent explosions from scattering minerals
non_flare_devouring_drop_pod = false  # [host-side] Stop the drop pod from eating flares
stickier_flame               = false  # [host-side] Sticky flames stick to any actor, not just terrain

# === Visual ===
normal_terrain_scanner_mat = false  # [client-side] Show normal terrain on the scanner...
```

Flip a `false` to `true` (or vice versa) for any fix you want, save the file, and launch the game.

Notes:
- **Role tags** tell you when a fix actually does anything. `[host-side]` fixes only take effect on the host's machine — turning one on as a client/joiner is harmless but does nothing. `[client-side]` fixes apply on whoever's screen they affect, regardless of who's hosting.
- Crash fixes are on by default; everything else is off. You don't have to edit anything to get the crash fixes.
- The file is regenerated each launch in canonical form, so any personal comments you add will be removed. Toggled values are preserved.
- Sharing a config? Send a friend your `bitfix.cfg` — they drop it next to the `.exe` and they're done.

## Will this slow down my game?

No measurable in-game impact. bitfix does all of its work once while the game is starting up — it scans the game binary for the patterns of each enabled fix and writes a few bytes per match — then it's done. There's no hook, no callback, and no Lua running during gameplay; the patches are just static byte changes to the binary in memory.

Startup adds maybe a second or two while the pattern scan runs. That's it.

## Uninstall

Delete the file you renamed `bitfix.dll` to (e.g. `x3daudio1_7.dll`) and the `fixes/` folder. The game goes back to vanilla. You can also delete `bitfix.cfg` and `bitfix.txt` if you want a clean wipe.

## Something broken?

1. Check `bitfix.txt` next to the game `.exe` — it logs every loaded fix, every pattern match, and any errors.
2. If a fix's pattern didn't match the current game build, you'll see `no pattern match for <fix>/<label>` in the log. Disable that fix in `bitfix.cfg` and report it.
3. To rule out bitfix entirely, just delete the renamed DLL and launch the game.

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

## Building

Rust nightly (pinned via `rust-toolchain.toml`).

```shell
cargo build --release
```

The output `target/release/bitfix.dll` is the artifact. CI cross-compiles for `x86_64-pc-windows-gnu` on every push to `master` and publishes a release zip.

## License

MIT — see [LICENSE](LICENSE).
