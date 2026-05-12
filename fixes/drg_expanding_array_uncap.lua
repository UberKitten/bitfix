--[[ Dead-codes the hardcoded MAXSIZE bound check in every templated
     ExpandingArray<T>::Resize function in DRG (54 sites in this build).

  =================== Crash this targets ===================

    Fatal error: [File:Unknown] [Line: 132]
    ExpandingArray out of range (MAXSIZE <varies>).

  Observed example crash dump (2026-05-11 21:28 PDT, the third crash in
  the sequence -- after the FSDVirtualMem +1 GiB patch had successfully
  unlocked the underlying allocator):

      ErrorMessage   : "ExpandingArray out of range (MAXSIZE 67108864)."
      MAXSIZE        : 67108864 = 0x04000000 = 64 MiB elements
      Crashed thread : CSGOpProcessor 2
      Top frame      : FSD+0x160c8ae (inside Resize<T> at FUN_14160c860, +0x4e)
      PCallStackHash : D0BDC7AFD58D915952C6A4E81056F08C00BD5056

  =================== Root cause ===================

  ExpandingArray<T> is DRG's templated growable container.  Each
  instantiation (one per element-type T) has its own compiler-generated
  Resize<T> function with a hardcoded MAXSIZE cap.  In this build,
  enumeration via Ghidra found 54 such functions; observed caps range
  from 0x10000 (64 KB) to 0xA000000 (160 MB).  Element-count caps; the
  storage budget per array is `MAXSIZE * sizeof(T)`.

  When modded heavy-carve workloads push one of these arrays past its
  cap, the check fires and the game asserts fatal.

  These caps look like defensive checks set conservatively rather than
  load-bearing safety invariants -- the same function's resize math is
  fine up to ~0x2AAAAAAA elements (~715M) before any int32 arithmetic
  would actually wrap.  Each MAXSIZE was sized for the *vanilla* expected
  workload, not for what mods produce.

  =================== The patch ===================

  All 54 Resize<T> functions share a byte-identical 15-byte prologue:

      48 89 5C 24 08         mov  [rsp+8], rbx
      57                     push rdi
      48 83 EC 30            sub  rsp, 0x30
      8B DA                  mov  ebx, edx          ; ebx = requested_size
      48 8B F9               mov  rdi, rcx          ; rdi = self

  Followed immediately by:

      81 FA <imm32>          cmp  edx, MAXSIZE      ; <imm32> varies per T
      7C 37                  jl   short OK          ; <-- byte we patch
      ... ~0x37 bytes of fatal-call setup (LEA fmt-string, MOV maxsize, CALL fatal_log) ...
  OK:
      ... rounded-up resize math; calls FSDVirtualMem::Commit to grow ...

  We change the `JL +0x37` (`0x7C 0x37`) to `JMP +0x37` (`0xEB 0x37`).
  One byte per site: `0x7C -> 0xEB` at offset +21 from the function entry.
  The fatal-call block becomes dead code in every Resize<T>; resize is
  unconditional.

  =================== Why disable, not bump ===================

  We considered patching each per-T MAXSIZE immediate to a bigger value
  instead.  Reasons we chose to disable the check entirely:

  1. The check is a defensive guard, not a hard invariant.  The Resize
     code itself is correct up to ~715M elements (the natural int32 limit
     for `(uVar1 - prev) * 6` and similar arithmetic).
  2. Picking the right new cap per T requires per-arena telemetry we
     don't have.  "Disable" is more honest than "guess".
  3. If we hit an int-overflow regime later, that'll be a *different*
     crash signature with its own diagnosis -- we'd rather catch it
     specifically than have it mask as "MAXSIZE was wrong".

  =================== Verification ===================

  Captured ExpandingArray struct (from the 2026-05-11 21:28 crash dump):

      data_base    = 0x284EE840000
      live_count   = 0x03FFFDDE  (67,108,318)     <- 546 elements short of full
      capacity     = 0x04000000  (67,108,864)     <- MAXSIZE; THIS is what asserted
      reserved_size= 0xBF000000  (~3.05 GiB)      <- arena has plenty of room left

  The arena had ~3 GiB of reserved VA (thanks to drg_csg_arena_bump.lua's
  v1 +1 GiB at the time); only ~1 GiB was actually backing the array's data.
  The FAILURE was entirely the artificial MAXSIZE cap -- the underlying
  allocator was nowhere near exhausted.  Removing the cap lets the array
  grow into the arena's available space.

  =================== Cost ===================

  - 54 single-byte writes at process startup; ~microseconds total via bitfix.
  - No runtime overhead -- the dead-coded fatal block is just unreachable
    instructions.
  - No memory cost -- the arrays grow on demand as before; the cap was
    just an upper bound, not a pre-allocation.

  =================== Caveats ===================

  - ~36 OTHER functions in the binary reference the same fatal format
    string but have different prologues (likely larger composite Resize
    variants -- bigger frames, more saved registers, or have been inlined).
    This pattern does NOT match them.  If a future crash mentions an
    ExpandingArray MAXSIZE in code with a different prologue, those are
    the next investigative targets.
  - We're trusting the int-overflow-safe math in the Resize body.  If a
    workload genuinely exceeds ~715M elements, expect a DIFFERENT crash
    (probably inside FSDVirtualMem::Commit again, or an integer overflow
    producing a bogus VirtualAlloc).  Not seen in practice.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"
  Expected matches: 54.  Confirm via bitfix.txt -- one "writing EB" line per
  match.  If count is far below 54, the build has shifted; widen the pattern
  (e.g. wildcard the trailing `7C 37` to `7C ??` in case some Resize<T>'s
  have a different fatal-block size).
]]

return {
    name = "DRG ExpandingArray Uncap",
    description = "Dead-code the hardcoded MAXSIZE check in every Resize<T> (fixes 'ExpandingArray out of range' from heavy carving)",
    category = "crash",
    default = true,
    patches = {
        {
            -- Common 15-byte prologue (identical across all 54 templated
            -- Resize<T> instantiations) + the CMP/JL bound check.
            --
            --   00..04  48 89 5C 24 08          mov  [rsp+8], rbx
            --   05      57                      push rdi
            --   06..09  48 83 EC 30             sub  rsp, 0x30
            --   10..11  8B DA                   mov  ebx, edx          ; save requested size
            --   12..14  48 8B F9                mov  rdi, rcx          ; save self
            --   15..20  81 FA ?? ?? ?? ??       cmp  edx, MAXSIZE      ; per-T immediate
            --   21..22  7C 37                   jl   +0x37             ; <- patch byte +21
            pattern = '48 89 5C 24 08 57 48 83 EC 30 8B DA 48 8B F9 81 FA ?? ?? ?? ?? 7C 37',
            match = function(ctx)
                -- 0x7C (JL rel8) -> 0xEB (JMP rel8) makes the jump unconditional.
                -- The fatal-call block at the fall-through path becomes dead code.
                ctx[ctx:address() + 21] = 0xEB
            end
        }
    }
}
