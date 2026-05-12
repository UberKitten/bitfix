-- Show normal terrain on the terrain scanner instead of the scanner material.
return {
    name = "Normal Terrain Scanner Material",
    description = "Show normal terrain on the scanner instead of scanner material",
    category = "visual",
    default = false,
    patches = {
        {
            pattern = '74 ?? 49 8B 4C 24 ?? EB ?? 49 8B 0C 24',
            match = function(ctx)
                ctx[ctx:address()] = 0x75
            end
        }
    }
}
