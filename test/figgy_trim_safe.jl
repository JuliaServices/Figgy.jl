using Figgy

function _trim_assert(condition::Bool, msg::AbstractString)::Nothing
    condition || error(msg)
    return nothing
end

function _trim_load_store()::Figgy.Store
    store = Figgy.Store()
    Figgy.load!(
        store,
        Figgy.kmap(
            Dict("raw_host" => "db.internal", "raw_port" => "5432"),
            "raw_host" => "host",
            "raw_port" => "port",
        );
        log = false,
    )
    Figgy.load!(
        store,
        Figgy.select(
            Dict("feature" => "enabled", "ignored" => "nope"),
            key -> key == "feature",
        );
        log = false,
    )
    Figgy.load!(
        store,
        Figgy.ProgramArguments("p"; args = ["--mode=test", "-p8443", "-abc", "positional"]);
        log = false,
    )
    Figgy.load!(
        store,
        Figgy.ProgramArguments(; args = ["--verbose", "--endpoint=http://host?a=b", "--", "--ignored=1"]);
        log = false,
    )
    return store
end

function _trim_load_document_sources(store::Figgy.Store)::Nothing
    ini = """
    [default]
    region = us-west-2
    retries: 3
    token = abc123==
    [other]
    region = us-east-1
    """
    Figgy.load!(store, Figgy.IniFile(ini, "default"); log = false)

    json = """
    {
        "service": {
            "url": "https://example.invalid",
            "enabled": true,
            "count": 2,
            "quoted": "a \\"b\\" c",
            "empty": {}
        },
        "unused": "ignored"
    }
    """
    Figgy.load!(store, Figgy.JsonObject(json, "service"); log = false)

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- config sample -->
    <root>
        <database>
            <username>figgy</username>
            <password>secret</password>
            <replica/>
        </database>
    </root>
    """
    Figgy.load!(store, Figgy.XmlObject(xml, "database"); log = false)

    toml = """
    [limits]
    timeout = 30
    burst = 4
    """
    Figgy.load!(store, Figgy.TomlObject(toml, "limits"); log = false)
    return nothing
end

function run_figgy_trim_sample()::Nothing
    store = _trim_load_store()
    _trim_load_document_sources(store)

    _trim_assert((store["host"]::String) == "db.internal", "kmap host")
    _trim_assert((store["port"]::String) == "5432", "kmap port")
    _trim_assert((store["feature"]::String) == "enabled", "select feature")
    _trim_assert(!haskey(store, "ignored"), "select ignored")
    _trim_assert((store["mode"]::String) == "test", "program long option")
    _trim_assert((store["p"]::String) == "8443", "program required value")
    _trim_assert((store["a"]::String) == "true", "program flag a")
    _trim_assert((store["b"]::String) == "true", "program flag b")
    _trim_assert((store["c"]::String) == "true", "program flag c")
    _trim_assert((store["verbose"]::String) == "true", "program long flag")
    _trim_assert((store["endpoint"]::String) == "http://host?a=b", "program long value with =")
    _trim_assert(!haskey(store, "ignored"), "program -- terminator")
    _trim_assert((store["region"]::String) == "us-west-2", "ini section")
    _trim_assert((store["retries"]::String) == "3", "ini colon")
    _trim_assert((store["token"]::String) == "abc123==", "ini value with =")
    _trim_assert((store["url"]::String) == "https://example.invalid", "json string")
    _trim_assert((store["enabled"]::String) == "true", "json bool")
    _trim_assert((store["count"]::String) == "2", "json number")
    _trim_assert((store["quoted"]::String) == "a \"b\" c", "json escaped string")
    _trim_assert(isempty(store["empty"]::Dict{String, Any}), "json empty object")
    _trim_assert((store["username"]::String) == "figgy", "xml username")
    _trim_assert((store["password"]::String) == "secret", "xml password")
    _trim_assert((store["replica"]::String) == "", "xml self-closing tag")
    _trim_assert((store["timeout"]::Int) == 30, "toml timeout")
    _trim_assert((store["burst"]::Int) == 4, "toml burst")

    fig = Figgy.getfig(store, "host")
    _trim_assert((fig[]::String) == "db.internal", "getfig")
    _trim_assert((get(store, "missing", "fallback")::String) == "fallback", "get fallback")
    _trim_assert((get(() -> "computed", store, "missing")::String) == "computed", "get callable fallback")
    _trim_assert(length(store) > 0, "length")
    _trim_assert(!isempty(store), "isempty")
    _trim_assert(length(keys(store)) == length(store), "keys snapshot")
    store["manual"] = "42"
    _trim_assert((store["manual"]::String) == "42", "setindex!")
    n = 0
    for kv in store
        n += 1
    end
    _trim_assert(n == length(store), "iterate snapshot")
    delete!(store, "password")
    _trim_assert(!haskey(store, "password"), "delete")
    empty!(store)
    _trim_assert(!haskey(store, "host"), "empty")
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_figgy_trim_sample()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
