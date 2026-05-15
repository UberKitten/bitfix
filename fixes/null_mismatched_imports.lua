--[[ Speculative fix for class-mismatch GC crashes.

  =================== STATUS: speculative / DEV BRANCH ===================

  Default OFF. This patch is shipped for empirical testing only -- we
  have one observed crash that this would prevent, and at least one
  successful session with the same underlying corruption pattern that
  did NOT crash. The trade-off (see below) is real and we don't yet
  know whether shipping it default-on would do more harm than good.

  Enable in bitfix.cfg by flipping the line to `true` if you want to
  experiment, OR if you're hitting a reproducible class-mismatch GC
  crash on launch and want to trade some mod functionality for
  stability.

  =================== What the upstream bug is ===================

  When you join a host whose mod set replaces stock UE4 classes (e.g.
  a mod ships a `PlayerMovementComponent` derived from stock
  `CharacterMovementComponent` and references stock-class names), UE4
  resolves imports via `FAsyncPackage::FindExistingImport`. On a
  class-name mismatch between the declared import class and the actual
  resolved object's class, UE4 normally:

    1. Logs `"FAsyncPackage::FindExistingImport class mismatch %s != %s
       while reading package %s"` to LogStreaming
    2. *Still uses the mismatched Object* by storing it in the import
       slot anyway

  The caller then dereferences the Object's fields assuming the
  *declared* class's layout. If the declared class has BP-added or
  derived-class fields that the actual Object doesn't have, the reads
  go beyond the Object's allocation into adjacent heap. Those reads
  return whatever happens to be there: sometimes 0, sometimes a valid
  pointer, sometimes `0xFFFFFFFFFFFFFFFF` (poison-fill pattern from
  some allocators).

  If one of those fields is treated as `UObject*` and the garbage
  value is `0xFFFFFFFFFFFFFFFF`, the FastReferenceCollector GC worker
  thread will eventually walk it and AV-crash on dereferencing -1.

  The whole crash family is documented in
  `~/drg-bitfix/NOTES.md` -- search for "Family C: class-mismatch GC".

  UE4 already whitelists two known-safe pairs in this function:
    * BlueprintGeneratedClass <-> DynamicClass
    * Function <-> DelegateFunction
  This patch only fires on mismatches NOT in that whitelist.

  =================== What this patch does ===================

  Replaces the 5-byte CALL to UE4's `FOutputDevice::Logf` (the
  log-the-warning line) with `MOV qword ptr [RSI+0x20], RCX; NOP`
  -- which is also 5 bytes:

      original:  E8 ?? ?? ?? ??              CALL Logf
      patched:   48 89 4E 20 90              MOV [RSI+0x20], RCX ; NOP

  This works because at that exact instruction:
    * RCX = 0 (from the preceding `XOR ECX, ECX` setting up the
      first log arg)
    * RSI = puVar13 = the ImportEntry pointer (RSI is callee-saved
      in Windows x64 ABI and the function uses RSI as its import
      pointer throughout)
    * [RSI+0x20] is the XObject field of the ImportEntry struct

  Effect: ImportEntry->XObject gets nulled. The caller treats the
  import as "not found" and skips the asset via UE4's normal
  missing-import handling path. The log warning is lost.

  =================== Trade-offs ===================

  Pros:
    * Prevents the dormant corruption that leads to GC crashes
    * Surgical: 5-byte patch, no behavior change for matching imports
    * No-op for the two whitelisted mismatch pairs UE4 already exempts

  Cons:
    * Breaks legitimate mod patterns where mods ship subclasses under
      their parent's FName. Those mods would lose their replacement
      behavior because their objects no longer get loaded into the
      import slot.
    * Loses the diagnostic log message. Future debugging of mod
      compatibility issues becomes harder.
    * Overrides GSG's compiled "log + allow" policy decision. They
      explicitly whitelisted only 2 pairs and allowed everything else;
      we don't know which other pairs are safe-in-practice.
    * Single empirical data point. The observed crash hasn't been
      reproduced; might be rare enough that this patch breaks more
      than it fixes.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"

  Patch site: `FAsyncPackage::FindExistingImport` @ RVA 0x1df4890,
  +0x3e5 (the `CALL FOutputDevice::Logf`).

  Pattern is anchored on the unique log-call arg-setup sequence:
    LEA RAX, [<fmt_str>]    ; load format string
    CMOVNZ RDX, RDI         ; conditional move (declared class name)
    XOR ECX, ECX            ; first log arg = 0
    MOV [RSP+0x28], RDX     ; stack arg
    XOR EDX, EDX            ; second log arg = 0
    MOV [RSP+0x20], RAX     ; stack arg = format string
    CALL Logf               ; <-- THE CALL we replace

  The LEA's disp32 (4 wildcard bytes) varies with binary layout;
  the CALL's disp32 (4 wildcard bytes) also varies. The 22 fixed
  bytes between them are sufficient for unique identification.
]]

return {
    name = "Null Mismatched Imports",
    description = "Null the import slot on non-whitelisted class mismatches (prevents Family C GC crashes by trading mod-subclass replacement for stability). Speculative; default off.",
    category = "crash",
    role = "client",
    default = false,
    patches = {
        -- FAsyncPackage::FindExistingImport log-call site @ RVA 0x1df4890 +0x3e5
        --   00..06   48 8D 05 ?? ?? ?? ??        LEA RAX, [fmt_str]
        --   07..0A   48 0F 45 D7                 CMOVNZ RDX, RDI
        --   0B..0C   33 C9                       XOR ECX, ECX
        --   0D..11   48 89 54 24 28              MOV [RSP+0x28], RDX
        --   12..13   33 D2                       XOR EDX, EDX
        --   14..18   48 89 44 24 20              MOV [RSP+0x20], RAX
        --   19..1D   E8 ?? ?? ?? ??              CALL Logf      <-- patch site
        {
            pattern = '48 8D 05 ?? ?? ?? ?? 48 0F 45 D7 33 C9 48 89 54 24 28 33 D2 48 89 44 24 20 E8 ?? ?? ?? ??',
            match = function(ctx)
                local addr = ctx:address()
                -- Replace the 5-byte CALL at offset 0x19 with
                --     48 89 4E 20      MOV qword ptr [RSI+0x20], RCX
                --     90               NOP
                ctx[addr + 0x19] = 0x48
                ctx[addr + 0x1A] = 0x89
                ctx[addr + 0x1B] = 0x4E
                ctx[addr + 0x1C] = 0x20
                ctx[addr + 0x1D] = 0x90
            end
        }
    }
}
