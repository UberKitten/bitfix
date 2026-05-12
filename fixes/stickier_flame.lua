--[[ Let Driller's sticky flame (and related fire DoT) stick to ANY actor
     instead of only terrain.  In vanilla DRG, sticky flame patches only
     adhere to terrain (DeepCSGSection mesh chunks); they fall right off
     enemies, ridden hazards, structures, etc.  This patch removes the
     terrain-only gate so the flame sticks wherever it hits.

  =================== Gameplay effect ===================

  Affects: Driller's flamethrower secondary sticky-flame puddles, the
  Flame Reactive Armor mod's residual flames, the Sticky Flames overclock,
  and any other site that goes through UStickyFlameSpawner::TrySpawnStickyFlameHit.

  Vanilla: only terrain (UE class `DeepCSGSection`, /Script/FSDEngine) can
  carry a sticky-flame patch.  When the flame ray hits an enemy/structure
  it returns without spawning, so the puddle disappears instantly.

  Patched: the terrain-class IS-A check is bypassed.  Every hit gets a
  sticky flame, including direct hits on Glyphids, mactera, the rival
  bots, deposits, etc.  Net effect is significantly higher DoT uptime
  in close combat and on flying/floating targets.

  This is a player-skill-amplifying patch (you still have to aim), not
  a balance break.  Off by default; opt-in via `bitfix.cfg`.

  =================== The function ===================

  `UStickyFlameSpawner::TrySpawnStickyFlameHit(self, FHitResult* hit)`
  is the entry point that decides whether a given hit point should spawn
  a sticky-flame patch.  Decompiled vanilla logic:

      hit_actor = hit->Actor;                       // FHitResult.Actor
      if (hit_actor == nullptr) return false;
      DeepCSGSection_class = static_class<DeepCSGSection>();
      if (!hit_actor.IsA(DeepCSGSection_class))     // <-- the gate
          return false;
      SpawnInner(self, hit->Location, hit->Normal); // success
      return true;

  The IS-A check is implemented inline as a class-hierarchy walk:
      MOVSXD RCX, [actor_class + 0x38]              ; depth
      ADD    RBX, 0x30
      CMP    ECX, [DeepCSGSection_class + 0x38]     ; compare depths
      JG     <fail>                                 ; deeper than target -> not IS-A
      MOV    RAX, [class + 0x30]                    ; class.ParentChain
      CMP    [RAX + RCX*8], RBX                     ; class chain[depth] == target?
      JNZ    <fail>                                 ; not IS-A
      ; fall through to spawn

  We turn the whole sequence into a fall-through.

  =================== Why TWO patterns? ===================

  The vanilla bitfix README ships TWO patterns for this fix because the
  C++ inliner emitted (at least) two distinct compile shapes of the same
  source function.  The shapes differ in:
    1) which calling-convention registers get the inputs:
         pattern 1 uses RDI/RSI  (mov rdi,rcx / mov rsi,rdx)
         pattern 2 uses RBP/RDI  (mov rbp,rcx / mov rdi,rdx)
    2) the local-frame stack size (`sub rsp, ??`):
         pattern 1 reserves 0x70 bytes
         pattern 2 reserves 0x40 bytes
    3) consequently, the offset where the terrain-check skip lives is
       different in each shape, and the rel8 distance to jump past the
       check is different too -- hence two separate (offset, distance)
       tuples.

  In the **CL-141575 build** the compiler emitted only ONE matching shape
  (pattern 2).  Pattern 1's prologue (`48 8b f9 48 8b f2` with
  `sub rsp, 0x70`) is no longer present in the binary; presumably an
  inlining or codegen change collapsed it into pattern 2's shape.
  Pattern 1 is therefore kept here for documentation but commented out --
  if a future build resurrects the RDI/RSI variant we can re-enable it.

  Note: a third compile shape exists at VA 0x1418dafd0 (stack 0x20, same
  RBP/RDI registers).  It's a *different* function with INVERTED semantics
  (it sticks to anything EXCEPT FSDPawn / PlayerCharacter), reached from
  a different caller chain (FUN_141b5bf70).  Vanilla bitfix did not patch
  it and we don't either; its default behavior is already "stick to most
  things", so the user-visible effect from leaving it alone is minor.

  =================== Pattern 2 disassembly ===================

  Match site VA 0x1418b52e0 (CL-141575); 163-byte function.  Annotated:

    +0x00  48 89 5C 24 08          mov  [rsp+8], rbx
    +0x05  48 89 6C 24 10          mov  [rsp+0x10], rbp
    +0x0A  48 89 74 24 18          mov  [rsp+0x18], rsi
    +0x0F  57                      push rdi
    +0x10  48 83 EC 40             sub  rsp, 0x40              ; <-- shape marker
    +0x14  48 8B E9                mov  rbp, rcx               ; rbp = self
    +0x17  48 8B FA                mov  rdi, rdx               ; rdi = FHitResult*
    +0x1A  48 8D 4A 68             lea  rcx, [rdx + 0x68]      ; &hit->Actor
    +0x1E  E8 3D 6C 6F 00          call FResolveActor          ; -> RAX = actor*
    +0x23  48 85 C0                test rax, rax               ; null actor?
    +0x26  74 64                   jz   +0x64  -> +0x8C        ; -> "return false"
    +0x28  E8 13 93 79 02          call <get DeepCSGSection class>      ; <<< PATCH SITE
    +0x2D  48 8D 4F 68             lea  rcx, [rdi + 0x68]
    +0x31  48 8B D8                mov  rbx, rax               ; rbx = target class
    +0x34  E8 27 6C 6F 00          call FResolveActor          ; (re-fetch)
    +0x39  48 63 4B 38             movsxd rcx, [rbx + 0x38]    ; class depth
    +0x3D  48 83 C3 30             add  rbx, 0x30              ; -> ParentChain
    +0x41  48 8B 40 10             mov  rax, [rax + 0x10]      ; actor class ptr
    +0x45  3B 48 38                cmp  ecx, [rax + 0x38]
    +0x48  7F 42                   jg   +0x42  -> +0x8C        ; depth too low -> fail
    +0x4A  48 8B 40 30             mov  rax, [rax + 0x30]      ; ParentChain
    +0x4E  48 39 1C C8             cmp  [rax + rcx*8], rbx     ; chain[depth] == target?
    +0x52  75 38                   jnz  +0x38  -> +0x8C        ; not IS-A -> fail
    +0x54  F2 0F 10 47 30          movsd xmm0, [rdi + 0x30]    ; <<< SPAWN PATH starts here
    +0x59  4C 8D 44 24 20          lea  r8, [rsp+0x20]
    +0x5E  8B 47 38                mov  eax, [rdi + 0x38]
    +0x61  48 8D 54 24 30          lea  rdx, [rsp+0x30]
    +0x66  F2 0F 11 44 24 20       movsd [rsp+0x20], xmm0      ; build local hit-info struct
    +0x6C  48 8B CD                mov  rcx, rbp
    +0x6F  F2 0F 10 47 18          movsd xmm0, [rdi + 0x18]
    +0x74  89 44 24 28             mov  [rsp+0x28], eax
    +0x78  8B 47 20                mov  eax, [rdi + 0x20]
    +0x7B  F2 0F 11 44 24 30       movsd [rsp+0x30], xmm0
    +0x81  89 44 24 38             mov  [rsp+0x38], eax
    +0x85  E8 D6 FD FF FF          call SpawnInner             ; <<< SPAWN
    +0x8A  EB 02                   jmp  +0x02  -> +0x8E        ; skip the XOR
    +0x8C  32 C0                   xor  al, al                 ; return false
    +0x8E  ...                     epilogue + RET

  The trick: at +0x28 the original instruction is `CALL <get class>`
  (opcode 0xE8, 5 bytes).  The vanilla bitfix patch writes:

      [+0x28] = 0xEB    ; JMP rel8
      [+0x29] = 0x2A    ; displacement

  Which encodes `JMP +0x2A`.  After the 2-byte JMP, RIP = +0x2A, and
  +0x2A + 0x2A = +0x54 -- exactly the start of the spawn path.  The
  remaining 3 bytes of the original CALL (`93 79 02`) become unreachable
  dead bytes inside the JMP.  Net result: the terrain-class IS-A check
  and its CALL setup are skipped entirely; every hit reaches SpawnInner.

  Note that +0x28 in this build is a CALL opcode (0xE8) rather than a JCC
  (0x70..0x7F).  Earlier builds may have had a JCC here -- the README
  refers to this style of patch as "JCC -> JMP" -- but the patch is
  semantically just "write `EB rel8` to redirect control flow" and works
  identically over a CALL.  Don't be alarmed if `pre-patch byte != 7X`.

  Pattern-1 patch would have used (offset 0x2C, distance 0x32), targeting
  the same +0x60 region inside the spawn path, with the larger frame size
  shifting the offsets accordingly.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"
  Expected matches:
    pattern 1 (commented out): 0  -- shape not emitted by this build's compiler
    pattern 2 (active):        1  -- at VA 0x1418b52e0
]]

