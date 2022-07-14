module Figgy

export @arg_str, @flag_str

# must iterate key-value config pairs
abstract type FigSource end

struct ManualSource <: FigSource end

struct Fig
    key::String
    value::Any
    source::FigSource
end

# chronological state of a fig key, last element in FigHistory is most recent
const FigHistory = Vector{Fig}

# threadsafe config store
struct Store
    lock::ReentrantLock # protects store field
    store::Dict{String, FigHistory}
end

Store() = Store(ReentrantLock(), Dict{String, FigHistory}())

function Base.show(io::IO, store::Store)
    @lock store.lock begin
        println(io, "Figgy.Store:")
        if isempty(store.store)
            print(io, "No entries")
        end
        for (k, hist) in store.store
            print(io, "  $k:")
            fig = hist[end]
            println(io, " `$(fig.value)` from `$(fig.source)`, $(length(hist) == 1 ? "1 entry" : "$(length(hist)) entries")")
        end
    end
end

function Base.empty!(store::Store)
    @lock store.lock begin
        empty!(store.store)
    end
    return store
end

function Base.getindex(store::Store, key::String)
    @lock store.lock begin
        st = store.store
        !haskey(st, key) && throw(KeyError(key))
        hist = st[key]
        @assert !isempty(hist)
        return hist[end].value
    end
end

function Base.get(store::Store, key::String, default=nothing)
    @lock store.lock begin
        st = store.store
        !haskey(st, key) && return default
        hist = st[key]
        @assert !isempty(hist)
        return hist[end].value
    end
end

function getfig(store::Store, key::String)
    @lock store.lock begin
        st = store.store
        !haskey(st, key) && throw(KeyError(key))
        return st[key][end]
    end
end

function gethistory(store::Store, key::String)
    @lock store.lock begin
        st = store.store
        !haskey(st, key) && return Fig[]
        hist = st[key]
        return hist
    end
end

# set a single fig
function Base.setindex!(store::Store, fig::Fig, key::String)
    @lock store.lock begin
        hist = get!(() -> Fig[], store.store, key)
        push!(hist, fig)
        return fig
    end
end

# load all key-value pairs from sources
function load!(store::Store, sources::FigSource...)
    @lock store.lock begin
        st = store.store
        for source in sources
            for (k, v) in source
                hist = get!(() -> Fig[], st, k)
                push!(hist, Fig(k, v, source))
            end
        end
    end
end


# FigSources
# supports conventions here: https://www.gnu.org/software/libc/manual/html_node/Argument-Syntax.html
# provided program arguments that don't have a key mapping are ignored
@enum ProgramArgumentType LONG ARG FLAG
# LONG: arg = `--key=val`; Fig(pa.longargs[arg.key], arg.val, pa)
# ARG: arg = `-key val` or `-keyval`; Fig(pa.args[arg.key], arg.val, pa)
# FLAG: arg = `-flag`; Fig(pa.flags[flag], true, pa)
macro arg_str(arg)
    if startswith(arg, "--")
        return (LONG, arg)
    elseif startswith(arg, "-")
        return (ARG, arg)
    else
        throw(ArgumentError("`$arg` is not a valid argument; must start with `-` or `--`"))
    end
end

macro flag_str(arg)
    if startswith(arg, "-")
        return (FLAG, arg)
    else
        throw(ArgumentError("`$arg` is not a valid flag; must start with `-`"))
    end
end

struct ProgramArgument
    type::ProgramArgumentType
    arg::String
    key::String
end

struct ProgramArguments <: FigSource
    args::Vector{ProgramArgument}
    ARGS::Vector{String} # store for testing purposes
end

ProgramArguments(args::Pair{Tuple{ProgramArgumentType, String}, String}...; ARGS=ARGS) =
    ProgramArguments([ProgramArgument(arg.first[1], arg.first[2], arg.second) for arg in args], ARGS)

Base.IteratorSize(::Type{ProgramArguments}) = Base.SizeUnknown()

function Base.iterate(pas::ProgramArguments, i=1)
    i > length(pas.ARGS) && return nothing
    while i <= length(pas.ARGS)
        arg = pas.ARGS[i]
        for pa in pas.args
            if pa.type == LONG && contains(arg, "=")
                k, v = split(arg, '=')
                if k == pa.arg
                    return (pa.key, v), i + 1
                end
            elseif pa.type == FLAG && arg == pa.arg
                return (pa.key, "true"), i + 1
            elseif pa.type == ARG && startswith(arg, pa.arg)
                if arg == pa.arg
                    # look for val in next arg
                    i += 1
                    if i > length(pas.ARGS)
                        throw(ArgumentError("missing value for arg $arg"))
                    end
                    v = pas.ARGS[i]
                else
                    # split current arg for val
                    _, v = split(arg, pa.arg)
                end
                return (pa.key, v), i + 1
            else
                # ignore unspecified program arguments
            end
        end
        i += 1
    end
    return nothing
end

# Environment variables
struct EnvironmentVariables <: FigSource
    keymappings::Dict{String, String} # map env name to fig store key
    env::Vector{Pair{String, String}} # store for testing purposes
end

EnvironmentVariables(keys::Pair{String, String}...; env=ENV) =
    EnvironmentVariables(Dict(keys), [Pair(k, v) for (k, v) in env])

Base.IteratorSize(::Type{EnvironmentVariables}) = Base.SizeUnknown()

function Base.iterate(envs::EnvironmentVariables, i=1)
    i > length(envs.env) && return nothing
    while i <= length(envs.env)
        kv = envs.env[i]
        if haskey(envs.keymappings, kv.first)
            return (envs.keymappings[kv.first], kv.second), i + 1
        end
        i += 1
    end
    return nothing
end

# INI files
struct IniFile <: FigSource
    file::String
    section::String
end

Base.IteratorSize(::Type{IniFile}) = Base.SizeUnknown()

Base.iterate(ini::IniFile) = iterate(inifile(isfile(file) ? open(file) : IOBuffer(), ini.section))

# convenience interface for parsing a specific section of an INI file
# returning key-values of that section
function inifile(io::IO, section)
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

end # module Figgy
