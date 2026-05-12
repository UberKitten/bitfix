--[[ Show the normal terrain material on the Scout's terrain scanner
     instead of the special outlined "scanner material" overlay.

  =================== What this changes ===================

  The Scout class's terrain scanner highlights nearby terrain by replacing
  the rendered material on scannable mesh sections with a special "scanner
  material" -- a stylized outlined / x-ray-ish look that makes geology
  pop visually but obscures the real terrain texture.

  This patch inverts a single conditional branch in the rendering path
  that selects between two materials per mesh section.  After the patch,
  the path that *would* have selected the scanner material instead selects
  the regular terrain material, so scanned terrain renders identically to
  unscanned terrain.

  Default off -- it's a cosmetic preference, not a fix.

  =================== The function ===================

  Patch site lives in FUN_143ff4060 (image-base 0x140000000, target build
  CL-141575).  The function takes an "object" (param_1), a 2-slot array
  descriptor (param_2 -> mesh-section list + count), a bitmask, and an
  output list (param_5).  It walks an array of 32-byte entries describing
  scannable mesh sections; for each entry it:

    1. Reads a vtable-derived bool from the owning object
       (cmp byte ptr [rcx+0xd9e], 0).  This appears to be the
       "render with scanner highlight?" flag.
    2. Selects one of two material pointers stored in the entry:
         entry[0]  (offset +0x00 in the 32-byte slot)  = normal material
         entry[1]  (offset +0x08 in the 32-byte slot)  = scanner material
    3. Invokes a virtual function at vtable+0x298 on that material.
    4. Adds the result to the per-frame draw list under several other
       conditions (gated by the param_4 bitmask and other state).

  The vtable slot is referenced from 4 read-only DATA xrefs (likely
  several mesh-component vtables) -- consistent with the scanner being
  a shared method on a few related render component classes.

  =================== Disassembly of the match site ===================

  Pre-context (the flag load):
      143ff40f0  48 8b 03                   mov  rax, [rbx]         ; object
      143ff40f3  48 8b 08                   mov  rcx, [rax]         ; -> vtable / inner ptr
      143ff40f6  80 b9 9e 0d 00 00 00       cmp  byte [rcx+0xd9e], 0  ; scanner flag?

  The two-way material select (our patch target):
      143ff40fd  74 07                      jz   +7 -> 143ff4106    ; <-- PATCH (74 -> 75)
      143ff40ff  49 8b 4c 24 08             mov  rcx, [r12+8]       ; entry[1] = scanner mat
      143ff4104  eb 04                      jmp  +4 -> 143ff410a    ; skip the else
      143ff4106  49 8b 0c 24                mov  rcx, [r12+0]       ; entry[0] = normal mat
      143ff410a  48 8b 01                   mov  rax, [rcx]         ; mat vtable
      143ff410d  ff 90 98 02 00 00          call [rax+0x298]        ; ->GetRenderProxy()? etc

  Original semantics:
      flag == 0  ->  JZ taken     ->  use entry[0] (normal material)
      flag != 0  ->  fall through ->  use entry[1] (scanner material)

  After patching 0x74 -> 0x75 (JZ -> JNZ) the condition is inverted:
      flag == 0  ->  fall through ->  use entry[1] (scanner material)
      flag != 0  ->  JNZ taken    ->  use entry[0] (normal material)

  So when the scanner is active (flag set) we now pick the normal material.
  When the scanner is *inactive* we pick the scanner material -- which is
  fine because in the inactive path the calling code presumably never gets
  here (or doesn't render the result).  The observed in-field behavior of
  the original trumank pattern is that this cleanly removes the scanner
  overlay.

  =================== The patch ===================

  One byte at offset 0:  0x74 (JZ rel8)  ->  0x75 (JNZ rel8).  Same
  instruction length, same target, opposite polarity.  Inverts which
  material the mesh-section render path picks when the scanner flag is set.

  =================== Pattern uniqueness ===================

  Pattern: '74 ?? 49 8B 4C 24 ?? EB ?? 49 8B 0C 24'  (12 bytes, 3 wildcards)

  Despite being short, the pattern is very selective in practice -- it
  encodes a specific compiler idiom (two-way pointer select from a
  frame-relative struct, with a short forward jmp connecting the arms).
  Validated against this build with a Python AOB scan: exactly **1 match**,
  at VA 0x143ff40fd, inside FUN_143ff4060.

  Sanity-checked the surrounding bytes:
    pre  : ... 48 8b 03 48 8b 08 80 b9 9e 0d 00 00 00   ; the flag test
    body : 74 07 49 8b 4c 24 08 eb 04 49 8b 0c 24       ; the if/else
    post : 48 8b 01 ff 90 98 02 00 00 ...               ; the virtual call

  All three sides confirm this is a real "select material then virtcall"
  site, not a coincidental match inside data / padding / jump tables.

  If a future DRG patch causes this to start matching multiple times,
  widen the pattern by anchoring on the preceding flag-test
  (`80 b9 9e 0d 00 00 00 74 ?? 49 8B 4C 24 ?? EB ?? 49 8B 0C 24`) or the
  trailing `48 8b 01 ff 90 98 02 00 00` virtcall.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"
  Image base 0x140000000 (static); patch site VA 0x143ff40fd, RVA 0x3ff40fd
  Expected pattern matches: 1.
]]

return {
    name = "Normal Terrain Scanner Material",
    description = "Show normal terrain on the scanner instead of scanner material",
    category = "visual",
    default = false,
    patches = {
        {
            -- if/else material select inside FUN_143ff4060:
            --   00      74 ??           jz   short ...      ; <- PATCH (74 -> 75)
            --   02..06  49 8B 4C 24 ??  mov  rcx, [r12+disp8]  ; scanner mat
            --   07..08  EB ??           jmp  short ...
            --   09..0C  49 8B 0C 24     mov  rcx, [r12]        ; normal mat
            pattern = '74 ?? 49 8B 4C 24 ?? EB ?? 49 8B 0C 24',
            match = function(ctx)
                -- 0x74 (JZ rel8) -> 0x75 (JNZ rel8).  Same length, opposite polarity.
                -- Inverts which material the render path picks when the scanner is active,
                -- yielding the normal terrain material in place of the scanner overlay.
                ctx[ctx:address()] = 0x75
            end
        }
    }
}
