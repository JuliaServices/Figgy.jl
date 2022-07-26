struct ProgramArguments <: FigSource
    args::Vector{Pair{String, String}}
end

"""
    Figgy.ProgramArguments(requiredArgs...)

A FigSource that parses command line arguments to a Julia program.
Specifically, arguments of the following form are parsed:
  * `--key=value`, long-form argument that is parsed as `key => value`
  * `-x`, "flag" argument that is parsed as `x => "true"`
  * `-abc`, multiple flag arguments that result in multiple key value pairs
    of the form `a => "true", b => "true", c => "true"`
  * `-x val`, required argument that is parsed as `x => val`
  * `-xval`, required argument that is parsed as `x => "val"` only when `"x"`
    is passed as a `requiredArgs` like `ProgramArguments("x")`

To transform program argument keys, see [`Figgy.kmap`](@ref).
"""
function ProgramArguments(requiredArgs::String...; args=ARGS)
    parsed = Pair{String, String}[]
    required = Set{String}(requiredArgs)
    i = 1
    while i <= length(args)
        arg = args[i]
        if startswith(arg, "--")
            # long-form
            spl = split(arg, "=")
            length(spl) == 2 || throw(ArgumentError("invalid long-form program argument: `$arg`, expected of the form `--key=value`"))
            push!(parsed, lstrip(spl[1], '-') => spl[2])
        elseif startswith(arg, "-")
            if length(arg) == 2 && i < length(args) && !startswith(args[i + 1], "-")
                # short-form with value
                push!(parsed, lstrip(arg, '-') => args[i + 1])
                i += 1
            elseif length(arg) >= 2 && arg[2:2] in required
                # short-form with required value that is concatenated with arg like: -ofoo
                push!(parsed, arg[2:2] => arg[3:end])
            else
                # short-form boolean falgs
                for j = 2:length(arg)
                    push!(parsed, arg[j:j] => "true")
                end
            end
        else
            # not a program option, so we're done
            break
        end
        i += 1
    end
    return ProgramArguments(parsed)
end

Base.show(io::IO, pa::ProgramArguments) = print(io, "Figgy.ProgramArguments($(length(pa.args) == 1 ? "1 argument" : "$(length(pa.args)) arguments"))")
load(x::ProgramArguments) = x.args

# Environment variables
struct EnvironmentVariables <: FigSource
    env::Vector{Pair{String, String}} # store for testing purposes
end

"""
    Figgy.EnvironmentVariables()

A FigSource that parses environment variables for config. Specifically,
it takes the current contents of the `ENV` global variable for
key-value pairs. Note that environment variable names will be preserved
as-is; to transform/normalize the names, see [`Figgy.kmap`](@ref).
"""
EnvironmentVariables(env::Base.EnvDict=ENV) = EnvironmentVariables([k => v for (k, v) in env])
Base.show(io::IO, x::EnvironmentVariables) = print(io, "Figgy.EnvironmentVariables($(length(x.env) == 1 ? "1 entry" : "$(length(x.env)) entries"))")
load(x::EnvironmentVariables) = x.env

# INI files
"""
    Figgy.IniFile(file, section)

A FigSource that parses an INI file. The `file` argument can be a path
to the INI file, or a `String` that is the contents of the INI file.
The `section` argument is required and specifies the INI file section
that will be parsed for key-value pairs.
"""
struct IniFile <: FigSource
    file::String
    section::String
end

# convenience interface for parsing a specific section of an INI file
# returning key-values of that section
function load(ini::IniFile)
    io = isfile(ini.file) ? open(ini.file) : IOBuffer(ini.file)
    section = ini.section
    figs = Dict{String, String}()
    section = "[$section]"
    insection = false
    for line in eachline(io)
        line = strip(line)
        if insection
            if startswith(line, "#") || startswith(line, ";") || line == ""
                # ignore comments and blank lines
            elseif startswith(line, "[") && endswith(line, "]")
                break
            else
                if contains(line, "=")
                    k, v = split(line, "=")
                elseif contains(line, ":")
                    k, v = split(line, ":")
                else
                    # malformed line? skip
                end
                figs[strip(k)] = strip(v)
            end
        elseif line == section
            insection = true
        end
    end
    return figs
end

