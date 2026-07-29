using Base64, Figgy, Test

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

@testset "Figgy.Store dict-like API" begin
    store = Figgy.Store()
    @test isempty(store)
    @test length(store) == 0
    @test isempty(keys(store))
    @test isempty(values(store))
    @test collect(store) == Pair{String, Any}[]
    @test get(() -> "computed", store, "missing") == "computed"

    Figgy.load!(store, "a" => "1", "b" => "2"; log=false)
    @test !isempty(store)
    @test length(store) == 2
    @test sort(keys(store)) == ["a", "b"]
    @test sort(values(store)) == ["1", "2"]
    @test sort(collect(store); by=first) == ["a" => "1", "b" => "2"]
    @test get(() -> "computed", store, "a") == "1"

    store["c"] = "3"
    @test store["c"] == "3"
    @test length(store) == 3
    fig = Figgy.getfig(store, "c")
    @test fig.sources[end] == Figgy.NamedSource("manual")
    store["c"] = "4"
    @test store["c"] == "4"
    @test length(fig.values) == 2
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

@testset "Figgy.kmap/select iteration" begin
    src = Dict("k" => "v", "k2" => "v2", "k3" => "v3")
    # collect used to produce #undef entries when keys were filtered out
    @test collect(Figgy.select(src, "k")) == ["k" => "v"]
    @test collect(Figgy.kmap(src, "k" => "kk"; select=true)) == ["kk" => "v"]
    @test sort(collect(Figgy.kmap(src, "k" => "kk"))) == ["k2" => "v2", "k3" => "v3", "kk" => "v"]
    @test Base.IteratorSize(typeof(Figgy.select(src, "k"))) == Base.SizeUnknown()
    @test Base.IteratorSize(typeof(Figgy.kmap(src, "k" => "kk"))) == Base.SizeUnknown()
    # filtering out many consecutive keys used to blow the stack via recursion
    bigsrc = Dict("key$i" => "v" for i = 1:200_000)
    @test collect(Figgy.select(bigsrc, "nomatch")) == []
    @test length(collect(Figgy.kmap(bigsrc, "key1" => "mapped"; select=true))) == 1
end

