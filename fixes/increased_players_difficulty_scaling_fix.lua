-- Allow difficulty scaling beyond the hard-coded 4-player limit.
-- NOTE: make sure all player-count-based arrays in difficulty settings have
-- enough values for the player count, or bad things will happen.
local patch = function(ctx)
    ctx[ctx:address() + 1] = 0xff
end
return {
    name = "Increased Players Difficulty Scaling",
    description = "Allow difficulty scaling beyond 4 players (pairs with the crash fix)",
    category = "crash",
    default = true,
    patches = {
        { match = patch, pattern = 'ba 04 00 00 00 3b c2 0f 4e d0' },
        { match = patch, pattern = 'b9 04 00 00 00 3b c1 0f 4e c8' },
        { match = patch, pattern = 'b9 04 00 00 00 8b 80 ?? ?? 00 00 3b c1 0f 4d c1' },
        { match = patch, pattern = 'b9 04 00 00 00 8b 40 08 3b c1 0f 4d c1' },
    }
}
