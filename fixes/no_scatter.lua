-- Prevent explosions from scattering minerals.
return {
    name = "No Mineral Scatter",
    description = "Prevent explosions from scattering minerals",
    category = "gameplay",
    default = false,
    patches = {
        {
            -- FGrenadeExplodeOperation::FGrenadeExplodeOperation
            pattern = 'f3 0f 11 43 ?? 76 14 f3',
            match = function(ctx)
                ctx[ctx:address() + 0x00] = 0x90
                ctx[ctx:address() + 0x01] = 0x90
                ctx[ctx:address() + 0x02] = 0x90
                ctx[ctx:address() + 0x03] = 0x90
                ctx[ctx:address() + 0x04] = 0x90
            end
        }
    }
}
