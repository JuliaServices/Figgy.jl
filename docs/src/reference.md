# API Reference

## Basics

```@docs
Figgy.FigSource
Figgy.load
Figgy.NamedSource
Figgy.ObjectSource
Figgy.Fig
Figgy.Store
Figgy.load!
Figgy.kmap
Figgy.select
```

## Builtin Configuration Sources

```@docs
Figgy.ProgramArguments
Figgy.EnvironmentVariables
Figgy.IniFile
Figgy.JsonObject
Figgy.XmlObject
Figgy.TomlObject
```

## Encrypted Config Values

```@docs
Figgy.encrypt
Figgy.decrypt
Figgy.Crypt
Figgy.Crypt.CipherConfig
Figgy.Crypt.Envelope
Figgy.Crypt.DEFAULT_CONFIG
Figgy.Crypt.jasypt_config
Figgy.Crypt.encrypt
Figgy.Crypt.encrypt_bytes
Figgy.Crypt.decrypt
Figgy.Crypt.decrypt_bytes
Figgy.Crypt.derive_key
Figgy.Crypt.parse_envelope
Figgy.Crypt.is_encrypted
```
