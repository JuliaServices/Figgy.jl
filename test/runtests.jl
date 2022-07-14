using Figgy, Test

@testset "Figgy.Store" begin
    store = Figgy.Store()
    @test_throws KeyError store["nonexistent"]
    @test_throws KeyError Figgy.getfig(store, "nonexistent")
    @test isempty(Figgy.gethistory(store, "nonexistent"))
    @test get(store, "nonexistent", 3.14) === 3.14

    fig = Figgy.Fig("key", "value", Figgy.ManualSource())
    store["key"] = fig
    @test store["key"] == "value"
    @test Figgy.getfig(store, "key") == fig
    hist = Figgy.gethistory(store, "key")
    @test !isempty(hist)
    @test hist[end] == fig

    fig2 = Figgy.Fig("key2", "value2", Figgy.ManualSource())
    store["key2"] = fig2
    @test store["key2"] == "value2"
    @test Figgy.getfig(store, "key2") == fig2
    hist2 = Figgy.gethistory(store, "key2")
    @test !isempty(hist2)
    @test hist2[end] == fig2

    # multiple configs in history
    fig3 = Figgy.Fig("key", "value3", Figgy.ManualSource())
    store["key"] = fig3
    @test store["key"] == "value3"
    @test Figgy.getfig(store, "key") == fig3
    hist3 = Figgy.gethistory(store, "key")
    @test !isempty(hist3)
    @test hist3[1] == fig
    @test hist3[end] == fig3
end

@testset "Figgy.ProgramArguments" begin
    pas = Figgy.ProgramArguments(
        arg"--key" => "key",
        flag"-key2" => "key2",
        arg"-key3" => "key3",
        arg"-key4" => "key4",
        arg"--key5" => "key5",
        arg"-key6" => "key6",
        flag"-key7" => "key7",
        ; ARGS=[
            "--key=value",
            "-key2",
            "-key3val3",
            "-untrackedflag",
            "-key4",
            "val4",
            "--nonexistent=value",
            "--key5=val5",
            "-key6",
            "val6",
            "-key7",
            "-untracked",
            "value"
        ]
    )
    x = collect(pas)
    @test x == [
        ("key", "value"),
        ("key2", "true"),
        ("key3", "val3"),
        ("key4", "val4"),
        ("key5", "val5"),
        ("key6", "val6"),
        ("key7", "true")
    ]
end

@testset "Figgy.EnvironmentVariables" begin
    envs = Figgy.EnvironmentVariables(
        "KEY" => "key",
        "AWS_KEY" => "aws_key",
        ; env = Dict(
            "KEY" => "val",
            "AWS_KEY" => "aws_val",
            "UNTRACKED" => "val"
        )
    )
    x = Dict(envs)
    @test x == Dict(
        "key" => "val",
        "aws_key" => "aws_val"
    )
end

@testset "Figgy.IniFile" begin
    ini = """
    [default]
    aws_access_key_id=AKIAIOSFODNN7EXAMPLE
    aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
    [named]
    aws_access_key_id=AKIAIOSFODNN7EXAMPLD
    aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEZ
    """
    figs = Figgy.inifile(IOBuffer(ini), "default")
    @test figs == Dict(
        "aws_access_key_id" => "AKIAIOSFODNN7EXAMPLE",
        "aws_secret_access_key" => "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    )
    figs2 = Figgy.inifile(IOBuffer(ini), "named")
    @test figs2 == Dict(
        "aws_access_key_id" => "AKIAIOSFODNN7EXAMPLD",
        "aws_secret_access_key" => "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEZ"
    )
end
