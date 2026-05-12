--[[ Raise the simultaneous-attacker cap in DRG's AttackerPositioningComponent
     from the stock value (currently 32 in this build, was 4 in older builds)
     up to 200.

  =================== What this changes ===================

  Deep Rock Galactic limits how many enemies can be actively attacking the
  player squad at one time.  Past that cap, additional enemies stand off
  ("queued") and wait for an active attacker to die / disengage before
  rotating in.  The cap is enforced by `UAttackerPositioningComponent`,
  which scores candidate enemies via `UPlayerAttackPositionComponent::GetScore`
  and admits only the top-N into the "actively attacking" set.

  Bumping the cap to 200 effectively removes the queue: nearly every enemy
  inside the perception/positioning radius can attack simultaneously.  This
  is the patch behind the well-known "200 attackers" community mod.  Pure
  gameplay-flavor change -- not a crash fix.

  Category: gameplay.  Default off; toggle via `bitfix.cfg`.

  =================== Target functions ===================

  Two functions are patched.  Both names come from trumank's original
  bitfix README (late 2024 era), where they were given as decompiled-symbol
  hints rather than DRG-exported symbols (FSD-Win64-Shipping.exe is stripped).

  -- Pattern 1: `UPlayerAttackPositionComponent::GetScore` --

  The per-candidate scoring routine.  Called for each candidate enemy when
  the positioning component is deciding which N to admit.  Internally it
  contains two parallel branches that both load `0x20` into EDI (the cap)
  before calling a virtual at `[rax+0x428]`.  These are the per-branch
  "max attacker count" arguments passed into the scoring math.

  Match site in this build: 0x14155f150 (RVA 0x155f150, .text).

  Prologue:

     14155f150  48 89 5C 24 08              mov  [rsp+8], rbx
     14155f155  48 89 6C 24 10              mov  [rsp+0x10], rbp
     14155f15a  48 89 74 24 18              mov  [rsp+0x18], rsi
     14155f15f  57                          push rdi
     14155f160  48 83 EC 30                 sub  rsp, 0x30
     14155f164  48 8B 01                    mov  rax, [rcx]            ; vtable
     14155f167  41 0F B6 F0                 movzx esi, r8b             ; bool arg
     ...

  The two patch sites inside this function:

     +89  (14155f1a9):  bf 20 00 00 00       mov edi, 0x20           ; <-- WE CHANGE THIS
     +187 (14155f20b):  bf 20 00 00 00       mov edi, 0x20           ; <-- AND THIS

  bitfix writes 200 (0xC8) at +89 and +187, overwriting the low byte of each
  `mov edi, imm32`.  The upper three bytes of each imm32 are already 0x00, so
  the result is a clean `mov edi, 200` -- same instruction, same encoding
  length, just a different constant.

  -- Pattern 2: `UAttackerPositioningComponent::UAttackerPositioningComponent` --

  The component's constructor.  Initializes default field values on a
  newly-allocated component, including the MaxAttackers cap at struct
  offset 0xB4.

  Match site in this build: 0x141545350 (RVA 0x1545350, .text).

  Prologue:

     141545350  48 89 5C 24 08              mov  [rsp+8], rbx
     141545355  48 89 6C 24 10              mov  [rsp+0x10], rbp
     14154535a  48 89 74 24 18              mov  [rsp+0x18], rsi
     14154535f  48 89 7C 24 20              mov  [rsp+0x20], rdi
     141545364  41 56                       push r14
     141545366  48 81 EC D0 00 00 00        sub  rsp, 0xD0
     14154536d  48 8B F9                    mov  rdi, rcx              ; rdi = this
     141545370  E8 ?? ?? ?? ??              call <base-ctor>
     141545375  48 8B D0                    mov  rdx, rax
     141545378  48 8B CF                    mov  rcx, rdi
     14154537b  E8 ?? ?? ?? ??              call <base-init>
     141545380  33 DB                       xor  ebx, ebx
     141545382  c7 87 B4 00 00 00 20 00 00 00
                                            mov  dword [rdi+0xB4], 0x20   ; <-- WE CHANGE THIS

  bitfix writes 200 (0xC8) at +56, which is the low byte of the `imm32`
  in that store instruction.  After the patch: `mov dword [rdi+0xB4], 200`.

  =================== Verification of patched-byte values ===================

  Validated against the target build on 2026-05-11 with
  `C:\Users\m\ghidra-projects\scripts\validate_max_attackers.py`:

  Pattern 1 -- 1 match @ 0x14155f150
    +89  = 0x20  (= 32)   patch overwrites to 0xC8 (= 200) ✓
    +187 = 0x20  (= 32)   patch overwrites to 0xC8 (= 200) ✓

  Pattern 2 -- 1 match @ 0x141545350
    +56  = 0x20  (= 32)   patch overwrites to 0xC8 (= 200) ✓

  NOTE: The patched bytes are 0x20 (= 32), NOT 0x04 (= 4) as one might expect
  from reading older docs of this patch.  The README this patch was lifted
  from (late 2024 / early 2025) talks about bumping the cap "from 4 to 200",
  which was accurate for that build.  The stock cap in the CL-141575 build
  appears to have been raised from 4 to 32 by GSG at some point between then
  and now.

  This does NOT break the patch.  The pattern still matches because none of
  the pattern bytes overlap the immediate.  The byte-write of 200 still lands
  on the low byte of the imm32, and the upper three bytes are still 0x00 --
  so the post-patch instruction is `mov ..., 0x000000C8`, exactly the
  intended "200 attackers" effect.  All three patched offsets land on the
  intended imm32 low byte; the surrounding instructions are unchanged.

  If a future GSG patch raises the stock cap above 0xFF, the upper bytes of
  the imm32 would no longer be zero and a single-byte write would silently
  produce a much larger number than 200 (e.g. stock = 0x100 -> patched =
  0x1C8 = 456).  At that point this patch should be rewritten to either
  zero out the upper bytes explicitly or to use a different patch strategy.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"
  Expected pattern matches: 1 + 1 = 2 (one per pattern, single match each).

  =================== Provenance ===================

  Original patch is from trumank's bitfix README (the "DRG max attackers"
  example).  Re-validated and documented on 2026-05-11 against the
  CL-141575 build with `validate_max_attackers.py`.  Both patterns still
  uniquely match; the constants being overwritten have shifted from 4 to
  32 in stock but the patch effect (set them to 200) is unchanged.
]]

