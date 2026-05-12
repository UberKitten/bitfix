-- Fix crash when more than 8 players are in the lobby during mission load.
-- Pair with `increased_players_difficulty_scaling_fix` for >4-player scaling.
return {
    name = "Increased Players Crash Fix",
    description = "Fix crash when >8 players are in the lobby during mission load",
    category = "crash",
    default = true,
    patches = {
        {
            pattern = '48 8b c4 48 89 48 08 55 57 48 8d a8 58 ff ff ff 48 81 ec 98 01 00 00 48 83 79 30 00 48 8b f9 0f 84',
            match = function(ctx)
                ctx[ctx:address()] = 0xC3
            end
        },
    }
}
