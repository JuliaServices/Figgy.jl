struct ProgramArguments <: FigSource
    args::Vector{Pair{String, String}}
end

"""
    Figgy.ProgramArguments(requiredArgs...)

A FigSource that parses command line arguments to a Julia program.
Specifically, arguments of the following form are parsed:
  * `--key=value`, long-form argument that is parsed as `key => value`;
    the value may itself contain `=` characters (only the first `=` delimits)
  * `--key`, long-form "flag" argument that is parsed as `key => "true"`
  * `-x`, "flag" argument that is parsed as `x => "true"`
  * `-abc`, multiple flag arguments that result in multiple key value pairs
    of the form `a => "true", b => "true", c => "true"`
  * `-x val`, required argument that is parsed as `x => val`
  * `-xval`, required argument that is parsed as `x => "val"` only when `"x"`
    is passed as a `requiredArgs` like `ProgramArguments("x")`

Parsing stops at the first non-option argument, at a bare `-`, or at the
conventional `--` end-of-options terminator.

To transform program argument keys, see [`Figgy.kmap`](@ref).
"""
function ProgramArguments(requiredArgs::String...; args=ARGS)
    parsed = Pair{String, String}[]
    required = Set{String}(requiredArgs)
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--" || arg == "-"
            # `--` is the conventional end-of-options terminator; a bare `-`
            # conventionally means stdin and is treated as a non-option argument
            break
        elseif startswith(arg, "--")
            # long-form
            spl = split(arg, '='; limit=2)
            key = lstrip(spl[1], '-')
            isempty(key) && throw(ArgumentError("invalid long-form program argument: `$arg`, expected of the form `--key=value` or `--key`"))
            if length(spl) == 2
                push!(parsed, key => spl[2])
            else
                # long-form boolean flag like `--verbose`
                push!(parsed, key => "true")
            end
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

# treat `x` as a file path if it names an existing file, otherwise as the contents itself
function _filecontents(x::AbstractString)
    isfilepath = false
    try
        isfilepath = !occursin('\n', x) && isfile(x)
    catch
        # not a valid path (too long, embedded NULs, etc.); treat as contents
    end
    return isfilepath ? read(x, String) : String(x)
end

# INI files
"""
    Figgy.IniFile(file, section)

A FigSource that parses an INI file. The `file` argument can be a path
to the INI file, or a `String` that is the contents of the INI file.
The `section` argument is required and specifies the INI file section
that will be parsed for key-value pairs. Within a section, each line is
split on the first `=` or `:` (whichever comes first), so values may
themselves contain separator characters; lines with no separator are ignored.
"""
struct IniFile <: FigSource
    file::String
    section::String
end

# convenience interface for parsing a specific section of an INI file
# returning key-values of that section
function load(ini::IniFile)
    contents = _filecontents(ini.file)
    section = ini.section
    figs = Dict{String, String}()
    section = "[$section]"
    insection = false
    for line in split(contents, '\n')
        line = strip(line)
        if insection
            if startswith(line, "#") || startswith(line, ";") || line == ""
                # ignore comments and blank lines
            elseif startswith(line, "[") && endswith(line, "]")
                break
            else
                # split on the first `=` or `:`, whichever comes first,
                # so values may contain separator characters (base64, urls, etc.)
                eq = findfirst(isequal('='), line)
                co = findfirst(isequal(':'), line)
                sep = eq === nothing ? co : (co === nothing ? eq : min(eq, co))
                # skip malformed lines with no key-value separator
                sep === nothing && continue
                figs[strip(line[1:prevind(line, sep)])] = strip(line[nextind(line, sep):end])
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
can be a path to a json file, a `String` which is itself json data, or a
`Vector{UInt8}` of json data.
The json is expected to be a json object where the key-values will be considered
key-value config pairs. String values may contain standard json escape
sequences (`\\"`, `\\\\`, `\\/`, `\\b`, `\\f`, `\\n`, `\\r`, `\\t`, and `\\uXXXX`),
which are unescaped. Note that json array values are not supported.
The `path` argument is optional and is used to
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

# parse 4 hex digits at `pos`; all digits must lie strictly before `endpos`
function _hex4(buf, pos, endpos)
    pos + 3 < endpos || throw(ArgumentError("invalid json string: truncated \\u escape"))
    u = UInt32(0)
    for j = 0:3
        b = getbyte(buf, pos + j)
        d = UInt8('0') <= b <= UInt8('9') ? b - UInt8('0') :
            UInt8('a') <= b <= UInt8('f') ? b - UInt8('a') + 0x0a :
            UInt8('A') <= b <= UInt8('F') ? b - UInt8('A') + 0x0a :
            throw(ArgumentError("invalid json string: invalid \\u escape digit"))
        u = (u << 4) | d
    end
    return u