@testset "Figgy.Crypt" begin
    salt = UInt8.(1:16)
    iv = UInt8.(17:28)
    enc = Figgy.encrypt("secret", "hello"; salt=salt, iv=iv)
    @test enc == "ENC[figgy-v1](RklHQ1JZUFQBAwEAAzRQIBAMEAAAAAUBAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscxph1MdIWaeW7MN9IYrGzEn5K0KD2)"
    @test Figgy.Crypt.is_encrypted(enc)
    @test Figgy.decrypt("secret", enc) == "hello"
    @test Figgy.decrypt(UInt8.(codeunits("secret")), enc) == "hello"
    envelope = Figgy.Crypt.parse_envelope(enc)
    @test envelope.format == :figgy_v1
    @test envelope.key_id === nothing
    @test_throws Figgy.Crypt.InvalidCiphertextError Figgy.decrypt("wrong", enc)

    keyed = Figgy.encrypt("secret", "hello"; salt=salt, iv=iv, key_id="v1")
    @test Figgy.Crypt.parse_envelope(keyed).key_id == "v1"
    @test Figgy.decrypt(Dict("v1" => "secret"), keyed) == "hello"
    @test_throws KeyError Figgy.decrypt(Dict("v2" => "secret"), keyed)
    @test_throws ArgumentError Figgy.encrypt("secret", "hello"; key_id="bad key")
    @test :encrypt in names(Figgy.Crypt)
    @test :decrypt in names(Figgy.Crypt)

    aad_enc = Figgy.encrypt("secret", "hello"; salt=salt, iv=iv, aad="figgy")
    @test Figgy.decrypt("secret", aad_enc; aad="figgy") == "hello"
    @test_throws Figgy.Crypt.InvalidCiphertextError Figgy.decrypt("secret", aad_enc; aad="other")

    tampered = copy(envelope.payload)
    tampered[end] ⊻= 0x01
    @test_throws Figgy.Crypt.InvalidCiphertextError Figgy.decrypt("secret", "ENC[figgy-v1]($(base64encode(tampered)))")

    empty_enc = Figgy.encrypt("secret", UInt8[]; salt=salt, iv=iv)
    @test Figgy.Crypt.decrypt_bytes("secret", empty_enc) == UInt8[]

    aes128 = Figgy.Crypt.CipherConfig(; algorithm=:aes_128_gcm, iterations=1_000)
    enc128 = Figgy.encrypt("secret", "small"; config=aes128, salt=salt, iv=iv)
    @test Figgy.decrypt("secret", enc128) == "small"

    jasypt = Figgy.Crypt.jasypt_config(iterations=1_000)
    jasypt_iv = UInt8.(17:32)
    jasypt_enc = Figgy.encrypt("secret", "hello"; config=jasypt, salt=salt, iv=jasypt_iv)
    @test jasypt_enc == "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyALLoLpqB+dUx0JfqS5Cze2"
    @test Figgy.decrypt("secret", jasypt_enc; config=jasypt) == "hello"
    @test Figgy.decrypt("secret", "ENC($jasypt_enc)"; config=jasypt) == "hello"
    @test_throws Figgy.Crypt.InvalidCiphertextError Figgy.decrypt("wrong", jasypt_enc; config=jasypt)

    # a bare (wrap=false) figgy payload still round-trips without a config
    bare = Figgy.encrypt("secret", "hello"; salt=salt, iv=iv, wrap=false)
    @test !startswith(bare, "ENC")
    @test Figgy.decrypt("secret", bare) == "hello"

    # the self-describing figgy envelope wins over a mismatched explicit config
    @test Figgy.decrypt("secret", enc; config=jasypt) == "hello"

    # PBKDF2 iteration counts are bounded
    @test_throws ArgumentError Figgy.Crypt.CipherConfig(; iterations=0)
    @test_throws ArgumentError Figgy.Crypt.CipherConfig(; iterations=20_000_000)
    # a crafted payload claiming ~4 billion iterations is rejected instead of stalling decrypt
    crafted = copy(Figgy.Crypt.parse_envelope(enc).payload)
    crafted[12:15] .= 0xff
    @test_throws Figgy.Crypt.InvalidCiphertextError Figgy.decrypt("secret", "ENC[figgy-v1]($(base64encode(crafted)))")
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

    # long-form values may contain `=` characters
    pa = Figgy.ProgramArguments(; args=["--url=http://host?a=b", "--token=abc=="])
    @test pa.args == ["url" => "http://host?a=b", "token" => "abc=="]
    # long-form boolean flags
    pa = Figgy.ProgramArguments(; args=["--verbose", "--key=value"])
    @test pa.args == ["verbose" => "true", "key" => "value"]
    # `--` ends option parsing
    pa = Figgy.ProgramArguments(; args=["--key=value", "--", "--notparsed=1"])
    @test pa.args == ["key" => "value"]
    # bare `-` (conventionally stdin) ends option parsing
    pa = Figgy.ProgramArguments(; args=["-a", "-", "-b"])
    @test pa.args == ["a" => "true"]
    # empty long-form key is invalid
    @test_throws ArgumentError Figgy.ProgramArguments(; args=["--=value"])
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

    # values may contain separator characters; the first `=` or `:` delimits
    ini2 = """
    [default]
    secret=abc123==
    endpoint: http://localhost:8080
    mixed = key:with=both
    malformed line without separator
    trailing=ok
    """
    figs = Figgy.load(Figgy.IniFile(ini2, "default"))
    @test figs["secret"] == "abc123=="
    @test figs["endpoint"] == "http://localhost:8080"
    @test figs["mixed"] == "key:with=both"
    @test figs["trailing"] == "ok"
    @test length(figs) == 4

    # a file path can be provided instead of contents
    mktemp() do path, io
        write(io, ini2)
        close(io)
        figs = Figgy.load(Figgy.IniFile(path, "default"))
        @test figs["secret"] == "abc123=="
    end
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

    # empty objects
    @test Figgy.JsonObject("{}").figs == Dict{String, Any}()
    @test Figgy.JsonObject(" { } ").figs == Dict{String, Any}()
    nested = Figgy.JsonObject("""{"a": {}, "b": "c"}""")
    @test nested.figs == Dict{String, Any}("a" => Dict{String, Any}(), "b" => "c")

    # string escape sequences
    escaped = Figgy.JsonObject("""{"k\\"1": "line1\\nline2", "k2": "a \\"quote\\" and \\\\ slash \\/ ok", "k3": "tab\\there", "k4": "\\u0041\\u00e9\\u4e2d", "k5": "\\ud834\\udd1e"}""")
    @test escaped.figs["k\"1"] == "line1\nline2"
    @test escaped.figs["k2"] == "a \"quote\" and \\ slash / ok"
    @test escaped.figs["k3"] == "tab\there"
    @test escaped.figs["k4"] == "Aé中"
    @test escaped.figs["k5"] == "𝄞"
    @test_throws ArgumentError Figgy.JsonObject("""{"k": "\\q"}""")
    @test_throws ArgumentError Figgy.JsonObject("""{"k": "\\ud834"}""")
    @test_throws ArgumentError Figgy.JsonObject("""{"k": "\\u12"}""")

    # a file path can be provided instead of contents
    mktemp() do path, io
        write(io, json)
        close(io)
        j = Figgy.JsonObject(path, "key3")
        @test j.figs["key4"] == "value4"
    end
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
    # multi-line text values have surrounding whitespace trimmed
    @test endswith(store["SessionToken"], "R/oLxBA==")
    @test !endswith(store["SessionToken"], "\n")

    # xml declarations, comments, doctypes, and self-closing tags
    xml2 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE root>
    <!-- top-level comment -->
    <root>
        <!-- comment between elements -->
        <k>v</k>
        <empty/>
        <alsoempty attr="x"/>
        <blank></blank>
        <nested>
            <inner>value</inner>
        </nested>
    </root>
    """
    x = Figgy.XmlObject(xml2)
    @test x.figs["k"] == "v"
    @test x.figs["empty"] == ""
    @test x.figs["alsoempty"] == ""
    @test x.figs["blank"] == ""
    @test x.figs["nested"] == Dict{String, Any}("inner" => "value")

    # a file path can be provided instead of contents
    mktemp() do path, io
        write(io, xml2)
        close(io)
        x = Figgy.XmlObject(path, "nested")
        @test x.figs["inner"] == "value"
    end
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

include("trim_compile_tests.jl")
