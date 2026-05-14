--[[ Fix crash at mission end when >8 players were in the lobby.

  Companion fix to `increased_players_crash_fix.lua`. That fix neutralises
  the crash at mission START (in the `mission_start_data` analytics builder).
  This one neutralises the same family of crash at mission END (in the
  `mission_end_data` analytics builder) -- they share the underlying buggy
  code path so they fail the same way.

  =================== Why ===================

  The original `increased_players_crash_fix` RET-outs `mission_start_data`,
  a 4727-byte analytics-event builder. With that fix applied, modded
  >8-player lobbies stopped crashing at mission start, but kept crashing
  "a little farther into the game" -- specifically at mission completion.

  A reverse-engineering pass identified three per-player data-gathering
  helpers that `mission_start_data` invokes:

      FUN_14190dea0  (1913 bytes, player loadout)
      FUN_14190cd50  (2083 bytes, per-player stats TArray)
      FUN_14190f540  (2547 bytes, bit-manipulation loops)

  A caller graph reveals these helpers are shared by exactly two analytics
  builders, and no others:

      helper            mission_start  mission_end  game_start  season_item_unlock
      FUN_14190dea0          yes          yes           no            no
      FUN_14190cd50          yes          yes           no            no
      FUN_14190f540          yes          yes           no            no

  Whatever bug fires inside one or more of these three helpers when player
  count exceeds vanilla's 4-player assumption also fires when called from
  `mission_end_data`. The crash that used to hit at mission start now hits
  at mission completion, because that's where the same helpers fire next.

  =================== What this patch does ===================

  Same shape as the original: rewrite the first byte of `mission_end_data`
  to `0xC3` (RET). The function then returns immediately without invoking
  any of the helpers. The only side effect is suppressing the mission-end
  telemetry event -- the game state is unchanged.

  Verified safe: the function is void-return and its prologue's first byte
  is `0x40` (REX prefix of `push rbp`), so writing `0xC3` before any
  register has been saved or any stack frame allocated is clean. The
  function becomes a no-op.

  =================== Pair this with ===================

  - `increased_players_crash_fix.lua` (the mission-start side of the
    same bug). One without the other only delays the crash.
  - `increased_players_difficulty_scaling_fix.lua` (lifts the 4-player
    cap on difficulty-scaling tables -- needed for >4 players to be
    handled at all, regardless of the crash fixes).

  =================== Where the actual bug is ===================

  Not yet pinpointed surgically. The three helpers' top-level loops are
  dynamically sized (`memcpy(dst, src, count*8)` with heap-allocated
  destinations, output TArrays grown via `FUN_14098b180`, no `cmp r, 4`
  bounds anywhere visible). The crash is somewhere INSIDE per-player
  sub-operations -- one of `FUN_14174a120`, `FUN_141749a90/b70` and
  friends has a fixed-size assumption that we haven't isolated.

  If a future RE pass identifies the specific bug, a surgical patch in
  the helper itself would let both `mission_start_data` and
  `mission_end_data` run their telemetry. Until then, RET'ing out both
  builders is the lowest-risk way to dodge the crash entirely.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"

  The pattern is verified against this build to match **exactly one site**
  at the expected RVA (0x1920750). If a future game build shifts the
  prologue, bitfix silently skips ("no pattern match") and the patch
  becomes a no-op.

  The RIP-relative immediate inside `mov rax, [rip+disp32]` (the security-
  cookie load) is wildcarded because that offset changes between builds
  while the surrounding instructions remain stable.
]]

return {
    name = "Increased Players Mission End Crash Fix",
    description = "Fix crash at mission end when >8 players are in the lobby (companion to increased_players_crash_fix)",
    category = "crash",
    role = "host",
    default = true,
    patches = {
        -- mission_end_data builder @ RVA 0x1920750
        --   00..01  40 55                   push  rbp        ; <- patch byte 0
        --   02      53                      push  rbx
        --   03..04  41 55                   push  r13
        --   05..06  41 57                   push  r15
        --   07..0E  48 8D AC 24 78 FE FF FF lea   rbp, [rsp-0x188]
        --   0F..15  48 81 EC 88 02 00 00    sub   rsp, 0x288
        --   16..1C  48 8B 05 ?? ?? ?? ??    mov   rax, [rip+disp32]   ; security cookie
        --   1D..1F  48 33 C4                xor   rax, rsp
        {
            pattern = '40 55 53 41 55 41 57 48 8D AC 24 78 FE FF FF 48 81 EC 88 02 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4',
            match = function(ctx)
                ctx[ctx:address()] = 0xC3
            end
        }
    }
}