end

# read a json string starting at the opening quote at `pos`;
# returns the position after the closing quote and the (unescaped) string
function readstring(buf, pos, len)
    pos += 1
    startpos = pos
    hasescape = false
    while true
        pos > len && throw(EOFError())
        b = getbyte(buf, pos)
        if b == UInt8('\\')
            hasescape = true
            pos += 2
        elseif b == UInt8('"')
            break
        else
            pos += 1
        end
    end
    endpos = pos # position of the closing quote
    hasescape || return endpos + 1, unsafe_string(pointer(buf, startpos), endpos - startpos)
    out = IOBuffer()
    i = startpos
    while i < endpos
        b = getbyte(buf, i)
        if b != UInt8('\\')
            write(out, b)
            i += 1
            continue
        end
        e = getbyte(buf, i + 1)
        i += 2
        if e == UInt8('"') || e == UInt8('\\') || e == UInt8('/')
            write(out, e)
        elseif e == UInt8('b')
            write(out, UInt8('\b'))
        elseif e == UInt8('f')
            write(out, UInt8('\f'))
        elseif e == UInt8('n')
            write(out, UInt8('\n'))
        elseif e == UInt8('r')
            write(out, UInt8('\r'))
        elseif e == UInt8('t')
            write(out, UInt8('\t'))
        elseif e == UInt8('u')
            u = _hex4(buf, i, endpos)
            i += 4
            if 0xd800 <= u <= 0xdbff
                # high surrogate; must be followed by an escaped low surrogate
                (i + 1 < endpos && getbyte(buf, i) == UInt8('\\') && getbyte(buf, i + 1) == UInt8('u')) ||
                    throw(ArgumentError("invalid json string: unpaired surrogate \\u escape"))
                u2 = _hex4(buf, i + 2, endpos)
                0xdc00 <= u2 <= 0xdfff || throw(ArgumentError("invalid json string: unpaired surrogate \\u escape"))
                i += 6
                u = UInt32(0x10000) + ((u - UInt32(0xd800)) << 10) + (u2 - UInt32(0xdc00))
            elseif 0xdc00 <= u <= 0xdfff
                throw(ArgumentError("invalid json string: unpaired surrogate \\u escape"))
            end
            write(out, Char(u))
        else
            throw(ArgumentError("invalid json string escape sequence: `\\$(Char(e))`"))
        end
    end
    return endpos + 1, String(take!(out))
end

function readvalue(buf, pos, len, b)
    if b == UInt8('{')
        root = Dict{String, Any}()
        pos += 1
        firstkey = true
        while true
            @nextbyte
            # @show Char(b)
            if firstkey && b == UInt8('}')
                # empty object
                pos += 1
                break
            end
            firstkey = false
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
        return readstring(buf, pos, len)
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
    buf = json isa AbstractString ? source(_filecontents(json)) : source(json)
    pos = 1
    len = length(buf)
    @nextbyte
    b != UInt8('{') && throw(ArgumentError("invalid json object for Figgy.JsonObject config source: expected opening object curly bracket"))
    pos, root = readvalue(buf, pos, len, b)
    if !isempty(path)
        for key in split(path, '.')
            root = root[key]::Dict{String, Any}
        end
    end
    return JsonObject(root)
end

