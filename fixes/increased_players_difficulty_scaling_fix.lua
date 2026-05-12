--[[ Lift the hard-coded 4-player cap on DRG's difficulty-scaling tables.

  =================== What this fixes ===================

  DRG's difficulty system reads scaling values out of arrays indexed by the
  active player count.  Throughout the difficulty subsystem, the code
  computes the index as `min(player_count, 4)` so the array reads never
  exceed the hard-coded design assumption of 1..4 players.

  With 8+ players in a lobby (mods like trumank's increased_players_fix
  remove the lobby cap), the scaling falls off the end of those arrays
  unless we patch every clamp site to allow indices up to 255.  Without
  this fix, difficulty stays pinned at the 4-player table values regardless
  of how many extra dwarves are running around.

  This patch pairs with trumank's `increased_players_fix.lua` (which makes
  the lobby itself allow >4 players).  Neither helps without the other.

  =================== How it works ===================

  Every clamp site in the difficulty code uses the standard MSVC
  "max with immediate" idiom built around CMOVcc:

      mov  reg, 4              ; load the floor (4) into a scratch register
      cmp  N, reg              ; compare current player count
      cmovge / cmovle ...      ; pick the larger of N or 4

  The compiler emits this in several variants depending on register
  allocation, whether the operand comes from a register or memory, and
  whether the result lands back in the same register or a different one.
  Across this build, the difficulty code contains FIFTEEN such sites
  with four distinct byte shapes.  We patch the immediate-4 to immediate-255
  at every site, which raises the floor of the clamp from 4 to 255 and
  thereby lets the index reflect the true player count (DRG supports up to
  this many players via the lobby patch).

  Patching the single immediate byte is sufficient because:
    - All four shapes encode the 4 as a 32-bit `mov reg, imm32` opcode
      family (0xB8..0xBF).  The four bytes after the opcode are
      little-endian imm32; the low byte being 0x04 with the rest zero
      means the immediate IS 0x00000004.  Flipping the low byte to 0xFF
      with everything else still zero turns it into 0x000000FF = 255.
    - 255 fits comfortably in `int`, doesn't trigger sign-extension issues
      (the high bit of the imm32 is still 0), and is far higher than any
      sane game will ever reach.

  =================== Per-pattern documentation ===================

  Hits in this build (FSD-Win64-Shipping.exe, build CL 141575):

    Pattern  Variant                                                 Hits
    -------  ------------------------------------------------------  ----
    #1       mov edx, 4 / cmp eax, edx / cmovle edx, eax               2
    #2       mov ecx, 4 / cmp eax, ecx / cmovle ecx, eax              12
    #3 (*)   load-then-mov-imm form -- see notes below                 1
    #4       mov ecx, 4 / mov eax, [rax+0x8] / cmp / cmovge eax,ecx    1
                                                              total = 16

  (*) Pattern 3 in earlier versions of this fix did NOT match this build.
  See the long-form note below.

  ----- Pattern #1 -----
    pattern: ba 04 00 00 00 3b c2 0f 4e d0
    decode:
      ba 04 00 00 00     mov   edx, 0x4
      3b c2              cmp   eax, edx
      0f 4e d0           cmovle edx, eax        ; edx = min(eax, 4)
    sites in this build (2):
      RVA 0x1747e15  inside FUN_141747df0  -- a difficulty-table reader
      RVA 0x1747ea0  inside FUN_141747e80  -- another table reader
    patch: flip the byte at match+1 (the 0x04) to 0xff
    effect: floor stays >=4 (originally), now reads as min(eax, 0xff)
            i.e. clamp upper bound is 255 instead of 4

  ----- Pattern #2 -----
    pattern: b9 04 00 00 00 3b c1 0f 4e c8
    decode:
      b9 04 00 00 00     mov   ecx, 0x4
      3b c1              cmp   eax, ecx
      0f 4e c8           cmovle ecx, eax        ; ecx = min(eax, 4)
    sites in this build (12), all inside the same difficulty-switch
    function FUN_141747ed0 and its siblings at 0x1748080..0x174df20.
    These are the bulk of the clamp sites -- one per case-arm in a
    big switch over a 7-way "scaling kind" enum.
    patch: flip the byte at match+1 (the 0x04) to 0xff

  ----- Pattern #3 -----
    -- ORIGINAL PATTERN (kept commented out for archival reference):
    --   pattern: b9 04 00 00 00 8b 80 ?? ?? 00 00 3b c1 0f 4d c1
    --   decode:
    --     b9 04 00 00 00     mov   ecx, 0x4
    --     8b 80 ?? ?? 00 00  mov   eax, [rax+disp32]   ; member load
    --     3b c1              cmp   eax, ecx
    --     0f 4d c1           cmovge eax, ecx           ; eax = max(eax, 4)
    --   In earlier DRG builds this targeted a clamp site where the
    --   player-count value was fetched from a member at a 32-bit
    --   offset *AFTER* the mov-imm-4 was emitted.
    --
    -- WHAT CHANGED IN THIS BUILD:
    -- The compiler swapped the order: the load happens BEFORE the mov-imm-4,
    -- so the byte sequence is now `8b 80 ?? ?? 00 00 b9 04 00 00 00 ...`
    -- (load-first), not `b9 04 ... 8b 80 ?? ?? 00 00 ...` (imm-first).
    -- The semantics are identical -- both compute `eax = max([rax+disp32], 4)`
    -- -- but the AOB scanner is byte-exact and won't match the reordered form.
    --
    -- The site this targets is inside FUN_14174d380, which is the
    -- "get clamped active player count" helper called by every
    -- pattern #2 site as well as several other difficulty readers.
    -- The function has two return branches:
    --   1. via [rbx+0x130] -> load [rax+0x8]   (Pattern #4 handles this)
    --   2. via [rbx+0x138] -> load [rax+0x240] (Pattern #3 handles this)
    -- Without a working Pattern #3, branch 2 of FUN_14174d380 caps at 4.
    --
    -- The REWORKED PATTERN below uses the new load-first byte order and
    -- restores coverage of this site.
    --
    -- See investigation log: 2026-05-11 session; Ghidra postscripts at
    -- C:\Users\m\ghidra-projects\scripts\find_player_clamp_variants.py
    -- and dump_fun_174d380.py.
    --
    -- pattern (new): 8b 80 ?? ?? 00 00 b9 04 00 00 00 3b c1 0f 4d c1
    -- decode:
    --   8b 80 ?? ?? 00 00  mov   eax, [rax+disp32]   ; disp32 is 0x00000240 here
    --   b9 04 00 00 00     mov   ecx, 0x4
    --   3b c1              cmp   eax, ecx
    --   0f 4d c1           cmovge eax, ecx           ; eax = max(eax, 4)
    -- site in this build (1):
    --   RVA 0x174d3d2  inside FUN_14174d380 (the second clamp branch)
    -- patch: flip the byte at match+7 (the 0x04 of `mov ecx, 4`) to 0xff
    --
    -- NOTE the patch offset is DIFFERENT from patterns #1, #2, #4 (which
    -- all patch at +1 because the mov-imm is the first instruction in
    -- their pattern).  Here the mov-imm is at +6, so the imm byte is at +7.

  ----- Pattern #4 -----
    pattern: b9 04 00 00 00 8b 40 08 3b c1 0f 4d c1
    decode:
      b9 04 00 00 00     mov   ecx, 0x4
      8b 40 08           mov   eax, [rax+0x8]   ; disp8 member load
      3b c1              cmp   eax, ecx
      0f 4d c1           cmovge eax, ecx        ; eax = max(eax, 4)
    site in this build (1):
      RVA 0x174d3b3  inside FUN_14174d380 (the first clamp branch)
    patch: flip the byte at match+1 (the 0x04) to 0xff

  =================== Context: FUN_14174d380 ===================

  Patterns #3 and #4 both target the same small helper function -- the
  "get clamped active player count for difficulty indexing" routine.
  Its 0x73-byte body (RVA 0x174d380..0x174d3f2) has two pointer-conditional
  branches that each load a player-count value and clamp it to >=4 before
  returning.  Without patching BOTH branches, half the call sites in the
  difficulty code would still cap at 4 players.  Confirmed via callgraph:
  FUN_14174d380 is called from every Pattern #2 site (FUN_141747ed0 et al)
  as well as ~13 other game state readers.

  =================== Caveat (from upstream README) ===================

  "Make sure all player-count-based arrays in difficulty settings have
  enough values for the player count, or bad things will happen."

  This is real: the patched index may now exceed the number of entries
  in some difficulty-scaling array somewhere, depending on which game
  mode + difficulty + scaling-table is loaded.  If you crash with an
  array-out-of-bounds shortly after spawning with >4 players, this is
  the most likely culprit.  Workarounds: keep player counts in the 5..8
  range to stay close to extrapolations of the existing tables, or
  combine with a mod that supplies extended difficulty tables.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"

  Expected pattern matches in this build:
    Pattern #1: 2 hits
    Pattern #2: 12 hits
    Pattern #3 (load-first, current): 1 hit
    Pattern #3 (imm-first, archival): 0 hits  -- compiler reordered, see notes
    Pattern #4: 1 hit
    Total patch sites: 16

  Verified 2026-05-11 via patternsleuth byte scan + Ghidra disassembly
  cross-check.
]]

