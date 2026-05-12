--[[ Neutralises the per-mission "mission_start" telemetry event builder by
     overwriting its function entry with a single-byte `ret`.

  Originally lifted from trumank's upstream `bitfix` example.  Re-validated
  against DRG build CL-141575 on 2026-05-11 -- the pattern still matches a
  single site, the function is byte-identical to what the old comment
  implied, and the patch still neutralises it cleanly.

  =================== Crash this targets ===================

  Per trumank's original note: "Fix game crashing if more than 8 players
  are in the lobby during mission load."

  Symptom (from public mint/bitfix reports, not directly observed in our
  own dumps -- we run with this patch enabled, so we don't crash here):
  starting a mission with >8 players present in the lobby causes a fatal
  during the mission_start handshake on the host.  The crash is not a
  FSDVirtualMem assert (that family is covered by drg_csg_arena_bump.lua);
  it manifests inside the analytics / loadout-gathering code path that
  runs immediately after the lobby-to-mission transition.

  =================== Root cause ===================

  The patched function (FSD+0x1922310, internally unnamed -- Ghidra calls
  it FUN_141922310) is a *telemetry event builder*.  Decompilation shows
  it constructing a "mission_start" event with the following keys and
  dispatching it through the analytics service stored at `param_1 + 0x30`:

    is_host, players_in_group, biome_name, mission_name, mission_seed,
    total_time, complexity, duration, difficulty, mission_campaign,
    campaign_name, campaign_progress, campaign, weapon,
    weapon_category, weapon_upgrades, weapon_overclock, weapon_framework,
    weapon_paintjob, player_loadout, grenade, perk_slot, perk_loadout,
    owned_schematics, crafted_schematics, ...

  Verbose log strings inside the function confirm the identity:

      L"mission_start_data: %s"
      L"mission_start_data part4: %s"

  The function also pre-allocates a per-player iteration:

      FUN_14190cd50(param_1, &local_108);    // gathers loadout per player
      lVar15 = (longlong)(int)local_100 * 0x60 + local_108;
      do { ... } while (lVar1 != lVar15);     // per-player serialise loop

  And earlier:

      FUN_14190dea0(param_1, local_d8);       // gathers mission-wide data
                                              // into a fixed-size struct
                                              // (~0x90 bytes on the caller's
                                              //  stack: local_d0..local_50)

  Trumank's note about ">8 players" almost certainly refers to a fixed-
  size buffer inside one of the gathering helpers (`FUN_14190dea0` /
  `FUN_14190cd50` / `FUN_14190f540`) that was sized for the stock 4-player
  game and overruns when a modded lobby has more bodies than the helper
  expected.  We did NOT pin down the exact overflow site (Ghidra has the
  helpers as anonymous FUN_*), but the pattern is consistent with the
  symptom and matches the trumank upstream rationale.

  The single caller is FSD+0x158c0bc (inside FUN_14158b270), reached via
  the mission-start chain after the lobby's player roster is finalised.
  Skipping this function therefore skips ALL of the data-gathering helpers
  it calls, which is what makes the byte-flip safe: the buffer that would
  overflow is never filled.

  =================== The patch ===================

  Function prologue at FSD+0x1922310:

    1922310  48 8B C4                mov  rax, rsp           ; <-- WE FLIP THIS BYTE
    1922313  48 89 48 08             mov  [rax+8], rcx
    1922317  55                      push rbp
    1922318  57                      push rdi
    1922319  48 8D A8 58 FF FF FF    lea  rbp, [rax-0xA8]
    1922320  48 81 EC 98 01 00 00    sub  rsp, 0x198         ; 0x198-byte frame
    1922327  48 83 79 30 00          cmp  qword ptr [rcx+0x30], 0
    192232c  48 8B F9                mov  rdi, rcx
    192232f  0F 84 48 12 00 00       je   FSD+0x192357d      ; bail if analytics nil

  Note the function already has an early-out: it checks whether the
  analytics service pointer (`[rcx+0x30]`) is null and exits if so.  Our
  patch rewrites the very first byte from `0x48` (the REX.W prefix of
  `mov rax, rsp`) to `0xC3` (RET).  The function becomes a single-byte
  function: push return address, immediately pop it and return.  No
  stack frame is allocated, no telemetry keys are emitted, no data-
  gathering helpers are called.

  Why this byte-flip is clean:
   1. The function takes a single pointer argument in RCX (Windows x64
      ABI) and is declared `void` (no return value to fake).  RET with
      RAX undefined is a valid Windows x64 calling-convention return
      for a void function.
   2. No stack space was committed yet (the SUB RSP hasn't executed),
      so there's nothing to unwind.
   3. The single caller treats the call as fire-and-forget:
        `FUN_141922310(uVar6); lVar2 = param_1[0x14]; ...`
      It doesn't read any output, doesn't check for side effects on
      the analytics service object, and continues unconditionally.

  =================== Verification ===================

  - AOB scan: 1 match (confirmed 2026-05-11 via byte-level scan of
    drg-FSD-Win64-Shipping.exe).  File offset 0x1921910 = RVA 0x1922310.
  - Decompilation: Ghidra confirms FUN_141922310 is a telemetry event
    builder emitting key `"mission_start"`.  Strings present in the
    function include `mission_start_data: %s` and
    `mission_start_data part4: %s`.
  - Caller: single UNCONDITIONAL_CALL from FUN_14158b270 at FSD+0x158c0bc
    (plus three DATA references from the analytics vtable area, which
    are not executed -- they're function-pointer slots in a vtable that
    points at this same function and won't be reached because the
    enclosing analytics path is short-circuited at its own check).

  =================== Risk assessment ===================

  Bypassed side effects (these no longer happen at mission start):

   1. The "mission_start" analytics event is never emitted.  This is
      developer-side telemetry that goes to GSG's analytics backend
      (or used to; the network endpoint may already be retired).  No
      user-visible gameplay effect.
   2. The loadout-gathering helpers (FUN_14190dea0/cd50/f540) are never
      called for the purpose of this event.  Those helpers are used in
      other code paths too, so this only suppresses the gathering done
      *for telemetry*, not for actual gameplay state.
   3. The verbose log lines `mission_start_data part4: %s` and
      `mission_start_data: %s` are never printed.  These are gated by
      `2 < DAT_14659c7b8` (verbosity level), so they wouldn't have
      printed in a normal user session anyway.

  Worst case: GSG no longer sees analytics on modded sessions running
  this patch.  That is, by design, what trumank's original `bitfix`
  shipped with, and what mint users have been running for years.

  Not bypassed (still happens as normal):
   - The actual mission start sequence (FUN_14158b270 continues past
     the call).
   - All gameplay-state initialisation in the calling function.
   - All other analytics events at other lifecycle points.

  =================== Caveat / what we didn't pin down ===================

  We did NOT precisely identify which gathering helper overflows with
  >8 players.  The mod community's empirical evidence (and trumank's
  upstream comment) says it does; our verification stopped at confirming
  the function is telemetry and that neutralising it is safe.  If a
  future build relocates this function or changes its prologue, the
  AOB pattern will fail to match and bitfix will log
  `scan results: []` -- at which point you'd need to re-derive the
  pattern from the new build's `mission_start` event-builder.

  =================== Target build ===================

  FSD-Win64-Shipping.exe sha256
    447E89B885E2D7A9941D9FC8DADFCB32EA210AEF7A17D67407EE1248585CB0EF
  UE4 4.27.2-141575+main / build version "main-CL-141575"
  Image base 0x140000000.
  Expected pattern matches: 1.  Confirmed in bitfix.txt on 2026-05-11
  launch.

  =================== Companions ===================

  Pair with `increased_players_difficulty_scaling_fix` for >4-player
  difficulty scaling -- this patch only addresses the mission-load
  crash, not the gameplay-tuning math.
]]

return {
    name = "Increased Players Crash Fix",
    description = "Fix crash when >8 players are in the lobby during mission load",
    category = "crash",
    role = "host",
    default = true,
    patches = {
        {
            -- Function prologue of FSD+0x1922310 ("mission_start" telemetry
            -- event builder).  The bytes are:
            --   00..02  48 8B C4                 mov  rax, rsp        ; <- flip [0] 48 -> C3 (RET)
            --   03..06  48 89 48 08              mov  [rax+8], rcx
            --   07      55                       push rbp
            --   08      57                       push rdi
            --   09..0F  48 8D A8 58 FF FF FF     lea  rbp, [rax-0xA8]
            --   10..16  48 81 EC 98 01 00 00     sub  rsp, 0x198
            --   17..1B  48 83 79 30 00           cmp  qword [rcx+0x30], 0
            --   1C..1E  48 8B F9                 mov  rdi, rcx
            --   1F..20  0F 84                    (first 2 bytes of je rel32)
            pattern = '48 8b c4 48 89 48 08 55 57 48 8d a8 58 ff ff ff 48 81 ec 98 01 00 00 48 83 79 30 00 48 8b f9 0f 84',
            match = function(ctx)
                -- Overwrite the REX.W prefix of `mov rax, rsp` (0x48) with
                -- a near RET (0xC3).  Function becomes a single-byte no-op
                -- on entry; the telemetry event is skipped entirely.
                ctx[ctx:address()] = 0xC3
            end
        },
    }
}
