--[[ Hardens DRG's UE4 FastReferenceCollector against the observed classes of
     impossible UObject* values in token-stream reference slots.

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

  A 2026-08-05 recurrence then proved that alignment alone was also
  incomplete. The v2 patch matched and was enabled at all 24 sites, but the
  saved fault context and token-stream slot both contained:

      RAX = 0x0000000000010000
      MOV EAX,[RAX+0xC] -> AV reading 0x000000000001000C

  That value is positive and 16-byte aligned, so it passed both v2 checks.
  Read-only sampling of the unchanged relaunch found 489,268 non-null live
  GUObjectArray entries: all 489,268 were 16-byte aligned, none were at or
  below 0x10000, and the minimum was 0x0000019580053600.

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

  =================== Version 3 patch ===================

  The 23 bytes before the dereference are rewritten in place:

      EB 10                       JMP permanent_skip
      90 90                       NOP; NOP
      A8 07                       TEST AL,7
      75 0A                       JNZ invalid_skip
      48 3D 00 00 01 00          CMP RAX,0x10000
      7E 02                       JLE invalid_skip
      EB 05                       JMP dereference
  invalid_skip:
      E9 <existing rel32>         JMP continue
  dereference:
      8B 40 0C                    MOV EAX,[RAX+C]

  Resulting logic:

      if (is_permanent)                 goto continue;
      if ((RAX & 7) != 0)               goto continue;
      if ((int64_t)RAX <= 0x10000)      goto continue;
      index = RAX->InternalIndex;

  The permanent-object entry now jumps directly to the shared skip. Ordinary
  pointers must be 8-byte aligned and, by signed comparison, greater than
  0x10000. That one comparison rejects null, all sign-set values, and the new
  aligned near-null value. The invalid-path E9 reuses the original JNZ rel32
  bytes at offsets +19..+22: both old and new instructions end at +23, so its
  destination remains exactly the original token-loop continue label. No
  trampoline, code cave, allocation, new call, or branch relocation is used.

  =================== Safety evidence ===================

  - UObject/FUObjectItem object pointers are allocator-aligned. Sampling
    39,477 non-null GUObjectArray entries from the two full 2026-07-17 dumps
    found 39,477/39,477 aligned to 16 bytes; the patch requires only 8.
    The 2026-08-05 live sample added 489,268/489,268 aligned to 16 bytes.
  - The two crashing values have low bits 5 and 2 and are rejected.
  - The 0x10000 crashing value is rejected by the signed low-address compare.
  - Null and all sign-set values remain rejected by the same comparison.
  - A permanent object still jumps directly to the original continue label.
  - An ordinary aligned pointer above 0x10000 reaches the original MOV.
  - The rewrite is length-preserving. The reused rel32 target and every
    instruction address after the guard remain unchanged.
  - The extended signature below matches exactly 24 sites in build 141575.

  This remains a consumer-side safety net, not a general pointer validator.
  It rejects the poison shapes observed in this crash family before this GC
  dereference. An aligned positive garbage value above 0x10000 (including an
  LA48-noncanonical value) can still pass. The fix does not identify or repair
  the upstream overwrite, and it cannot protect unrelated consumers.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"
  Expected matches: 24.
]]

return {
    name = "DRG GC Invalid-Reference Skip",
    description = "GC skips permanent references and rejects observed null, low-address, sign-set, or misaligned poison before dereference",
    category = "crash",
    role = "client",
    default = true,
    patches = {
        {
            -- Extended signature includes the permanent-pool flag setup and
            -- both original branches to the token-loop continue label.
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

                -- Permanent entry -> shared invalid/continue jump at +18.
                ctx[address + 0] = 0xEB
                ctx[address + 1] = 0x10
                ctx[address + 2] = 0x90
                ctx[address + 3] = 0x90

                -- Ordinary entry: reject misalignment, then reject signed
                -- values <= 0x10000 (null, near-null, and sign-set).
                ctx[address + 4] = 0xA8
                ctx[address + 5] = 0x07
                ctx[address + 6] = 0x75
                ctx[address + 7] = 0x0A
                ctx[address + 8] = 0x48
                ctx[address + 9] = 0x3D
                ctx[address + 10] = 0x00
                ctx[address + 11] = 0x00
                ctx[address + 12] = 0x01
                ctx[address + 13] = 0x00
                ctx[address + 14] = 0x7E
                ctx[address + 15] = 0x02

                -- Valid pointers hop over the shared E9 to the dereference.
                -- Invalid pointers reuse the original JNZ rel32 bytes at
                -- +19..+22; E9 at +18 ends at the same +23 address.
                ctx[address + 16] = 0xEB
                ctx[address + 17] = 0x05
                ctx[address + 18] = 0xE9
            end
        }
    }
}