-- For patterns 1, 2, 4: the mov-reg-imm32 is the first instruction in the
-- pattern, so the 0x04 immediate sits at offset +1 from the match address.
local patch_imm_at_plus_1 = function(ctx)
    ctx[ctx:address() + 1] = 0xff
end

-- For the reworked pattern 3: the load instruction is FIRST (6 bytes) and
-- the mov-reg-imm32 follows it, so the 0x04 immediate sits at offset +7.
local patch_imm_at_plus_7 = function(ctx)
    ctx[ctx:address() + 7] = 0xff
end

return {
    name = "Increased Players Difficulty Scaling",
    description = "Allow difficulty scaling beyond 4 players (pairs with the crash fix)",
    category = "crash",
    default = true,
    patches = {
        -- Pattern #1: mov edx,4 / cmp eax,edx / cmovle edx,eax  (2 hits)
        { match = patch_imm_at_plus_1, pattern = 'ba 04 00 00 00 3b c2 0f 4e d0' },

        -- Pattern #2: mov ecx,4 / cmp eax,ecx / cmovle ecx,eax  (12 hits)
        { match = patch_imm_at_plus_1, pattern = 'b9 04 00 00 00 3b c1 0f 4e c8' },

        -- Pattern #3 (ORIGINAL imm-first form) -- DOES NOT MATCH IN THIS BUILD.
        -- The compiler reordered the instructions so the load comes before the
        -- mov-imm-4.  Kept commented for archival reference -- see the doc
        -- comment at the top of this file for the full story.  Re-enable
        -- alongside the new pattern if a future build flips the order back.
        --   { match = patch_imm_at_plus_1, pattern = 'b9 04 00 00 00 8b 80 ?? ?? 00 00 3b c1 0f 4d c1' },

        -- Pattern #3 (reworked load-first form for this build, 1 hit at
        -- RVA 0x174d3d2 inside FUN_14174d380 second branch).
        -- Note the different patch offset (+7 instead of +1).
        { match = patch_imm_at_plus_7, pattern = '8b 80 ?? ?? 00 00 b9 04 00 00 00 3b c1 0f 4d c1' },

        -- Pattern #4: mov ecx,4 / mov eax,[rax+0x8] / cmp / cmovge  (1 hit)
        { match = patch_imm_at_plus_1, pattern = 'b9 04 00 00 00 8b 40 08 3b c1 0f 4d c1' },
    }
}
