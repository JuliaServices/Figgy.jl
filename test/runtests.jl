using Figgy, Test

@testset "Figgy" begin

@testset "Figgy.Store" begin
    store = Figgy.Store()
    @test_throws KeyError store["nonexistent"]
    @test_throws KeyError Figgy.getfig(store, "nonexistent")
    @test get(store, "nonexistent", 3.14) === 3.14

    Figgy.load!(store, "key" => "value")
    @test store["key"] == "value"
    @test sprint(show, store) == "Figgy.Store:\n  key: `value` from `Figgy.ObjectSource(Pair{String, String})`, 1 entry"
    fig = Figgy.getfig(store, "key")
    @test fig[] == "value"
    Figgy.update!(fig, "value2", Figgy.NamedSource("manual"))
    @test fig[] == "value2"
    @test store["key"] == "value2"
    
    Figgy.load!(store, (key2="value3",); name="nt")
    @test haskey(store, "key2")
    fig = Figgy.getfig(store, "key2")
    @test fig.sources[end] isa Figgy.NamedSource

    delete!(store, "key2")
    @test !haskey(store, "key2")
    empty!(store)
    @test !haskey(store, "key")
end

@testset "Figgy.kmap" begin
    store = Figgy.Store()
    src = Dict("k" => "v", "k2" => "v2")
    Figgy.load!(store, Figgy.kmap(src, "k2" => "kk2"))
    @test store["k"] == "v"
    @test store["kk2"] == "v2"
    @test !haskey(store, "k2")
    empty!(store)
    Figgy.load!(store, Figgy.kmap(src, "k2" => k -> "kk2"))
    @test store["k"] == "v"
    @test store["kk2"] == "v2"
    @test !haskey(store, "k2")
    empty!(store)
    Figgy.load!(store, Figgy.kmap(src, k -> uppercase(k)))
    @test store["K"] == "v"
    @test store["K2"] == "v2"
    empty!(store)
    Figgy.load!(store, Figgy.kmap(src, "k2" => "kk2"; select=true))
    @test store["kk2"] == "v2"
    @test !haskey(store, "k")
end

@testset "Figgy.select" begin
    store = Figgy.Store()
    src = Dict("k" => "v", "k2" => "v2")
    Figgy.load!(store, Figgy.select(src, "k"))
    @test store["k"] == "v"
    @test !haskey(store, "k2")
    empty!(store)
    Figgy.load!(store, Figgy.select(src, k -> (k == "k")))
    @test store["k"] == "v"
    @test !haskey(store, "k2")
end

@testset "Figgy.ProgramArguments" begin
    pas = Figgy.ProgramArguments("c";
        args=[
            "--key=value",
            "-b",
            "-cval3",
            "-def",
            "-g",
            "val4",
            "--key5=val5",
            "-h",
            "val6",
            "value"
        ]
    )
    store = Figgy.Store()
    Figgy.load!(store, pas)
    @test store["key"] == "value"
    @test store["b"] == "true"
    @test store["c"] == "val3"
    @test store["d"] == "true"
    @test store["e"] == "true"
    @test store["f"] == "true"
    @test store["g"] == "val4"
    @test store["key5"] == "val5"
    @test store["h"] == "val6"
end

@testset "Figgy.EnvironmentVariables" begin
    store = Figgy.Store()
    withenv("key" => "value", "key2" => "value2") do
        Figgy.load!(store, Figgy.EnvironmentVariables())
    end
    @test store["key"] == "value"
    @test store["key2"] == "value2"
end

@testset "Figgy.IniFile" begin
    store = Figgy.Store()
    ini = """
    [default]
    aws_access_key_id=AKIAIOSFODNN7EXAMPLE
    aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
    [named]
    aws_access_key_id=AKIAIOSFODNN7EXAMPLD
    aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEZ
    """
    Figgy.load!(store, Figgy.IniFile(ini, "default"))
    @test store["aws_access_key_id"] == "AKIAIOSFODNN7EXAMPLE"
    @test store["aws_secret_access_key"] == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    Figgy.load!(store, Figgy.IniFile(ini, "named"))
    @test store["aws_access_key_id"] == "AKIAIOSFODNN7EXAMPLD"
    @test store["aws_secret_access_key"] == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEZ"
end

@testset "Figgy.JsonObject" begin
    store = Figgy.Store()
    json = """
    {
        "key": "value",
        "key2": "value2",
        "key3": {
            "key4": "value4"
        }
    }
    """
    Figgy.load!(store, Figgy.JsonObject(json))
    @test store["key"] == "value"
    @test store["key2"] == "value2"
    @test store["key3"]["key4"] == "value4"
    empty!(store)
    Figgy.load!(store, Figgy.JsonObject(json, "key3"))
    @test store["key4"] == "value4"
    @test !haskey(store, "key")
end

@testset "Figgy.XmlObject" begin
    store = Figgy.Store()
    xml = """
    <AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
    <AssumeRoleResult>
        <SourceIdentity>Alice</SourceIdentity>
        <AssumedRoleUser>
        <Arn>arn:aws:sts::123456789012:assumed-role/demo/TestAR</Arn>
        <AssumedRoleId>ARO123EXAMPLE123:TestAR</AssumedRoleId>
        </AssumedRoleUser>
        <Credentials>
        <AccessKeyId>ASIAIOSFODNN7EXAMPLE</AccessKeyId>
        <SecretAccessKey>wJalrXUtnFEMI/K7MDENG/bPxRfiCYzEXAMPLEKEY</SecretAccessKey>
        <SessionToken>
        AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQW
        LWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/qkPpKPi/kMcGd
        QrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU
        9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz
        +scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA==
        </SessionToken>
        <Expiration>2019-11-09T13:34:41Z</Expiration>
        </Credentials>
        <PackedPolicySize>6</PackedPolicySize>
    </AssumeRoleResult>
    <ResponseMetadata>
        <RequestId>c6104cbe-af31-11e0-8154-cbc7ccf896c7</RequestId>
    </ResponseMetadata>
    </AssumeRoleResponse>
    """
    Figgy.load!(store, Figgy.XmlObject(xml))
    @test haskey(store, "AssumeRoleResult")
    empty!(store)
    Figgy.load!(store, Figgy.XmlObject(xml, "AssumeRoleResult.Credentials"))
    @test store["AccessKeyId"] == "ASIAIOSFODNN7EXAMPLE"
    @test store["SecretAccessKey"] == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYzEXAMPLEKEY"
end

@testset "Figgy.TomlObject" begin
    data = """
           [database]
           server = "192.168.1.1"
           ports = [ 8001, 8001, 8002 ]
       """;
    store = Figgy.Store()
    Figgy.load!(store, Figgy.TomlObject(data, "database"))
    @test store["server"] == "192.168.1.1"
    @test store["ports"] == [ 8001, 8001, 8002 ]
    data = """
    server = "192.168.1.2"
    """
    store = Figgy.Store()
    Figgy.load!(store, Figgy.TomlObject(data))
    @test store["server"] == "192.168.1.2"
end

end # @testset "Figgy"