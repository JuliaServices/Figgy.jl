
# Figgy

[![CI](https://github.com/JuliaServices/Figgy.jl/workflows/CI/badge.svg)](https://github.com/JuliaServices/Figgy.jl/actions?query=workflow%3ACI)
[![codecov](https://codecov.io/gh/JuliaServices/Figgy.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaServices/Figgy.jl)
[![deps](https://juliahub.com/docs/Figgy/deps.svg)](https://juliahub.com/ui/Packages/Figgy/HHBkp?t=2)
[![version](https://juliahub.com/docs/Figgy/version.svg)](https://juliahub.com/ui/Packages/Figgy/HHBkp)
[![pkgeval](https://juliahub.com/docs/Figgy/pkgeval.svg)](https://juliahub.com/ui/Packages/Figgy/HHBkp)

*A threadsafe, sensible, configuration manager for Julia services*

## Installation

The package is registered in the [`General`](https://github.com/JuliaRegistries/General) registry and so can be installed at the REPL with `] add Figgy`.

## Documentation

- [**STABLE**][docs-stable-url] &mdash; **most recently tagged version of the documentation.**
- [**LATEST**][docs-latest-url] &mdash; *in-development version of the documentation.*

## Project Status

The package is tested against Julia `1.6`, current stable release, and nightly on Linux.

## Encrypted Config Values

`Figgy.Crypt` provides OpenSSL-backed helpers for encrypting individual config values. New values use
PBKDF2-HMAC-SHA256 plus AES-256-GCM by default and are wrapped as self-describing `ENC[figgy-v1](...)`
envelopes. A `jasypt_config()` profile is available for Java/Jasypt-compatible AES-256-CBC values while
keeping the public API on the generic `Figgy.Crypt.encrypt` and `Figgy.Crypt.decrypt` functions.

## Contributing and Questions

Contributions are very welcome, as are feature requests and suggestions. Please open an
[issue][issues-url] if you encounter any problems or would just like to ask a question.

[docs-latest-img]: https://img.shields.io/badge/docs-latest-blue.svg
[docs-latest-url]: https://juliaservices.github.io/Figgy.jl/dev

[docs-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[docs-stable-url]: https://juliaservices.github.io/Figgy.jl/stable

[ci-img]: https://github.com/JuliaServices/Figgy.jl/workflows/CI/badge.svg
[ci-url]: https://github.com/JuliaServices/Figgy.jl/actions?query=workflow%3ACI+branch%3Amaster

[codecov-img]: https://codecov.io/gh/JuliaServices/Figgy.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaServices/Figgy.jl

[issues-url]: https://github.com/JuliaServices/Figgy.jl/issues
