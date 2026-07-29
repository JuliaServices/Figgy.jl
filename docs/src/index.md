# Figgy.jl Documentation

GitHub Repo: [https://github.com/JuliaServices/Figgy.jl](https://github.com/JuliaServices/Figgy.jl)

Welcome to Figgy.jl! A threadsafe, sensible, configuration manager for Julia services.

## Installation

You can install Figgy by typing the following in the Julia REPL:
```julia
] add Figgy 
```

followed by 
```julia
using Figgy
```
to load the package.

## Overview 

The Figgy.jl package provides a threadsafe configuration manager that allows respecting a priority
of config sources and updating config values over time while tracking history. It offers support for
a number of simple, builtin configuration source types with zero dependencies. The API is
straightforward:

```julia
using Figgy
store = Figgy.Store()
Figgy.load!(store, sources...)
```

First, there must be a [`Figgy.Store`](@ref) object in which we store and track configuration key-value pairs.
Then, via calls to [`Figgy.load!`](@ref), we store config values, respecting the order in which various config
sources are provided as the order of priority. For example,

```julia
using Figgy
store = Figgy.Store()
Figgy.load!(store, Figgy.ProgramArguments(), Figgy.EnvironmentVariables())
```

In this case, we're loading config key-value pairs from any program arguments and then environment
variables. If we come across a key in the environment variables that was already seen in the
program arguments, it will be ignored, placing priority/precedence on program arguments key since
it was listed first. Alternatively, if we call:

```julia
using Figgy
store = Figgy.Store()
Figgy.load!(store, Figgy.ProgramArguments())
Figgy.load!(store, Figgy.EnvironmentVariables())
```

And again we have a matching key in environment variables, it _will_ replace the value from program
arguments since we're doing a separate load. This gives us the functionality where *within a single load*
we can control which sources we prioritize, while also allowing us to update any config value later on
by doing subsequent loads. This follows the common pattern seen in applications where on initialization,
we want to do a prioritized load from a number of potential config sources, then later during normal runtime
have the ability to tweak specific config values (like production log level) as needed.

In addition to loading, `Figgy.Store` supports the familiar dict-like operations, all threadsafe:

```julia
store["key"]                     # current value for "key"; throws KeyError if absent
get(store, "key", "default")     # current value or default
get(() -> "computed", store, "key") # current value or computed fallback
store["key"] = "value"           # manually set a value (recorded with a "manual" source)
haskey(store, "key")
length(store); isempty(store)
keys(store); values(store)       # snapshots of current keys/values
for (k, v) in store; ...; end    # iterate a snapshot of current key-value pairs
delete!(store, "key")            # remove a config item (including history)
empty!(store)                    # remove all config items
Figgy.getfig(store, "key")       # full Figgy.Fig with value/source history
```

See the API Reference page for the section on builtin configuration sources provided directly by Figgy.jl,
 including program arguments, environment variales, ini files, json, xml, and toml.

See the docs on [`Figgy.FigSource`](@ref) for the simple interface for creating your own custom config source.

## Encrypted config values

`Figgy.Crypt` provides OpenSSL-backed helpers for encrypting individual config values before they are
stored in files, environment variables, or secret stores. The default profile uses PBKDF2-HMAC-SHA256
and AES-256-GCM, returning a self-describing `ENC[figgy-v1](...)` envelope:

```julia
encrypted = Figgy.encrypt("password", "database-password"; key_id="v1")
plain = Figgy.decrypt(Dict("v1" => "password"), encrypted)
```

Use explicit `key_id`s when rotating keys so decryptors can select the intended key instead of trying
multiple keys and hoping failures are deterministic. For Java/Jasypt interoperability, use
[`Figgy.Crypt.jasypt_config`](@ref) with the generic encrypt/decrypt functions:

```julia
config = Figgy.Crypt.jasypt_config()
encrypted = Figgy.encrypt("password", "database-password"; config)
plain = Figgy.decrypt("password", encrypted; config)
```
