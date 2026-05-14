--[[ SPECULATIVE: RET-out three additional analytics event-builder functions
     that match the shape of the function `increased_players_crash_fix` already
     targets. Hypothesis: same fixed-size-buffer-for-4-players bug, different
     event in the mission lifecycle.

  =================== Why this exists ===================

  Modded DRG still crashes with 8+ players in the lobby even after
  `increased_players_crash_fix.lua` is enabled. Reports describe the crash
  as getting "a little farther into the game" before firing -- past lobby
  load, into actual play. The existing crash fix RET-outs a single analytics
  function: the `mission_start_data` builder at RVA 0x1922310, identified via
  the wide-string literals `"mission_start_data: %s"` and
  `"mission_start_data part4: %s"` and a fixed-size payload that overflows
  when there are more per-player stat slots to fill than the buffer was
  sized for.

  A targeted recon pass found three other functions in the same tight
  RVA cluster (0x191e8d0 .. 0x19238ab) with the identical shape:

  - Large bodies (1KB .. 7.8KB)
  - Reference an analytics format string of the form `<event>_data: %s`
  - Gated by `if (2 < <verbosity-global>) { Log(... format_string ...) }`
  - Dispatch via a vtable call on `param_1[6]` (the analytics-service ref)
  - Return void

  =================== The three targets ===================

  All three are early-RET'd via `ctx[ctx:address()] = 0xC3`. Each function
  is void-return and its only side effect is firing a telemetry event;
  skipping is a no-op from the game's perspective. Risk is low.

    1) `game_start_data` builder at RVA 0x191e8d0  (7797 bytes)
         Fires at session enter. The biggest of the three. Likely
         iterates per-player to record initial loadouts / season stats.
         Two callers in this build chain.

    2) `mission_end_data` builder at RVA 0x1920750  (7104 bytes)
         Fires at mission outcome -- success/fail/extraction completion.
         **Highest-probability match for the "crashes a little farther
         into the game" symptom**, because the trigger point is at the
         end of an actual mission rather than at session/mission start.
         Per-player end-of-mission stats serialisation looks like
         exactly the shape that would overflow.

    3) `season_item_unlock_data` builder at RVA 0x1923590  (1002 bytes)
         Fires on individual unlock events. Small, no obvious per-player
         loop. Lower likelihood of being the trigger but included for
         completeness because it sits in the same cluster and is
         RET-safe.

  =================== Status: SPECULATIVE ===================

  None of these patches has been verified against a crash dump. Keep this
  fix DEFAULT OFF. To test: set `drg_analytics_silencer = true` in
  bitfix.cfg, then play with 8+ players and observe whether the crash
  moves, disappears, or persists. Report back here so we can either
  promote individual patches to default-on (probably moving the verified
  one into `increased_players_crash_fix.lua`) or archive them in
  `fixes/broken/`.

  When/if we get a real dump:
  - if any of these functions appears on the crashing thread's stack
    (look for a return address in the function's RVA range), that's
    our trigger. Promote it.
  - if the crash is in totally different code, disable this fix and
    leave the patterns archived for future reference.

  =================== Why early-RET is safe ===================

  Each target function's prologue performs only:
   - one or more `push reg` (saves callee-preserved registers)
   - `lea rbp, [rsp+disp]` (frame pointer setup)
   - `sub rsp, imm32` (frame allocation)
   - security-cookie load + xor + store

  Returning before any of those have side-effected anything is safe:
  the caller's stack is unchanged, no registers we'd preserve have been
  spilled, no externally-visible side effect has occurred. The function
  becomes a no-op that returns immediately. The byte we flip is the
  first byte of the prologue, so execution sees `RET` (`0xC3`) before
  doing anything else.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"

  Each pattern verified against this build to match **exactly one site**
  at the expected RVA. If a future game build shifts the prologue, bitfix
  silently skips ("no pattern match") and the patch becomes a no-op.

  The RIP-relative immediate inside `mov rax, [rip+disp32]` (the security-
  cookie load) is wildcarded because that offset changes between builds
  while the surrounding instructions remain stable.
]]

return {
    name = "DRG Analytics Silencer (Speculative)",
    description = "Speculative: RET-out 3 sibling analytics builders (mission_end, game_start, season_item_unlock) that may overflow with 8+ players. Untested. Opt-in.",
    category = "crash",
    role = "host",
    default = false,
    patches = {
        -- game_start_data builder @ RVA 0x191e8d0
        --   00..01  40 55                   push  rbp        ; <- patch byte 0
        --   02..03  41 55                   push  r13
        --   04..0B  48 8D AC 24 B8 FC FF FF lea   rbp, [rsp-0x348]
        --   0C..12  48 81 EC 48 04 00 00    sub   rsp, 0x448
        --   13..19  48 8B 05 ?? ?? ?? ??    mov   rax, [rip+disp32]   ; security cookie
        --   1A..1C  48 33 C4                xor   rax, rsp
        {
            pattern = '40 55 41 55 48 8D AC 24 B8 FC FF FF 48 81 EC 48 04 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4',
            match = function(ctx)
                ctx[ctx:address()] = 0xC3
            end
        },

        -- mission_end_data builder @ RVA 0x1920750  ** highest-probability target **
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
        },

        -- season_item_unlock_data builder @ RVA 0x1923590
        --   00..04  48 89 5C 24 18          mov   [rsp+0x18], rbx   ; <- patch byte 0
        --   05      55                      push  rbp
        --   06      56                      push  rsi
        --   07      57                      push  rdi
        --   08..09  41 54                   push  r12
        --   0A..0B  41 57                   push  r15
        --   0C..10  48 8D 6C 24 C9          lea   rbp, [rsp-0x37]
        --   11..17  48 81 EC A0 00 00 00    sub   rsp, 0xA0
        {
            pattern = '48 89 5C 24 18 55 56 57 41 54 41 57 48 8D 6C 24 C9 48 81 EC A0 00 00 00',
            match = function(ctx)
                ctx[ctx:address()] = 0xC3
            end
        }
    }
}