"""
    Figgy.XmlObject(xml, path="")

A FigSource for parsing simple xml as key-value pairs. The `xml` argument
can be a path to an xml file, a `String` which is itself xml data, or a
`Vector{UInt8}` of xml data.
Xml declarations (`<?xml ...?>`), comments (`<!-- ... -->`), and doctypes
are skipped; self-closing tags like `<key/>` are parsed as `key => ""`.
Element text values have surrounding whitespace trimmed.
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
    buf = xml isa AbstractString ? source(_filecontents(xml)) : source(xml)
    pos = 1
    len = length(buf)
    pos = _skip_xml_misc(buf, pos, len)
    b = getbyte(buf, pos)
    b == UInt8('<') || throw(ArgumentError("invalid xml; missing opening tag '<'"))
    pos, (rootkey, root) = readxml(buf, pos, len, b)
    if !isempty(path)
        for key in split(path, '.')
            root = root[key]::Dict{String, Any}
        end
    end
    return XmlObject(root)
end

_xml_whitespace(b) = b == UInt8(' ') || b == UInt8('\t') || b == UInt8('\n') || b == UInt8('\r')

# skip whitespace, xml declarations/processing instructions (`<?...?>`),
# comments (`<!--...-->`), and doctypes (`<!...>`);
# returns the position of the next content byte
function _skip_xml_misc(buf, pos, len)
    while true
        while true
            pos > len && throw(EOFError())
            _xml_whitespace(getbyte(buf, pos)) || break
            pos += 1
        end
        b = getbyte(buf, pos)
        if b == UInt8('<') && pos < len && getbyte(buf, pos + 1) == UInt8('?')
            # declaration/processing instruction; skip past `?>`
            pos += 2
            while true
                pos >= len && throw(EOFError())
                if getbyte(buf, pos) == UInt8('?') && getbyte(buf, pos + 1) == UInt8('>')
                    pos += 2
                    break
                end
                pos += 1
            end
        elseif b == UInt8('<') && pos + 3 <= len && getbyte(buf, pos + 1) == UInt8('!') && getbyte(buf, pos + 2) == UInt8('-') && getbyte(buf, pos + 3) == UInt8('-')
            # comment; skip past `-->`
            pos += 4
            while true
                pos + 2 > len && throw(EOFError())
                if getbyte(buf, pos) == UInt8('-') && getbyte(buf, pos + 1) == UInt8('-') && getbyte(buf, pos + 2) == UInt8('>')
                    pos += 3
                    break
                end
                pos += 1
            end
        elseif b == UInt8('<') && pos < len && getbyte(buf, pos + 1) == UInt8('!')
            # doctype or other declaration; skip past `>`
            pos += 2
            while true
                pos > len && throw(EOFError())
                if getbyte(buf, pos) == UInt8('>')
                    pos += 1
                    break
                end
                pos += 1
            end
        else
            return pos
        end
    end
end

# match the element name at `keystartpos` (of length `keylen`) followed by `>`,
# starting at `pos`; used for validating closing tags
function _match_closing_tag(buf, pos, len, keystartpos, keylen, key)
    for i = 0:(keylen - 1)
        (pos <= len && getbyte(buf, pos) == getbyte(buf, keystartpos + i)) || throw(ArgumentError("malformed xml; expected closing tag for key: `$key`"))
        pos += 1
    end
    (pos <= len && getbyte(buf, pos) == UInt8('>')) || throw(ArgumentError("malformed xml; expected closing tag for key: `$key`"))
    return pos + 1
end

function readxml(buf, pos, len, b)
    pos += 1
    # parse key until space or closing tag
    keystartpos = pos
    foundspace = false
    selfclosing = false
    keylen = 0
    while true
        pos > len && throw(EOFError())
        b = getbyte(buf, pos)
        #TODO: handle escaped closing tags?
        if b == UInt8('>')
            break
        elseif b == UInt8('/') && pos < len && getbyte(buf, pos + 1) == UInt8('>')
            selfclosing = true
            foundspace = true
        else
            foundspace = foundspace || b == UInt8(' ')
            keylen += !foundspace
        end
        pos += 1
    end
    key = unsafe_string(pointer(buf, keystartpos), keylen)
    pos += 1
    # self-closing tag like `<key/>` has an empty string value
    selfclosing && return pos, key => ""
    pos = _skip_xml_misc(buf, pos, len)
    b = getbyte(buf, pos)
    if b == UInt8('<') && pos < len && getbyte(buf, pos + 1) != UInt8('/')
        # nested object
        val = Dict{String, Any}()
        while true
            pos, kv = readxml(buf, pos, len, b)
            val[kv.first] = kv.second
            pos = _skip_xml_misc(buf, pos, len)
            b = getbyte(buf, pos)
            if b == UInt8('<') && pos < len && getbyte(buf, pos + 1) == UInt8('/')
                pos = _match_closing_tag(buf, pos + 2, len, keystartpos, keylen, key)
                break
            end
        end
        return pos, key => val
    else
        # string value; leading whitespace was skipped above and
        # trailing whitespace before the closing tag is trimmed
        strstartpos = pos
        strlen = 0
        vallen = 0
        while true
            pos > len && throw(EOFError())
            b = getbyte(buf, pos)
            if b == UInt8('<')
                pos += 1
                (pos <= len && getbyte(buf, pos) == UInt8('/')) || throw(ArgumentError("malformed xml; expected closing tag for key: `$key`"))
                pos = _match_closing_tag(buf, pos + 1, len, keystartpos, keylen, key)
                break
            end
            strlen += 1
            _xml_whitespace(b) || (vallen = strlen)
            pos += 1
        end
        str = unsafe_string(pointer(buf, strstartpos), vallen)
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
    if !isempty(path)
        for key in split(path, '.')
            figs = figs[key]::Dict{String, Any}
        end
    end
    return TomlObject(figs)
end
