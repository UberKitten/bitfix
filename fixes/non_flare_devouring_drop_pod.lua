--[[ Stop the drop pod from eating flares (and any other RefinerySecondaryObjective
     pickup) when it sucks dwarves up at extraction.

  =================== Behavior this targets ===================

  When the drop pod arrives at extraction and sucks the dwarves in, any flares
  that happen to be in the suction radius get consumed too -- they vanish into
  the pod with no payoff.  Same story for the M.U.L.E.-style team transport
  pickup volume (see "Two match sites" below).  This patch makes both pickup
  volumes silently ignore RefinerySecondaryObjective actors (flares are this
  class) instead of consuming them.

  =================== Two match sites ===================

  Same idiomatic byte sequence appears in two different functions in this
  build.  Both implement the same UE4 "is this actor an instance of
  RefinerySecondaryObjective?" interface-table check before calling a
  destroy/consume helper:

    1) FUN_14182ad20 @ 0x14182ad20  (193 bytes; match at +0xBE = 0x14182adde)
         Pulled in via URefineryExtractorPodWidget::OnObjectiveUpdated
         (confirmed by the wide-string literal in callee FUN_141805c90).
         Class lookups: RefineryExtractorPodWidget, FSDGameMode,
         RefinerySecondaryObjective.

    2) FUN_141899a30 @ 0x141899a30  (92 bytes; match at +0x37 = 0x141899a67)
         Class lookup: TeamTransport.  Same interface-match-then-consume
         idiom -- the team transport pickup volume eats flares too.

  Both sites are patched together because the pattern is symmetric and the
  desired behavior (don't eat flares) is the same in both.

  =================== The match site ===================

  At each match address the bytes are (decoded with annotations):

     +00  3B 51 38              cmp  edx, [rcx+0x38]    ; idx vs interface count
     +03  7F 15                 jg   <end>              ; if greater, no match
     +05  48 8B 49 30           mov  rcx, [rcx+0x30]    ; interfaces array ptr
     +09  48 39 04 D1           cmp  [rcx+rdx*8], rax   ; interfaces[idx] vs RefinerySecondaryObjective
     +0D  75 0B                 jnz  <end>              ; <-- WE FLIP THIS to EB (jmp)
     +0F  48 8B D3              mov  rdx, rbx
     +12  48 8B CF              mov  rcx, rdi
     +15  E8 ?? ?? ?? ??        call <destroy-or-consume-flare>
     +1A  48 8B 5C 24 30        mov  rbx, [rsp+0x30]    ; epilogue
     +1F  48 83 C4 20           add  rsp, 0x20
     +23  5F                    pop  rdi
     +24  C3                    ret

  This is the standard UE4 "does this object implement interface I?" inline
  test: index into the class's interface table and compare slot pointers.
  If equal, the actor IS-A RefinerySecondaryObjective and we fall through
  into the call that destroys it (drop-pod site) or removes it from the
  transport queue (TeamTransport site).

  =================== The patch ===================

  Rewrite byte +0x0D from 0x75 (JNZ rel8) to 0xEB (JMP rel8).  The rel8
  displacement (0x0B) is unchanged, so the jump still lands at the same
  end-of-block label.  Net effect: the call to the destroy helper at +0x15
  becomes unreachable.  The CMP at +0x09 still runs but its result is
  ignored.

      JNZ +0x0B   ==>   JMP +0x0B

  No flags, registers, or downstream code paths are touched.  The function's
  early-return path is now unconditional whenever execution reaches +0x0D.

  =================== Verification ===================

  validate_flare.py against the target build (2026-05-11):
    - Hit count: 2 (one per call site listed above)
    - Byte at +0x0D at site 0x14182adde = 0x75  (PASS)
    - Byte at +0x0D at site 0x141899a67 = 0x75  (PASS)
    - Bytes 0..0x1F at both sites match the annotated layout above
      (rel8 displacement is 0x15 for the upper jg, 0x0B for the jnz at
      both sites in this build -- consistent shape).

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"
  Expected pattern matches: 2.

  =================== Provenance ===================

  Pattern lifted from trumank's original bitfix README (late 2024 / early
  2025).  Re-validated 2026-05-11 against current DRG build above.
]]

return {
    name = "Non-Flare-Devouring Drop Pod",
    description = "Stop the drop pod (and team transport) from consuming flares at pickup",
    category = "gameplay",
    role = "host",
    default = false,
    patches = {
        {
            -- Both call sites: the interface-match check that gates the
            -- destroy/consume helper for RefinerySecondaryObjective actors.
            --
            --   00..02  3B 51 ??           cmp  edx, [rcx+disp8]
            --   03..04  7F ??              jg   <end>
            --   05..08  48 8B 49 ??        mov  rcx, [rcx+disp8]
            --   09..0C  48 39 04 D1        cmp  [rcx+rdx*8], rax
            --   0D..0E  75 ??              jnz  <end>          <-- imm at +0x0D
            --   0F..11  48 8B D3           mov  rdx, rbx
            --   12..14  48 8B CF           mov  rcx, rdi
            --   15..19  E8 ?? ?? ?? ??     call <consume-flare>
            --   1A..1D  48 8B 5C 24 ..     mov  rbx, [rsp+...]  (epilogue anchor)
            pattern = '3B 51 ?? 7F ?? 48 8B 49 ?? 48 39 04 D1 75 ?? 48 8B D3 48 8B CF E8 ?? ?? ?? ?? 48 8B 5C 24',
            match = function(ctx)
                -- Flip JNZ rel8 (0x75) to JMP rel8 (0xEB) at +0x0D.
                -- The 1-byte displacement that follows is unchanged, so the
                -- branch still lands at the same end-of-block label -- it's
                -- just unconditional now, making the destroy call below
                -- unreachable.
                ctx[ctx:address() + 13] = 0xEB
            end
        },
    }
}