"""
    Figgy.JsonObject(json, path="")

A FigSource for parsing simple json as key-value pairs. The `json` argument
must be a `String` which is itself json data, or a `Vector{UInt8}`.
The json is expected to be a json object where the key-values will be considered
key-value config pairs. The `path` argument is optional and is used to
specify a nested path to an object that should be used for config pairs. So a
json object like:
```json
{
    "k": "v",
    "nested": {
        "level2": {
            "key1": "val1",
            "key2": "val2"
        },
        "key3": "val3"
    }
}
```
Where we wish to use the key-value pairs of `nested.level2` for config, could be parsed
like: `Figgy.JsonObject(json, "nested.level2")`.
"""
struct JsonObject <: FigSource
    figs::Dict{String, Any}
end

load(x::JsonObject) = x.figs

function getbyte(buf::AbstractVector{UInt8}, pos)
    @inbounds b = buf[pos]
    return b
end

macro nextbyte(checkwh=true)
    esc(quote
        if pos > len
            throw(EOFError())
        end
        b = getbyte(buf, pos)
        if $checkwh
            while b == UInt8('\t') || b == UInt8(' ') || b == UInt8('\n') || b == UInt8('\r')
                pos += 1
                if pos > len
                    throw(EOFError())
                end
                b = getbyte(buf, pos)
            end
        end
    end)
end

numberbyte(b) = b == UInt8('-') || b == UInt8('+') || b == UInt8('.') || b == UInt8('e') || b == UInt8('E') || UInt8('0') <= b <= UInt8('9')

function readvalue(buf, pos, len, b)
    if b == UInt8('{')
        root = Dict{String, Any}()
        pos += 1
        while true
            @nextbyte
            # @show Char(b)
            b == UInt8('"') || throw(ArgumentError("invalid json object for Figgy.JsonObject config source: expected opening key quote character; $(Char(b))"))
            pos, key = readvalue(buf, pos, len, b)
            @nextbyte
            # @show Char(b)
            b != UInt8(':') && throw(ArgumentError("invalid json object for Figgy.JsonObject config source: expected key-value colon separator"))
            pos += 1
            @nextbyte
            # @show Char(b)
            pos, value = readvalue(buf, pos, len, b)
            root[key] = value
            @nextbyte
            # @show Char(b)
            if b == UInt8('}')
                pos += 1
                # cool, we're done
                break
            elseif b != UInt8(',')
                throw(ArgumentError("invalid json object for Figgy.JsonObject config source: expected comma separator between key-value pairs"))
            end
            pos += 1
        end
        return pos, root
    elseif b == UInt8('[')
        throw(ArgumentError("array values not supported by Figgy.JsonObject for config source"))
    elseif b == UInt8('"')
        pos += 1
        startpos = pos
        while true
            @nextbyte(false)
            if b == UInt8('\\')
                throw(ArgumentError("escape sequences in strings not supported by Figgy.JsonObject for config source"))
            elseif b == UInt8('"')
                pos += 1
                break
            end
            pos += 1
            @nextbyte(false)
        end
        return pos, unsafe_string(pointer(buf, startpos), pos - startpos - 1)
    elseif pos + 3 <= length(buf) &&
        b            == UInt8('n') &&
        buf[pos + 1] == UInt8('u') &&
        buf[pos + 2] == UInt8('l') &&
        buf[pos + 3] == UInt8('l')
        return pos + 4, "null"
    elseif pos + 3 <= length(buf) &&
        b            == UInt8('t') &&
        buf[pos + 1] == UInt8('r') &&
        buf[pos + 2] == UInt8('u') &&
        buf[pos + 3] == UInt8('e')
        return pos + 4, "true"
    elseif pos + 4 <= length(buf) &&
        b            == UInt8('f') &&
        buf[pos + 1] == UInt8('a') &&
        buf[pos + 2] == UInt8('l') &&
        buf[pos + 3] == UInt8('s') &&
        buf[pos + 4] == UInt8('e')
        return pos + 5, "false"
    else # number
        startpos = pos
        while numberbyte(b)
            pos += 1
            @nextbyte(false)
        end
        return pos, unsafe_string(pointer(buf, startpos), pos - startpos)
    end
end

source(x::AbstractVector{UInt8}) = x
source(x::AbstractString) = codeunits(x)

