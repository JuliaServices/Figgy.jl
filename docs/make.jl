using Documenter, Figgy

makedocs(;
    pages=[
        "Home" => "index.md",
        "API Reference" => "reference.md",
    ],
    sitename="Figgy.jl",
)

deploydocs(;
    repo="github.com/JuliaServices/Figgy.jl",
    devbranch = "main",
    push_preview = true,
)
