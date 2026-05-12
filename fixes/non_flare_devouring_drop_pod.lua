-- Stop the drop pod from eating flares. (Why does it do that?)
return {
    name = "Non-Flare-Devouring Drop Pod",
    description = "Stop the drop pod from eating flares",
    category = "gameplay",
    default = false,
    patches = {
        {
            pattern = '3B 51 ?? 7F ?? 48 8B 49 ?? 48 39 04 D1 75 ?? 48 8B D3 48 8B CF E8 ?? ?? ?? ?? 48 8B 5C 24',
            match = function(ctx)
                ctx[ctx:address() + 13] = 0xEB
            end
        },
    }
}