function JsonObject(json::Union{AbstractString, AbstractVector{UInt8}}, path::String="")
    buf = source(json)
    pos = 1
    len = length(buf)
    @nextbyte
    b != UInt8('{') && throw(ArgumentError("invalid json object for Figgy.JsonObject config source: expected opening object curly bracket"))
    pos, root = readvalue(buf, pos, len, b)
    if !isempty(path)
        for key in split(path, '.')
            root = root[key]
        end
    end
    return JsonObject(root)
end

"""
    Figgy.XmlObject(xml, path="")

A FigSource for parsing simple xml as key-value pairs. The `xml` argument
must be a `String` which is itself xml data, or a `Vector{UInt8}`.
The xml is expected to be a xml object where the key-values will be considered
key-value config pairs. The `path` argument is optional and is used to
specify a nested path to an object that should be used for config pairs. So a
xml object like:
```xml
<root>
    <k>v</k>
    <nested>
        <level2>
            <key1>val1</key1>
            <key2>val2</key2>
        </level2>
        <key3>val3</key3>
    </nested>
</root>
```
Where we wish to use the key-value pairs of `nested.level2` for config, could be parsed
like: `Figgy.XmlObject(xml, "nested.level2")`.
"""
struct XmlObject <: FigSource
    figs::Dict{String, Any}
end

load(x::XmlObject) = x.figs

function XmlObject(xml::Union{AbstractString, AbstractVector{UInt8}}, path::String="")
    buf = source(xml)
    pos = 1
    len = length(buf)
    @nextbyte
    b == UInt8('<') || throw(ArgumentError("invalid xml; missing opening tag '<'"))
    pos, (rootkey, root) = readxml(buf, pos, len, b)
    if !isempty(path)
        for key in split(path, '.')
            root = root[key]
        end
    end
    return XmlObject(root)
end

function readxml(buf, pos, len, b)
    pos += 1
    # parse key until space or closing tag
    keystartpos = pos
    foundspace = false
    keylen = 0
    while true
        b = buf[pos]
        #TODO: handle escaped closing tags?
        foundspace = foundspace || b == UInt8(' ')
        b == UInt8('>') && break
        keylen += !foundspace
        pos += 1
    end
    key = unsafe_string(pointer(buf, keystartpos), keylen)
    pos += 1
    @nextbyte
    if b == UInt8('<') && (pos < length(buf) && buf[pos + 1] != UInt8('/'))
        # nested object
        val = Dict{String, Any}()
        while true
            pos, kv = readxml(buf, pos, len, b)
            val[kv.first] = kv.second
            @nextbyte
            if b == UInt8('<') && (pos < length(buf) && buf[pos + 1] == UInt8('/'))
                pos += 2
                for i = 0:(keylen - 1)
                    buf[pos] == buf[keystartpos + i] || throw(ArgumentError("malformed xml; expected closing tag for key: `$key`"))
                    pos += 1
                end
                b = buf[pos]
                b == UInt8('>') || throw(ArgumentError("malformed xml; expected closing tag for key: `$key`"))
                pos += 1
                break
            end
        end
        return pos, key => val
    else
        # string value
        strstartpos = pos
        strlen = 0
        while true
            b = buf[pos]
            if b == UInt8('<')
                pos += 1
                b = buf[pos]
                b == UInt8('/') || throw(ArgumentError("malformed xml; expected closing tag for key: `$key`"))
                pos += 1
                for i = 0:(keylen - 1)
                    buf[pos] == buf[keystartpos + i] || throw(ArgumentError("malformed xml; expected closing tag for key: `$key`"))
                    pos += 1
                end
                b = buf[pos]
                b == UInt8('>') || throw(ArgumentError("malformed xml: expected closing tag for key: `$key`"))
                pos += 1
                break
            end
            strlen += 1
            pos += 1
        end
        str = unsafe_string(pointer(buf, strstartpos), strlen)
        return pos, key => str
    end
end

struct TomlObject <: FigSource
    figs::Dict{String, Any}
end

load(x::TomlObject) = x.figs

"""
    Figgy.TomlObject(file, path="")

A FigSource for loading config key-value pairs from .toml files. The `file`
argument can be a path to a .toml file, or a `String` of which the contents
is toml data directly. The `path` argument is optional and is used to
specify a nested path to an object that should be used for config pairs.
"""
function TomlObject(file::String, path="")
   if isfile(file)
        figs = TOML.parsefile(file)
   else
        figs = TOML.parse(file)
   end
   for key in split(path, '.')
        figs = figs[key]
   end
   return TomlObject(figs)
end
