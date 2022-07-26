module Figgy

using TOML

"""
    Figgy.FigSource

Abstract type for all concrete config subtypes. The interface for `FigSource` includes:
    * `T <: Figgy.FigSource`: must subtype `Figgy.FigSource`
    * `Figgy.load(::T) -> key-value iterator`: return a key-value iterator for config source `T`
      Each "key-value" is an object `x` that can be indexed like: `x[1] -> key` and `x[2] -> value`
      Examples include `Pair`, `Tuple{K, V}`, `Vector` of length 2, etc. Keys should be `String` type,
      or will be converted to such via `Figgy.load!`. Values can be any type, though caution is advised
      as many config sources only support loading `String => String` key-value pairs.
      `Figgy.load` is called for each source when users call `Figgy.load!(::Figgy.Store, sources...)`
      to retrieve the key-value config items to load in the store.
"""
abstract type FigSource end

"""
    Figgy.load(::Figgy.FigSource) -> key-value iterator

Required function of the `Figgy.FigSource` interface. See the docs for [`Figgy.FigSource`](@ref) for details.
"""
function load end

# NamedSource & ObjectSource are the only FigSource that *don't* implement `Figgy.load`,
# since they're special-cased in `Figgy.load!` for non-`FigSource` objects. We specifically *don't* want to keep a reference
# to the original source object, so NamedSource/ObjectSource just capture the provided name/type of the source
# and that's used as the `FigSource`.
"""
    Figgy.NamedSource(name)

A generic config source that has a name. Used when generic objects (Dict, Vector of Pairs) are passed
to `Figgy.load!`, but a name can be provided for the specific set of configs.
"""
struct NamedSource <: FigSource
    name::String
end

"""
    Figgy.ObjectSource

A generic, unnamed config source where key-value pairs are provided directly from an object, with
no additional information to identify the config source.
"""
struct ObjectSource <: FigSource
    type::Type
end

"""
    Figgy.Fig(key, values, sources)

Represents a unique config item `key` and its history of values from various sources.
Used by `Figgy.Store` to track config items.
"""
struct Fig
    key::String
    # values & sources are *always* the same length
    # when a new value is loaded for `key`, the new value + source are pushed on to the
    # array fields, so the most recent/current config value is always values[end]
    values::Vector{Any}
    sources::Vector{FigSource}
end

function update!(x::Fig, value, source)
    push!(x.values, value)
    push!(x.sources, source)
    return x
end

"Get the current value for a `Fig`"
function Base.getindex(x::Fig)
    @assert !isempty(x.values)
    return x.values[end]
end

"""
    Figgy.Store()

A threadsafe config store. Tracks config item history as they are updated over time.
Configs are loaded by calling `Figgy.load!(::Figgy.Store, sources...)`, where `sources`
is a list of `Figgy.FigSource` objects, including `Figgy.ProgramArguments`, `Figgy.EnvironmentVariables`,
`Figgy.IniFile`, `Figgy.JsonObject`, `Figgy.XmlObject`, etc. Loading directly from `Dict`, `NamedTuple`,
or `Pair{String, String}` is also allowed. See [`Figgy.load!`](@ref) for more details.
"""
struct Store
    lock::ReentrantLock # protects store field
    store::Dict{String, Fig}
end

Store() = Store(ReentrantLock(), Dict{String, Fig}())

function Base.show(io::IO, store::Store)
    Base.@lock store.lock begin
        print(io, "Figgy.Store:")
        if isempty(store.store)
            print(io, "\nNo entries")
        end
        for (k, fig) in store.store
            print(io, "\n  $k:")
            print(io, " `$(fig.values[end])` from `$(fig.sources[end])`, $(length(fig.values) == 1 ? "1 entry" : "$(length(fig.values)) entries")")
        end
    end
end

"Completely clear all config items and their history from a `Figgy.Store`"
function Base.empty!(store::Store)
    Base.@lock store.lock begin
        empty!(store.store)
    end
    return store
end

"Completely delete a single config item, including its history, as identified by `key`"
function Base.delete!(store::Store, key::String)
    Base.@lock store.lock begin
        delete!(store.store, key)
    end
    return store
end

"Check whether a `Figgy.Store` contains a config item identified by `key`"
function Base.haskey(store::Store, key::String)
    Base.@lock store.lock begin
        return haskey(store.store, key)
    end
end

"Get the current value for a config item identified by `key`, throws `KeyError` if not found"
function Base.getindex(store::Store, key::String)
    Base.@lock store.lock begin
        st = store.store
        !haskey(st, key) && throw(KeyError(key))
        fig = st[key]
        @assert !isempty(fig.values)
        return fig.values[end]
    end
end

"Get the current value for a config item identified by `key`, returns `default` if not found"
function Base.get(store::Store, key::String, default=nothing)
    Base.@lock store.lock begin
        st = store.store
        !haskey(st, key) && return default
        fig = st[key]
        @assert !isempty(fig.values)
        return fig.values[end]
    end
end

"Get the full `Figgy.Fig` object for a config item identified by `key`, throws `KeyError` if not found; includes history of values/sources"
function getfig(store::Store, key::String)
    Base.@lock store.lock begin
        st = store.store
        !haskey(st, key) && throw(KeyError(key))
        return st[key]
    end
end

_pairs(x) = x
_pairs(x::Pair) = (x,)
_pairs(x::NamedTuple) = pairs(x)