local patch = function(offset, distance)
    return function(ctx)
        ctx[ctx:address() + offset] = 0xEB
        ctx[ctx:address() + offset + 1] = distance
    end
end

return {
    name = "Stickier Flame",
    description = "Driller's sticky flames stick to enemies and any other actor, not just terrain",
    category = "gameplay",
    role = "host",
    default = false,
    patches = {
        -- UStickyFlameSpawner::TrySpawnStickyFlameHit, RBP/RDI variant.
        -- Sub rsp, 0x40; mov rbp,rcx; mov rdi,rdx; ...; CALL get_class.
        -- Match site in CL-141575: VA 0x1418b52e0.
        -- Patch writes JMP +0x2A at offset 0x28 to skip the terrain IS-A
        -- check and land at the spawn path.
        {
            pattern = '48 89 5c 24 08 48 89 6c 24 10 48 89 74 24 18 57 48 83 ec 40 48 8b e9 48 8b fa 48 8d 4a 68',
            match = patch(0x28, 0x2A)
        },

        -- UStickyFlameSpawner::TrySpawnStickyFlameHit, RDI/RSI variant
        -- (sub rsp, 0x70; mov rdi,rcx; mov rsi,rdx; ...).
        --
        -- DISABLED in CL-141575: this compile shape does NOT appear in
        -- this build.  Pattern 2 alone covers every UStickyFlameSpawner
        -- match site.  Kept commented out so a future re-emission of the
        -- RDI/RSI form can be re-enabled by uncommenting.
        --
        -- {
        --     pattern = '48 89 5c 24 08 48 89 6c 24 10 48 89 74 24 18 57 48 83 ec 70 48 8b f9 48 8b f2 48 8d 4a 68',
        --     match = patch(0x2C, 0x32)
        -- },
    }
}
