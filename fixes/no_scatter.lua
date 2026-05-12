--[[ Prevent explosions from launching minerals (nitra/morkite/ore) outward
     by NOPing one MOVSS in FGrenadeExplodeOperation's constructor that
     writes the scatter-velocity scalar into the operation struct.

  =================== What this changes ===================

  Gameplay: when an explosion drops minerals (e.g. detonator, C4, bulk
  detonator, drilldozer / shredder swarm bombs, etc), the minerals would
  normally be flung outward with some initial velocity along the explosion
  vector.  With this patch, the scatter-velocity field on the explode
  operation is never written, so it stays at zero and the minerals drop
  in place where the chunk of terrain used to be.

  Practical effect: nitra piles, morkite veins, gold and other ore that's
  uncovered by carving stay neatly where the carve happened instead of
  scattering across the floor.  Easier to vacuum up with the scout/driller,
  easier to find in dark caves.

  =================== The function ===================

  Target: the FGrenadeExplodeOperation constructor.

  Ghidra address in this build: FUN_1415f9b20 (no symbol, no demangled name;
  identified by its constructor-shape and xref topology).  Signature:

    FGrenadeExplodeOperation*
    ctor(FGrenadeExplodeOperation* self,
         FVector*  origin,           // param_2 -- xyz of the explosion center
         float     scatter_strength, // param_3 -- magnitude of scatter velocity
         FVector*  direction,        // param_4
         float     radius_scale,     // param_5
         uint32    flags,            // param_6
         float     duration_a,       // param_7
         float     duration_b,       // param_8
         bool      flag_a,           // param_9
         bool      flag_b,           // param_10
         uint32    seed_or_index);   // param_11

  Identified as a ctor because:
    1. First instructions install two vtable pointers:
         *self          = &PTR_FUN_144e51340   ;  primary vtable
         self[0x18]     = &PTR_FUN_144e50f28   ;  secondary vtable (multi-inh)
       Setting a vtable in the prologue is the canonical C++ ctor signature.
    2. The function returns its `self` pointer (also canonical ctor return).
    3. Only two xrefs in the whole binary:
         - one DATA xref (a single vtable / RTTI entry at 0x1468c61d8)
         - one CALL xref from FUN_14160aad0 (the only constructor caller --
           presumably FGrenadeExplodeOperation::Create or a similar factory)
       Only-one-caller is consistent with a ctor invoked exclusively from
       a single factory function.

  The original trumank bitfix README comments this as
  `FGrenadeExplodeOperation::FGrenadeExplodeOperation`.  We can't verify
  the exact mangled name (no symbols in the shipping exe, and Ghidra hasn't
  recovered it from RTTI for this class), but everything observed --
  constructor shape, single ctor-caller xref, two-vtable layout, position/
  velocity floats, "ExplodeOperation"-flavoured class shape -- is consistent
  with that name.

  =================== Disassembly of the match site ===================

  In this build, the match site is at FSD+0x15f9b9f (VA 0x1415f9b9f), about
  0x7F bytes into the function.  Context around the patch:

    1415f9b8f  F3 0F 10 3D 51 6B 19 03    MOVSS  XMM7, [rip+0x144796278]
    1415f9b97  41 0F 28 C0                MOVAPS XMM0, XMM8
    1415f9b9b  F3 0F 59 C7                MULSS  XMM0, XMM7         ; XMM0 = scatter_strength * k
                                                                     ; k = *(float*)0x144796278
    1415f9b9f  F3 0F 11 43 60             MOVSS  [RBX+0x60], XMM0   ; <-- WE NOP THIS
                                                                     ;     5 bytes -> 90 90 90 90 90
    1415f9ba4  76 14                      JBE    +0x14              ; pattern's anchor byte 5..6
    1415f9ba6  F3 0F 10 3D ...            MOVSS  XMM7, [rip+...]    ; pattern's anchor byte 7

  Decompiled high-level (the line that becomes the MOVSS):

    *(float *)(param_1 + 0xc) = param_3 * DAT_144796278;
                ^^^^^^^^^^^^                ^^^^^^^^^^^
                 [RBX+0x60]             constant load (probably 1/duration
                                        or a unit-conversion scalar)

  The pattern (`f3 0f 11 43 ?? 76 14 f3`) anchors on:
    - MOVSS [RBX + disp8], XMM0  (the store we want to kill)
    - JBE   short rel8           (the followup conditional)
    - F3 ...                     (a subsequent MOVSS opcode prefix --
                                  used as a third anchor byte to keep
                                  the match unique)

  The `??` wildcard is on the disp8 of the MOVSS so the pattern survives
  small struct-layout changes between builds.  In this build the disp8 is
  0x60.

  =================== The patch ===================

  Five 0x90 bytes (NOPs) overwrite the entire 5-byte MOVSS instruction:

    F3 0F 11 43 60   ->   90 90 90 90 90

  Net effect: the constructor never writes to `self->[0x60]`.  That field
  remains whatever it was initialized to before the ctor body ran (in
  practice: zero, because operator new / placement-new zero-fills, and
  any preceding field initialization is unaffected).  Downstream code that
  reads `self->[0x60]` to compute mineral pickup velocity reads zero,
  applies a zero impulse, and the pickup stays put.

  No flow-control bytes are touched -- the JBE at +5 keeps its rel8 and
  the rest of the function executes normally.  All the other field writes
  in the ctor (position, radius, duration, flags, index, etc.) still happen.

  =================== Caveats ===================

  - **ANY operation that uses this constructor will skip the scatter
    setup**, not just mineral chunks.  If other code paths (gibbing,
    enemy-corpse impulse, debris bounce, etc.) share this struct's
    [+0x60] field for their own velocity, they'll all be flat.  In
    practice the field appears to be specifically the "outgoing pickup
    velocity scalar" for the operation -- the function's other outputs
    (position at +0xe8/+0xf0, direction at +0xf4/+0xf8/+0xfc, durations
    at +0x104/+0x108/+0x10c, etc.) are unaffected.
  - If a future DRG patch reorders the FGrenadeExplodeOperation fields
    or changes scatter to read from a different offset, this NOP will
    silently no-op (i.e. minerals will start scattering again with no
    crash).  The pattern would still match -- the only failure mode is
    "patch does nothing", which is benign.
  - Pattern is anchored on the JBE+MOVSS combo *and* a third F3 byte.
    If MSVC reorders this prologue across a recompile, the pattern would
    cease to match.  Expected behaviour in that case: bitfix logs 0
    matches in `bitfix.txt` and the fix simply doesn't take effect.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"
  Image base: 0x140000000

  Expected pattern matches: 1.
  Confirmed by Python AOB scan against the static image (sole hit at file
  offset 0x15f919f, VA 0x1415f9b9f, .text section).  Bytes at the match
  site read F3 0F 11 43 60 76 14 F3 ...  -- the 5-byte MOVSS we NOP plus
  the JBE+F3 trailing anchor.
  Confirmed by Ghidra headless that this VA falls inside the constructor
  FUN_1415f9b20, which exhibits all the structural markers of
  FGrenadeExplodeOperation::FGrenadeExplodeOperation.

  Pattern lineage: lifted from trumank's original bitfix README
  (https://github.com/trumank/bitfix) `no-scatter.lua` example, late
  2024 / early 2025.  Still matches cleanly on CL-141575 -- the layout
  is stable across recent DRG updates.
]]

return {
    name = "No Mineral Scatter",
    description = "Prevent explosions from scattering minerals (nitra/morkite/ore stay put when carved)",
    category = "gameplay",
    role = "host",
    default = false,
    patches = {
        {
            -- FGrenadeExplodeOperation::FGrenadeExplodeOperation, mid-ctor.
            -- The match site disassembles to:
            --   00..04  F3 0F 11 43 ??         movss [rbx+disp8], xmm0   ; <- we NOP this
            --   05..06  76 14                  jbe   short +0x14
            --   07      F3 ...                 (next movss opcode prefix; anchor only)
            -- The MOVSS stores scatter_strength * <constant> into
            -- self->[+0x60].  Killing it leaves that field at zero,
            -- so mineral pickups get no outgoing velocity from the
            -- explode operation.
            pattern = 'f3 0f 11 43 ?? 76 14 f3',
            match = function(ctx)
                -- 5 x 0x90 NOPs over the MOVSS instruction.
                -- The trailing JBE + downstream code are untouched.
                ctx[ctx:address() + 0x00] = 0x90
                ctx[ctx:address() + 0x01] = 0x90
                ctx[ctx:address() + 0x02] = 0x90
                ctx[ctx:address() + 0x03] = 0x90
                ctx[ctx:address() + 0x04] = 0x90
            end
        }
    }
}