"""
    Figgy.load!(store::Store, sources...; name::String="", log::Bool=true)

Load config items from `sources` into `store`. With in a single call to `load!`, it is assumed that `sources`
are ordered by priority, with the highest priority source first. That means that if a config item is found, it
will be ignored from any subsequent sources. The `sources` arguments can be any official `Figgy.FigSource` object,
like `Figgy.ProgramArguments`, `Figgy.EnvironmentVariables`, `Figgy.IniFile`, `Figgy.JsonObject`, `Figgy.XmlObject`, etc. or a generic key-value-producer object, like `Dict`, `NamedTuple`, or `Pair`. For these generic
objects, a name can be provided to identify the config source via the `name` keyword argument.

Note: each call to `Figgy.load!` will gather all unique config items from `sources` and load them all, meaning config items already present in the store will be "updated" (though their history preserved).

By default, each config item loaded into the store is logged via an `@info` log message; to disable this logging,
pass `log=false`.

Keys for sources are expected to be `String` and will be converted to such if not already. Key uniqueness is then
determined by exact string comparison (`==`).

See [`Figgy.kmap`](@ref) and [`Figgy.select`](@ref) for helper functions to transform key names or filter out keys prior to loading.
"""
function load!(store::Store, sources...; name::String="", log::Bool=true)
    # first we load configs from all sources
    # *not* replacing figs we've already seen
    figs = Dict{String, Tuple{Any, FigSource}}()
    for source in sources
        if source isa FigSource
            for (k, v) in load(source)
                if !haskey(figs, k)
                    log && @info "loading config property `$k` from `$(typeof(source))`"
                    figs[string(k)] = (v, source)
                end
            end
        else
            # NamedSource/ObjectSource
            src = isempty(name) ? ObjectSource(typeof(source)) : NamedSource(name)
            # Note: we don't call load here because if you're providing some generic object
            # it needs to iterate key-value configs directly
            for (k, v) in _pairs(source)
                if !haskey(figs, k)
                    log && @info "loading config property `$k` from `$(typeof(src))`"
                    figs[string(k)] = (v, src)
                end
            end
        end
    end
    # now we update store w/ new figs
    # *replacing* current values of figs we've already seen
    Base.@lock store.lock begin
        for (k, (v, src)) in figs
            fig = get!(() -> Fig(k, Any[], FigSource[]), store.store, k)
            update!(fig, v, src)
        end
    end
    return store
end

# FigSources
# helper transforms
struct KeyMap{T} <: FigSource
    source::T # any key-value iterator/result of Figgy.load
    mapping::Any # Function or Dict{String} w/ vals of String or Function
    select::Bool
end

"""
    Figgy.kmap(source, mappings; select::Bool=false)

Allows lazily transforming keys of a `Figgy.FigSource` object. Source is any official `Figgy.FigSource` object,
or a generic key-value-producer object, like `Dict`, `NamedTuple`, or `Pair`. Mappings can be a one of the following:
  * a `Function` that takes a key and returns a new key; applies to all keys in `source`
    * a `Dict` with keys of `String` and values of:
      * a `String` that is the new key
      * a `Function` that takes a key and returns a new key; only applies to the matched key in `source`

Common use-cases for `Figgy.kmap` include normalizing environment variable names like `AWS_PROFILE` and 
program arguments like `--profile` to a common config name like `aws_profile`.

The `select` keyword argument indicates that only provided key mappings should be "selected" from the
config source, thus combining the functionaltiy of [`Figgy.select`](@ref).
"""

kmap(source, mappings::Pair{String}...; select::Bool=false) = KeyMap(source, Dict(mappings), select)
kmap(source, mappings::Union{Function, Dict{String}}; select::Bool=false) = KeyMap(source, mappings, select)
load(x::KeyMap) = x

Base.IteratorSize(::Type{KeyMap{T}}) where {T} = Base.IteratorSize(T)
Base.length(x::KeyMap) = length(x.source)

function Base.iterate(x::KeyMap, st...)
    state = iterate(x.source, st...)
    state === nothing && return nothing
    kv, stt = state
    key = kv[1]
    if x.select && !haskey(x.mapping, key)
        return iterate(x, stt)
    end
    key2 = x.mapping isa Function ? x.mapping(key) : get(x.mapping, key, key)
    kv2 = (key2 isa Function ? key2(key) : key === key2 ? key : key2) => kv[2]
    return kv2, stt
end

struct Select{T} <: FigSource
    source::T # any key-value iterator/result of Figgy.load
    set::Any # Function or Set{String}
end

"""
    Figgy.select(source, keys)

Allows filtering keys of a `Figgy.FigSource` object. Source is any official `Figgy.FigSource` object,
or a generic key-value-producer object, like `Dict`, `NamedTuple`, or `Pair`. `keys` can be a one of the following:
  * a `Function` that takes a key and returns a `Bool`; applies to all keys in `source`
  * a `Set` of `String` keys that are the only keys to be included in the result
"""
function select end

select(source, keys::String...) = Select(source, Set(keys))
select(source, filt) = Select(source, filt)
load(x::Select) = x

Base.IteratorSize(::Type{Select{T}}) where {T} = Base.IteratorSize(T)
Base.length(x::Select) = length(x.source)

function Base.iterate(x::Select, st...)
    state = iterate(x.source, st...)
    state === nothing && return nothing
    kv, stt = state
    if x.set isa Set && !(kv[1] in x.set)
        return iterate(x, stt)
    elseif x.set isa Function && !(x.set(kv[1]))
        return iterate(x, stt)
    end
    return kv, stt
end

include("sources.jl")

end # module Figgy
