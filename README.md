# bitfix

A small Lua-scriptable runtime binary patcher for Windows games. Ships with a curated set of fixes for **Deep Rock Galactic**.

Compatible with [mint](https://github.com/trumank/mint), the third-party DRG mod manager. mint and bitfix coexist; you can run both.

## Install (and update)

1. Download [bitfix.zip](https://github.com/UberKitten/bitfix/releases/latest/download/bitfix.zip).
2. Find the folder containing the game's `.exe`. For Deep Rock Galactic on Steam:
   - Right-click DRG in Steam, **Manage > Browse local files**
   - Open `FSD\Binaries\Win64\`. You should see `FSD-Win64-Shipping.exe` in there.
   - On a default Windows + Steam setup this folder is `C:\Program Files (x86)\Steam\steamapps\common\Deep Rock Galactic\FSD\Binaries\Win64\`.
3. Extract everything from the zip into that folder, replacing existing files when prompted.
4. Launch the game. Crash fixes apply automatically. A `bitfix.cfg` file and a `bitfix.txt` log are created next to the game `.exe` on first launch.

**Don't drop the files in the top-level `Deep Rock Galactic\` folder.** That folder also contains an `FSD.exe` (a small launcher), but bitfix has to sit next to the real game executable at `FSD\Binaries\Win64\FSD-Win64-Shipping.exe`. If `bitfix.txt` never appears after launching, you probably installed one level too high.

**Updating is the same process** — download the latest zip and extract over the top. Your `bitfix.cfg` toggles are preserved.

## Linux / Proton / Steam Deck

Install the files exactly as above, then add one extra step: Proton won't load the files unless you tell it to. If the game launches but no `bitfix.cfg` or `bitfix.txt` shows up, this is why.

In Steam, right-click **Deep Rock Galactic > Properties > General > Launch Options** and paste one of these in:

**bitfix only:**

```
WINEDLLOVERRIDES="winmm=n,b" %command%
```

**bitfix and [mint](https://github.com/trumank/mint) together:**

```
WINEDLLOVERRIDES="winmm=n,b;x3daudio1_7=n,b" %command%
```

Then launch the game. `bitfix.cfg` and `bitfix.txt` should show up next to the game `.exe` like normal.

## Uninstall

Delete `winmm.dll` and the `fixes/` folder from your game folder. The game goes back to vanilla. You can also delete `bitfix.cfg` and `bitfix.txt` if you want a clean wipe.

## Enabling and disabling fixes

The first time you launch the game after installing, bitfix creates a `bitfix.cfg` file next to the game `.exe`. Open it in Notepad. It will look something like:

```
# === Crash Fixes ===
drg_csg_arena_bump                        = true   # [client-side] Add +2 GiB of reserved VA to every FSDVirtualMem arena...
drg_expanding_array_uncap                 = true   # [client-side] Dead-code the hardcoded MAXSIZE check...
drg_gc_poison_ref_skip                    = true   # [client-side] GC skips null/poison reference slots instead of crashing (modded-host class-mismatch AV)...
increased_players_crash_fix               = true   # [host-side] Fix crash when >8 players in lobby...
increased_players_difficulty_scaling_fix  = true   # [host-side] Allow difficulty scaling beyond 4 players...
increased_players_mission_end_crash_fix   = true   # [host-side] Fix crash at mission end when >8 players in lobby...

# === Gameplay ===
max_attackers                = false  # [host-side] Raise simultaneous-attacker cap to 200
no_scatter                   = false  # [host-side] Prevent explosions from scattering minerals
non_flare_devouring_drop_pod = false  # [host-side] Stop the drop pod from eating flares
stickier_flame               = false  # [host-side] Sticky flames stick to any actor, not just terrain

# === Visual ===
normal_terrain_scanner_mat = false  # [client-side] Show normal terrain on the scanner instead of scanner material
```

Flip `false` to `true` for any fix you want, save the file, then launch the game.

**Role tags** tell you when a fix actually does something:

- `[host-side]` only takes effect on the host's machine. Turning one on while you join someone else's lobby is harmless but does nothing.
- `[client-side]` takes effect on your local machine regardless of who hosts.

Crash fixes are on by default. Everything else is off.

## Will this slow down my game?

No measurable in-game impact. bitfix does all of its work once while the game is starting up. It scans the game binary for the patterns of each enabled fix, writes a few bytes per match, and is done. There's no hook, no callback, and no Lua running during gameplay; the patches are just static byte changes to the binary in memory.

Startup adds maybe a second or two while the pattern scan runs. That's it.

## Something broken?

1. Check `bitfix.txt` next to the game `.exe`. It logs every loaded fix, every pattern match, and any errors.
2. If a fix's pattern didn't match the current game build, you'll see `no pattern match for <fix>/<label>` in the log. Disable that fix in `bitfix.cfg` and report it.
3. To rule out bitfix entirely, delete `winmm.dll` from the game folder and launch.

### Catching new crashes

When a fresh crash shows up that nobody has a fix for yet, the most useful thing you can do is collect a **full crash dump** and share it.

To enable full dumps:

1. In Steam, right-click **Deep Rock Galactic > Properties**.
2. Under **General > Launch Options**, add: `-fullcrashdumpalways`
3. Close Properties. The next time the game crashes, a full dump is written automatically.

To find the dump:

1. Right-click DRG in Steam, **Manage > Browse local files**.
2. Open `FSD\Saved\Crashes\`. On a default Windows + Steam setup this is `C:\Program Files (x86)\Steam\steamapps\common\Deep Rock Galactic\FSD\Saved\Crashes\`.
3. Each crash is its own timestamped subfolder containing the dump (`.dmp`), a log, and metadata. Zip up the whole subfolder if you want to share.

**Warning:** full dumps are large. Each one is typically 2-5 GB and they pile up fast. Clear the `Crashes\` folder periodically, or remove `-fullcrashdumpalways` from launch options once you've captured what you need. Without that flag, the game writes much smaller minidumps that often miss the data you'd need to diagnose a new crash.

## For developers

See [DEVELOPING.md](DEVELOPING.md) for how to write your own fixes and build from source.

## License

MIT. See [LICENSE](LICENSE).