return {
    name = "Max Attackers 200",
    description = "Raise simultaneous-attacker cap from stock to 200 (UAttackerPositioningComponent)",
    category = "gameplay",
    role = "host",
    default = false,
    patches = {
        {
            -- UPlayerAttackPositionComponent::GetScore
            -- Two `mov edi, imm32` instructions inside the function carry the
            -- attacker-count argument used by two parallel score branches.
            -- Overwriting the low byte of each imm32 with 200 changes both
            -- to `mov edi, 200`.
            pattern = '48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 48 83 EC 30 48 8B 01 41 0F',
            match = function(ctx)
                ctx[ctx:address() + 89] = 200   -- low byte of first  `mov edi, 0x20`
                ctx[ctx:address() + 187] = 200  -- low byte of second `mov edi, 0x20`
            end
        },
        {
            -- UAttackerPositioningComponent::UAttackerPositioningComponent
            -- Constructor stores the default MaxAttackers cap at [this+0xB4]
            -- via `mov dword [rdi+0xB4], imm32`.  Overwriting the low byte
            -- of that imm32 with 200 changes the initial cap to 200.
            pattern = '48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 48 89 7C 24 20 41 56 48 81 EC D0 00 00 00 48 8B F9 E8 ?? ?? ?? ?? 48 8B D0 48 8B CF E8 ?? ?? ?? ?? 33 DB',
            match = function(ctx)
                ctx[ctx:address() + 56] = 200   -- low byte of imm32 in `mov [rdi+0xB4], 0x20`
            end
        }
    }
}
