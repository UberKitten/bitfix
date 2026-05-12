--[[ Adds +2 GiB of reserved virtual address space to every FSDVirtualMem arena
     by patching the single function FSDVirtualMem::Reserve at its entry.

  =================== Crash this targets ===================

    Fatal error: [File:Unknown] [Line: 115]
    FSDVirtualMem::Commit failed with error: 487.

  Error 487 = ERROR_INVALID_ADDRESS, returned by VirtualAlloc(addr, sz,
  MEM_COMMIT, ...) when `addr` does not fall inside an already-MEM_RESERVE'd
  region.

  Observed example crash dump (2026-05-10 8:34 PM PDT):
      MemoryStats.AvailableVirtual : 47.9 GB    <- plenty free, NOT real OOM
      MemoryStats.UsedVirtual      :  9.4 GB
      MemoryStats.bIsOOM           :  0
      CrashedThread.Name           : "CSGOpProcessor 2"
      Top frame                    : FSD+0x3fc0f71 (inside FSDVirtualMem::Commit)
      PCallStackHash               : 885EE378D8DF899C5FA64DFF4CF0C7EDD07B197D

  =================== Root cause ===================

  DRG uses a custom allocator (FSDVirtualMem) for CSG mesh / terrain
  destruction data.  Each named arena ("pool-VertexPositions", "pool-Faces",
  "pool-Debris", etc.) reserves a fixed-size virtual-address region at
  startup via MEM_RESERVE; then ::Commit walks pages from low to high
  within that region.  When too many CSG ops are queued (modded heavy
  carve loads -- bulk detonator chains, mass terrain destruction), the
  next page index runs past the reservation's end.  VirtualAlloc returns
  NULL with GetLastError == 487, and ::Commit asserts fatal.

  Observed arena sizes in this build range from ~1.5 MB to ~2.5 GB; the
  ~43 named arenas include pool-Planes, pool-Cells*, pool-SubMeshes,
  pool-VertexPositions, pool-Faces, pool-PhysTriangles, pool-Debris,
  pool-VolumeBuffers1/2/3, pool-BitVolumeBuffers1/2/3, and ~25 others.
  Any of these can be the offender depending on which arena the
  particular workload presses on.

  =================== The patch ===================

  FSDVirtualMem::Reserve(arena*, size) starts with:

     143fc... 48 89 5C 24 08         mov  [rsp+8], rbx       ; save rbx
              57                     push rdi
              48 83 EC 50            sub  rsp, 0x50          ; locals
              48 81 C2 FF FF 00 00   add  rdx, 0xFFFF        ; <-- WE CHANGE THIS
              48 8D 79 10            lea  rdi, [rcx+0x10]    ; arena's inner ptr
              48 C1 EA 10            shr  rdx, 0x10          ; convert to page count
              48 8B D9               mov  rbx, rcx
              48 8B C2               mov  rax, rdx
              48 C1 E0 10            shl  rax, 0x10          ; back to byte size, 64K-aligned
              48 89 41 30            mov  [rcx+0x30], rax    ; arena.reserved_size = aligned

  The `add rdx, 0xFFFF` round-up-to-64K trick combined with `shr/shl 0x10`
  is the standard alignment idiom.  By rewriting the high byte of the imm32
  from 0x00 to 0x7F, the instruction becomes `add rdx, 0x7FFFFFFF` -- which
  adds ~2 GiB to every arena's reservation.  The subsequent SHR/SHL chain
  still rounds to 64 KiB correctly because 0x7FFFFFFF has the low 16 bits set.

  We can't go higher than 0x7F via single-byte patch: `ADD r/m64, imm32`
  sign-extends the immediate, so any high byte >= 0x80 turns the ADD into
  a SUBTRACT of a huge value.  0x7F is the max safe.

  =================== Verification ===================

  From the 2026-05-11 21:28 PDT crash dump (after this patch's v1 +1 GiB
  variant was already deployed), captured the ExpandingArray struct of the
  array that overflowed:

      data_base     = 0x284EE840000   (data inside the arena)
      reserved_size = 0xBF000000      = 3.05 GiB

  Without the patch the arena would have reserved (0xBF000000 - 0x7FFFFFFF)
  ~= 1.06 GiB; v1 was confirmed working in the field.  v2 brings the bump
  to +2 GiB so heavier carves don't bottleneck on the allocator now that
  the ExpandingArray<T> MAXSIZE caps are also unlocked (see
  drg_expanding_array_uncap.lua).

  =================== Cost ===================

  - Address space: ~+2 GiB per arena * ~43 arenas = ~86 GiB extra reserved.
    Process limit on x64 Windows is 128 TiB; we're using ~0.07% of it.
  - Physical RAM: zero impact at startup.  MEM_RESERVE doesn't commit any
    pages; commit only happens when the game actually needs more space.
  - Page-state bitmap: ~+2 KiB per arena.  Trivial.
  - System commit charge: bitmap allocations are committed; ~86 KiB total.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"
  Expected pattern matches: 1.  Confirmed in bitfix.txt on 2026-05-10 and
  2026-05-11 game launches.
]]

return {
    name = "DRG CSG Arena Bump",
    description = "Add +2 GiB of reserved VA to every FSDVirtualMem arena (fixes Commit error 487 from heavy carving)",
    category = "crash",
    default = true,
    patches = {
        {
            -- FSDVirtualMem::Reserve prologue + the round-up-to-64KB math:
            --   00..04  48 89 5C 24 08          mov  [rsp+8], rbx
            --   05..09  48 89 74 24 10          mov  [rsp+0x10], rsi
            --   10      57                      push rdi
            --   11..14  48 83 EC 50             sub  rsp, 0x50
            --   15..21  48 81 C2 FF FF 00 00    add  rdx, 0xFFFF       ; <- imm high byte at +21
            --   22..25  48 8D 79 10             lea  rdi, [rcx+0x10]
            pattern = '48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 50 48 81 C2 FF FF 00 00 48 8D 79 10',
            match = function(ctx)
                -- Rewrite imm32 from 0x0000FFFF to 0x7FFFFFFF.
                -- ADD RDX, 0x0000FFFF  ==>  ADD RDX, 0x7FFFFFFF
                -- Net effect: every arena's reserved VA grows by ~2 GiB.
                ctx[ctx:address() + 21] = 0x7F
            end
        }
    }
}
