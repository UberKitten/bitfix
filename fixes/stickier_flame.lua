-- Allow sticky flames to stick to any actor, not just terrain.
local patch = function(offset, distance)
    return function(ctx)
        ctx[ctx:address() + offset] = 0xEB
        ctx[ctx:address() + offset + 1] = distance
    end
end
return {
    name = "Stickier Flame",
    description = "Sticky flames stick to any actor, not just terrain",
    category = "gameplay",
    default = false,
    patches = {
        -- UStickyFlameSpawner::TrySpawnStickyFlameHit
        {
            pattern = '48 89 5c 24 08 48 89 6c 24 10 48 89 74 24 18 57 48 83 ec 70 48 8b f9 48 8b f2 48 8d 4a 68',
            match = patch(0x2C, 0x32)
        },
        {
            pattern = '48 89 5c 24 08 48 89 6c 24 10 48 89 74 24 18 57 48 83 ec 40 48 8b e9 48 8b fa 48 8d 4a 68',
            match = patch(0x28, 0x2A)
        },
    }
}
