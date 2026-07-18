--[[ Hardens DRG's UE4 FastReferenceCollector against impossible UObject*
     values in token-stream reference slots.

  =================== Crash family ===================

  Confirmed fault site (all recurrences):

      FSD+0x1e49b80  MOV EAX,[RAX+0xC]
      PCallStackHash  36E75CD1571B9A5581294C6CAFCA237753463C50
      UE4             FastReferenceCollector token-stream walker

  The original recurrences were reported as reads from
  0xFFFFFFFFFFFFFFFF. Version 1 of this fix changed the existing null guard
  from JZ to JLE, which also rejects sign-set values such as -1.

  Two 2026-07-17 recurrences proved that was incomplete. The exception
  stream still reported -1, but the saved CPU contexts and slot memory show
  the actual RAX values at the faulting MOV were:

      0x0065006500530065    UTF-16 bytes "eSee", low bits 5
      0x0043005F00500042    UTF-16 bytes "BP_C", low bits 2

  Both are positive, non-canonical, and misaligned. They therefore pass the
  old JLE guard. An unchanged third launch completed the same live mission;
  all 200 modules and all 24 old patches matched the crashing launches. The
  direct failure is heap/timing dependent, not evidence that a mod pack or
  the patch failed to load.

  The upstream writer of the bad slot is not yet proven. Class-mismatch and
  unresolved-archetype warnings occur in both crashing and successful runs,
  so they are correlation/background conditions rather than a sufficient
  root cause.

  =================== Original collector sequence ===================

  Each of the 24 reference-token cases has this layout (rel32 differs):

      B1 01                       MOV  CL,1       ; pointer is permanent
      EB 02                       JMP  guard
      32 C9                       XOR  CL,CL      ; ordinary pointer
  guard:
      48 85 C0                    TEST RAX,RAX
      0F 84 ?? ?? ?? ??           JZ   continue   ; null -> skip
      84 C9                       TEST CL,CL
      0F 85 ?? ?? ?? ??           JNZ  continue   ; permanent -> skip
      8B 40 0C                    MOV  EAX,[RAX+C] ; faulting dereference

  RAX is the reference-slot value. The permanent-object range check that
  precedes this sequence selects MOV CL,1 or XOR CL,CL. Both conditional
  branches target the same token-loop continue label.

  =================== Version 2 patch ===================

  Three in-place substitutions preserve instruction lengths and branch
  destinations:

      B1 01       MOV CL,1       ->  0C 01       OR AL,1
      0F 84       JZ continue    ->  0F 8E       JLE continue
      84 C9       TEST CL,CL     ->  A8 07       TEST AL,7

  Resulting logic:

      if (RAX == 0 || bit63(RAX))       goto continue;
      if (is_permanent) RAX.low_bit = 1;
      if ((RAX & 7) != 0)               goto continue;
      index = RAX->InternalIndex;

  The OR executes only on the path already classified as permanent and
  already destined to skip. It deliberately tags that otherwise-valid RAX
  value so the reused TEST AL,7 keeps the original permanent-object behavior.
  On the ordinary-object path, XOR CL,CL remains but RAX is untouched.

  The JLE retains version 1's null/sign-set protection. TEST AL,7 adds an
  eight-byte-alignment requirement and catches both positive text-shaped
  values observed on 2026-07-17. No trampoline, code cave, allocation, new
  call, or branch relocation is required.

  =================== Safety evidence ===================

  - UObject/FUObjectItem object pointers are allocator-aligned. Sampling
    39,477 non-null GUObjectArray entries from the two full 2026-07-17 dumps
    found 39,477/39,477 aligned to 16 bytes; the patch requires only 8.
  - The two crashing values have low bits 5 and 2 and are rejected.
  - Null and all sign-set values remain rejected by JLE.
  - A permanent object is still skipped: OR AL,1 sets the exact bit tested
    by TEST AL,7, and that path never dereferences the tagged value.
  - An ordinary aligned pointer is unchanged and reaches the original MOV.
  - All substitutions are length-preserving. The existing rel32 targets and
    every instruction address after the guard remain unchanged.
  - The extended signature below matches exactly 24 sites in build 141575.

  This remains a consumer-side safety net. It prevents this GC dereference
  from consuming an impossible slot value; it does not identify or repair
  the upstream overwrite, and it cannot protect unrelated consumers.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"
  Expected matches: 24.
]]

return {
    name = "DRG GC Invalid-Reference Skip",
    description = "GC skips null, sign-set, permanent, or misaligned reference slots instead of dereferencing impossible UObject pointers",
    category = "crash",
    role = "client",
    default = true,
    patches = {
        {
            -- Extended signature includes the permanent-pool flag setup so
            -- it can be converted into an RAX low-bit marker. Both rel32s
            -- still point to the same token-loop continue label.
            --
            --   +00  B1 01                    MOV CL,1
            --   +02  EB 02                    JMP +2
            --   +04  32 C9                    XOR CL,CL
            --   +06  48 85 C0                 TEST RAX,RAX
            --   +09  0F 84 ?? ?? ?? ??        JZ continue
            --   +15  84 C9                    TEST CL,CL
            --   +17  0F 85 ?? ?? ?? ??        JNZ continue
            --   +23  8B 40 0C                 MOV EAX,[RAX+0xC]
            pattern = 'B1 01 EB 02 32 C9 48 85 C0 0F 84 ?? ?? ?? ?? 84 C9 0F 85 ?? ?? ?? ?? 8B 40 0C',
            match = function(ctx)
                local address = ctx:address()

                -- Permanent path: MOV CL,1 -> OR AL,1. That path already
                -- skips; tagging RAX lets the shared alignment test retain
                -- the original behavior without adding instructions.
                ctx[address + 0] = 0x0C

                -- Null/sign guard: JZ -> JLE (same rel32 destination).
                ctx[address + 10] = 0x8E

                -- Permanent marker OR natural misalignment -> skip.
                -- TEST CL,CL -> TEST AL,7 (same two-byte length).
                ctx[address + 15] = 0xA8
                ctx[address + 16] = 0x07
            end
        }
    }
}
