--[[ Makes DRG's GC FastReferenceCollector skip a token-stream reference
     slot whose pointer is null OR has its sign bit set (poison / garbage /
     non-canonical), instead of dereferencing it and crashing.

  =================== Crash this targets ===================

    Unhandled Exception: EXCEPTION_ACCESS_VIOLATION reading address
    0xFFFFFFFFFFFFFFFF   deep-rock-galactic@v141575

  Observed (3/3 same fault site):

      2026-05-14 22:03 PDT  SecondsSinceStart 58   (join modded host)
      2026-05-30 20:17 PDT  SecondsSinceStart 4623 (~77 min into session)
      2026-05-30 20:19 PDT  SecondsSinceStart 31   (relaunch + rejoin)

      PCallStackHash : 36E75CD1571B9A5581294C6CAFCA237753463C50
      Top frame      : FSD+0x1e49b80  (FUN_141e49770 +0x410)
      FUN_141e49770  : UE4 FastReferenceCollector GC token-stream walker
      Faulting addr  : 0xFFFFFFFFFFFFFFFF (kernel-recorded, both 5/30 dumps)

  This is "Family C" in the bitfix workbench notes -- a class-mismatch
  GC crash. Full RE writeup:
    C:\Users\m\drg-bitfix\family-c-recurrence-2026-05-30.md
    C:\Users\m\drg-bitfix\crash-2026-05-14-gc-mismatch.md
    C:\Users\m\drg-bitfix\NOTES.md  (section "Family C")

  =================== Root cause ===================

  When a modded host's pak content can't be fully resolved client-side,
  FAsyncPackage::FindExistingImport logs a class mismatch (e.g.
  "PlayerMovementComponent != CharacterMovementComponent") but STILL
  installs the wrong-class object into the import slot (GSG's compiled
  "log + allow" policy). Callers then read that object's fields using the
  DECLARED class layout; reads past the actual object's size land in
  adjacent heap. A poisoned UObject* slot can end up holding
  0xFFFFFFFFFFFFFFFF (an allocator poison-fill / sentinel value).

  Later, the GC worker thread (FastReferenceCollector) walks that object's
  reference token stream. For each object-reference token it loads the
  slot pointer and dereferences `pObj->InternalIndex` at +0xC to index
  GUObjectArray. If the slot reads 0xFFFFFFFFFFFFFFFF, the deref AVs
  reading [-1+0xC] -> fatal crash.

  =================== The fault site, decompiled ===================

  The token-reference case of the walker (one of ~24 byte-identical
  instances across FastReferenceCollector and its siblings):

      RAX = *(slot)                 ; loaded UObject* from token stream
      pool_lo <= RAX < pool_hi ?    ; sets CL = "in GUObjectArray pool"
      if (RAX == 0)      goto skip; ; +0x3FF  TEST RAX,RAX / JZ  continue
      if (in_pool)       goto skip; ; +0x408  TEST CL,CL  / JNZ continue
      idx = RAX->InternalIndex;     ; +0x410  MOV EAX,[RAX+0xc]  <-- AV
      ... index GUObjectArray[idx], check flags, maybe clear slot ...
  skip/continue:                    ; advance token stream, next token

  The existing null guard catches RAX == 0. NOTHING catches RAX == -1
  (the range guard's pool bounds were degenerate/empty at crash time, so
  -1 falls through to the deref). A dedicated guard is required.

  Exact bytes at the confirmed crash site (RVA 0x1e49b6f, verified against
  FSD-Win64-Shipping.exe on disk):

      1e49b6f  48 85 C0              TEST RAX,RAX
      1e49b72  0F 84 96 FE FF FF     JZ   0x1e49a0e   ; null -> skip
      1e49b78  84 C9                 TEST CL,CL
      1e49b7a  0F 85 8E FE FF FF     JNZ  0x1e49a0e   ; in-pool -> skip
      1e49b80  8B 40 0C              MOV  EAX,[RAX+0xc] ; <-- FAULT

  =================== The patch ===================

  One byte per site: change the null-guard `JZ` to `JLE`.

      0F 84  (JZ  rel32)  ->  0F 8E  (JLE rel32)

  `TEST RAX,RAX` sets OF=0, ZF=(RAX==0), SF=bit63(RAX). `JLE` branches on
  `ZF=1 OR (SF != OF)` = `ZF=1 OR SF=1`. So after the swap the guard skips
  the slot when:

      RAX == 0                     (unchanged: original null case), OR
      bit63(RAX) is set            (any negative / non-canonical pointer,
                                    including 0xFFFFFFFFFFFFFFFF)

  The branch displacement bytes are untouched, so it still targets the
  same continue label -- which is exactly "skip this reference, advance
  the token stream." Same destination both existing guards already use.

  Why this is safe for legitimate objects:

  - All valid x64 user-mode heap pointers are < 0x0000_8000_0000_0000
    (bit63 clear, i.e. non-negative). They still fall through to the deref
    unchanged. The patch cannot skip a real object.
  - Any pointer with bit63 set is a kernel-space / non-canonical address
    that the deref would AV on regardless. Treating it as "skip" is
    strictly safer than dereferencing it -- and semantically correct for
    GC (a slot that can't be a real UObject contributes no references).
  - This does NOT touch FindExistingImport's "log + allow" policy (the C1
    site we deliberately left alone, because nulling mismatched imports
    breaks legitimate subclass mods). It only hardens the GC consumer (C2)
    against the impossible-pointer case. The class-mismatch log spam still
    appears; the game just stops dying when GC walks a poisoned slot.

  =================== Why all 24 sites ===================

  The `TEST RAX,RAX / JZ continue / TEST CL,CL / JNZ continue /
  MOV EAX,[RAX+0xc]` idiom appears 24 times across FastReferenceCollector
  and sibling collectors (the per-token-type cases of the GC walk). All 24
  were verified to have:

    - the pool-bounds compare (`48 3B 05 ...`) immediately preceding, and
    - the JZ and JNZ both targeting the SAME continue label.

  So at every site, "null OR in-pool -> skip" is the established meaning,
  and extending the null-skip to "null OR poison -> skip" is identical in
  intent. Only ONE site (0x1e49b6f) is the confirmed crash; the other 23
  are the same latent bug and would crash with their own PCallStackHash if
  a poisoned slot were walked through a different token case. Patching the
  whole family mirrors drg_expanding_array_uncap.lua (which fixed all 54
  Resize<T> sites from a single observed crash).

  =================== Verification ===================

  - FaultingAddress 0xFFFFFFFFFFFFFFFF confirmed in BOTH 2026-05-30
    full-memory dumps via the exception stream's own ThreadContext
    (kernel ExceptionInformation[1]); RIP == FSD+0x1e49b80 in both.
  - Patch-site bytes confirmed byte-for-byte against the on-disk exe.
  - JZ at 0x1e49b72 confirmed to target 0x1e49a0e (the loop-continue
    label). JZ->JLE keeps the displacement, so the target is preserved.
  - Exact pattern (with both specific rel32s) matches exactly 1 site (the
    crash). rel32-wildcarded pattern matches 24 sites; all 24 carry 0x84
    (JZ opcode2) at pattern offset +4 and the shared-target property above.

  Expected matches: 24. Confirm via bitfix.txt -- one write line per match.
  If the count drops well below 24, the build shifted; re-verify the
  pattern against the new FSD-Win64-Shipping.exe.

  =================== Cost ===================

  - 24 single-byte writes at process startup; microseconds via bitfix.
  - Zero runtime overhead: JLE costs the same as JZ; the only behavior
    change is on pointers that would otherwise crash.
  - No memory cost.

  =================== Caveats ===================

  - This is a SAFETY NET, not a cure for the corruption. The wrong-class
    objects still get installed by C1; GC just no longer dies walking a
    poisoned slot. Other consumers of the same corrupted object (not GC)
    could still misbehave -- but no other crash signature has been
    observed from this corruption, and the GC walk is where it manifests.
  - If a future crash shows a poisoned slot that is small-but-positive
    (e.g. 0x0000000000000008, bit63 clear), JLE won't catch it. Not seen;
    the observed poison value is -1, which JLE catches.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"
  Expected matches: 24.
]]

