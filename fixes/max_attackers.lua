-- Increase the MaxAttackers cap to 200.
return {
    name = "Max Attackers 200",
    description = "Increase MaxAttackers cap to 200",
    category = "gameplay",
    default = false,
    patches = {
        {
            -- UPlayerAttackPositionComponent::GetScore
            pattern = '48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 48 83 EC 30 48 8B 01 41 0F',
            match = function(ctx)
                ctx[ctx:address() + 89] = 200
                ctx[ctx:address() + 187] = 200
            end
        },
        {
            -- UAttackerPositioningComponent::UAttackerPositioningComponent
            pattern = '48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 48 89 7C 24 20 41 56 48 81 EC D0 00 00 00 48 8B F9 E8 ?? ?? ?? ?? 48 8B D0 48 8B CF E8 ?? ?? ?? ?? 33 DB',
            match = function(ctx)
                ctx[ctx:address() + 56] = 200
            end
        }
    }
}