return {
    name = "DRG GC Poison-Reference Skip",
    description = "GC FastReferenceCollector skips null/poison (sign-set) reference slots instead of crashing (fixes 'AV reading 0xFFFFFFFFFFFFFFFF' from class-mismatch corruption on modded hosts)",
    category = "crash",
    role = "client",
    default = true,
    patches = {
        {
            -- The GC token-reference guard idiom (24 byte-identical sites).
            -- rel32 displacements wildcarded so the single pattern matches
            -- every instance; the JZ opcode2 we patch is at offset +4.
            --
            --   +00..02  48 85 C0              TEST RAX,RAX     ; RAX = slot ptr
            --   +03      0F                     (JZ rel32, byte 1)
            --   +04      84                     (JZ rel32, byte 2)  <- patch +04: 84 -> 8E
            --   +05..08  ?? ?? ?? ??            (JZ rel32 displacement -> continue)
            --   +09..0A  84 C9                  TEST CL,CL       ; in-pool flag
            --   +0B..0C  0F 85                  (JNZ rel32)
            --   +0D..10  ?? ?? ?? ??            (JNZ rel32 displacement -> same continue)
            --   +11..13  8B 40 0C               MOV EAX,[RAX+0xc] ; the deref that AVs
            pattern = '48 85 C0 0F 84 ?? ?? ?? ?? 84 C9 0F 85 ?? ?? ?? ?? 8B 40 0C',
            match = function(ctx)
                -- 0F 84 (JZ rel32) -> 0F 8E (JLE rel32). Displacement bytes
                -- unchanged, so the branch still hits the continue label.
                -- After TEST RAX,RAX, JLE skips when RAX==0 (orig null case)
                -- or bit63(RAX) set (poison / non-canonical, incl. -1).
                ctx[ctx:address() + 4] = 0x8E
            end
        }
    }
}
