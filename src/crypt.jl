"""
    Figgy.Crypt

OpenSSL-backed helpers for password-based config-value encryption.

New Figgy-managed values should use the default AES-256-GCM profile, which
produces self-describing `ENC[figgy-v1](...)` envelopes. Interoperability
profiles are available through configuration objects rather than separate
encrypt/decrypt aliases.
"""
module Crypt

using Base64
using OpenSSL_jll
using Random

export decrypt, encrypt

"""
    Figgy.Crypt.CipherConfig(; kwargs...)

Password-based encryption configuration used by [`Figgy.Crypt.encrypt`](@ref)
and [`Figgy.Crypt.decrypt`](@ref).

The default config uses PBKDF2-HMAC-SHA256 and AES-256-GCM with a self-describing
`ENC[figgy-v1](...)` envelope. CBC configs are supported for interoperability
with existing ecosystems, but new Figgy-managed values should prefer the default
authenticated encryption profile.
"""
struct CipherConfig
    algorithm::Symbol
    digest::Symbol
    iterations::Int
    salt_bytes::Int
    iv_bytes::Int
    tag_bytes::Int
    key_bytes::Int
    normalize_password::Bool
    envelope::Symbol
end

"""
    Figgy.Crypt.Envelope

Parsed encrypted-value wrapper returned by [`Figgy.Crypt.parse_envelope`](@ref).
`format` is `:figgy_v1`, `:enc`, or `:bare`; `key_id` is populated only for
Figgy's versioned envelope when one was provided at encryption time.
"""
struct Envelope
    format::Symbol
    key_id::Union{Nothing,String}
    payload::Vector{UInt8}
end

struct CryptoError <: Exception
    message::String
end

struct InvalidCiphertextError <: Exception
    message::String
end

Base.showerror(io::IO, err::CryptoError) = print(io, err.message)
Base.showerror(io::IO, err::InvalidCiphertextError) = print(io, err.message)

const LIBCRYPTO = OpenSSL_jll.libcrypto
const FIGGY_MAGIC = UInt8[0x46, 0x49, 0x47, 0x43, 0x52, 0x59, 0x50, 0x54, 0x01]
const EVP_MAX_BLOCK_LENGTH = 32
const EVP_CTRL_GCM_SET_IVLEN = Cint(0x9)
const EVP_CTRL_GCM_GET_TAG = Cint(0x10)
const EVP_CTRL_GCM_SET_TAG = Cint(0x11)

function CipherConfig(;
    algorithm::Symbol=:aes_256_gcm,
    digest::Symbol=:sha256,
    iterations::Integer=210_000,
    salt_bytes::Integer=16,
    iv_bytes::Union{Nothing,Integer}=nothing,
    tag_bytes::Union{Nothing,Integer}=nothing,
    key_bytes::Union{Nothing,Integer}=nothing,
    normalize_password::Bool=true,
    envelope::Symbol=:figgy_v1,
)
    algorithm = _normalize_algorithm(algorithm)
    digest = _normalize_digest(digest)
    iterations = Int(iterations)
    iterations >= 1 || throw(ArgumentError("iterations must be >= 1"))
    salt_bytes = Int(salt_bytes)
    salt_bytes >= 1 || throw(ArgumentError("salt_bytes must be >= 1"))
    key_bytes = something(key_bytes, _default_key_bytes(algorithm)) |> Int
    key_bytes == _default_key_bytes(algorithm) || throw(ArgumentError("key_bytes=$key_bytes does not match $algorithm"))
    iv_bytes = something(iv_bytes, _default_iv_bytes(algorithm)) |> Int
    iv_bytes >= 1 || throw(ArgumentError("iv_bytes must be >= 1"))
    tag_bytes = something(tag_bytes, _default_tag_bytes(algorithm)) |> Int
    if _is_gcm(algorithm)
        1 <= tag_bytes <= 16 || throw(ArgumentError("AES-GCM tag_bytes must be between 1 and 16"))
    else
        tag_bytes == 0 || throw(ArgumentError("AES-CBC does not use an authentication tag"))
        iv_bytes == 16 || throw(ArgumentError("AES-CBC requires a 16-byte IV"))
    end
    envelope in (:figgy_v1, :jasypt, :bare) || throw(ArgumentError("unsupported envelope: $envelope"))
    return CipherConfig(algorithm, digest, iterations, salt_bytes, iv_bytes, tag_bytes, key_bytes, normalize_password, envelope)
end

"""
    Figgy.Crypt.jasypt_config(; iterations=50_000)

Return a `CipherConfig` compatible with Jasypt's
`PBEWITHHMACSHA512ANDAES_256` convention: PBKDF2-HMAC-SHA512, a 16-byte salt,
a 16-byte random IV, AES-256-CBC with PKCS padding, and a
`base64(salt || iv || ciphertext)` payload.

This profile exists for interoperability. Prefer the default AES-GCM config for
new Figgy-managed secrets.
"""
function jasypt_config(; iterations::Integer=50_000)
    return CipherConfig(;
        algorithm=:aes_256_cbc,
        digest=:sha512,
        iterations=iterations,
        salt_bytes=16,
        iv_bytes=16,
        tag_bytes=0,
        key_bytes=32,
        normalize_password=true,
        envelope=:jasypt,
    )
end

"""
    Figgy.Crypt.encrypt(secret, plaintext; config=Figgy.Crypt.DEFAULT_CONFIG, key_id=nothing, aad=UInt8[], rng=Random.default_rng(), salt=nothing, iv=nothing, wrap=nothing)

Encrypt a string or byte vector with a password/secret string or byte vector.

The default returns a self-describing `ENC[figgy-v1](...)` value. Passing
`key_id` stores an explicit key identifier in the envelope so decryptors can
route to the correct key without trying keys by exception.
"""
function encrypt(secret, plaintext; config::CipherConfig=DEFAULT_CONFIG, key_id::Union{Nothing,AbstractString}=nothing, aad=UInt8[], rng::AbstractRNG=Random.default_rng(), salt=nothing, iv=nothing, wrap=nothing)
    return _encrypt(secret, _bytes(plaintext), config, key_id, _bytes(aad), rng, salt, iv, wrap)
end

"""
    Figgy.Crypt.encrypt_bytes(secret, plaintext; kwargs...)

Byte-vector variant of [`Figgy.Crypt.encrypt`](@ref).
"""
function encrypt_bytes(secret, plaintext::AbstractVector{UInt8}; kwargs...)
    return encrypt(secret, plaintext; kwargs...)
end

"""
    Figgy.Crypt.decrypt(secret, encrypted; config=nothing, aad=UInt8[])
    Figgy.Crypt.decrypt(keys::AbstractDict, encrypted; config=nothing, aad=UInt8[])

Decrypt an encrypted string and return UTF-8 text. When a dictionary of keys is
provided, the Figgy envelope must contain a `key_id`; the matching dictionary
entry is selected before decrypting.
"""
function decrypt(secret, encrypted::AbstractString; config::Union{Nothing,CipherConfig}=nothing, aad=UInt8[])
    return String(decrypt_bytes(secret, encrypted; config=config, aad=aad))
end

function decrypt(keys::AbstractDict, encrypted::AbstractString; config::Union{Nothing,CipherConfig}=nothing, aad=UInt8[])
    envelope = parse_envelope(encrypted)
    envelope.key_id === nothing && throw(ArgumentError("encrypted value does not include a key_id"))
    secret = get(() -> throw(KeyError(envelope.key_id)), keys, envelope.key_id)
    return decrypt(secret, encrypted; config=config, aad=aad)
end

"""
    Figgy.Crypt.decrypt_bytes(secret, encrypted; config=nothing, aad=UInt8[])

Decrypt an encrypted string and return raw bytes.
"""
function decrypt_bytes(secret, encrypted::AbstractString; config::Union{Nothing,CipherConfig}=nothing, aad=UInt8[])
    envelope = parse_envelope(encrypted)
    aad = _bytes(aad)
    if config === nothing
        envelope.format == :figgy_v1 || throw(ArgumentError("config is required for non-Figgy encrypted values"))
        config, salt, iv, ciphertext, tag = _parse_figgy_payload(envelope.payload)
    elseif config.envelope == :figgy_v1
        config, salt, iv, ciphertext, tag = _parse_figgy_payload(envelope.payload)
    elseif config.envelope == :jasypt
        salt, iv, ciphertext = _parse_salt_iv_ciphertext(envelope.payload, config)
        tag = UInt8[]
    else
        salt, iv, ciphertext = _parse_salt_iv_ciphertext(envelope.payload, config)
        tag = UInt8[]
    end
    key = derive_key(secret, salt; config=config)
    return _evp_decrypt(config, key, iv, ciphertext, tag, aad)
end

"""
    Figgy.Crypt.derive_key(secret, salt; config=Figgy.Crypt.DEFAULT_CONFIG)

Derive an encryption key using OpenSSL's `PKCS5_PBKDF2_HMAC`.
"""
function derive_key(secret, salt::AbstractVector{UInt8}; config::CipherConfig=DEFAULT_CONFIG)
    password = _secret_bytes(secret, config)
    salt = Vector{UInt8}(salt)
    key = Vector{UInt8}(undef, config.key_bytes)
    digest = _digest(config.digest)
    rc = ccall(
        (:PKCS5_PBKDF2_HMAC, LIBCRYPTO),
        Cint,
        (Ptr{UInt8}, Cint, Ptr{UInt8}, Cint, Cint, Ptr{Cvoid}, Cint, Ptr{UInt8}),
        password,
        length(password),
        salt,
        length(salt),
        config.iterations,
        digest,
        length(key),
        key,
    )
    rc == 1 || throw(CryptoError("PBKDF2 failed: $(_openssl_error())"))
    return key
end

"""
    Figgy.Crypt.parse_envelope(encrypted) -> Figgy.Crypt.Envelope

Parse `ENC[figgy-v1](...)`, `ENC[figgy-v1:key-id](...)`, `ENC(...)`, or bare
Base64 encrypted values. Bare values are returned with `format == :bare`.
"""
function parse_envelope(encrypted::AbstractString)
    s = strip(String(encrypted))
    if startswith(s, "ENC[")
        close = findfirst(==(']'), s)
        close === nothing && throw(ArgumentError("invalid ENC[...] envelope"))
        paren = nextind(s, close)
        paren <= lastindex(s) && s[paren] == '(' || throw(ArgumentError("invalid ENC[...] envelope"))
        endswith(s, ")") || throw(ArgumentError("invalid ENC[...] envelope"))
        metadata = s[nextind(s, firstindex(s), 4):prevind(s, close)]
        payload = s[nextind(s, paren):prevind(s, lastindex(s))]
        format, key_id = _parse_figgy_metadata(metadata)
        return Envelope(format, key_id, base64decode(payload))
    elseif startswith(s, "ENC(")
        endswith(s, ")") || throw(ArgumentError("invalid ENC(...) envelope"))
        return Envelope(:enc, nothing, base64decode(s[nextind(s, firstindex(s), 4):prevind(s, lastindex(s))]))
    else
        return Envelope(:bare, nothing, base64decode(s))
    end
end

"""
    Figgy.Crypt.is_encrypted(value) -> Bool

Return whether a string looks like an `ENC(...)` or `ENC[...](...)` value.
"""
is_encrypted(value::AbstractString) = startswith(strip(String(value)), "ENC(") || startswith(strip(String(value)), "ENC[")

function _encrypt(secret, plaintext::Vector{UInt8}, config::CipherConfig, key_id, aad::Vector{UInt8}, rng, salt, iv, wrap)
    key_id !== nothing && config.envelope != :figgy_v1 && throw(ArgumentError("key_id is only supported by the Figgy v1 envelope"))
    salt = _materialize_bytes(salt, config.salt_bytes, "salt", rng)
    iv = _materialize_bytes(iv, config.iv_bytes, "iv", rng)
    key = derive_key(secret, salt; config=config)
    ciphertext, tag = _evp_encrypt(config, key, iv, plaintext, aad)
    return _format_encrypted(config, salt, iv, ciphertext, tag, key_id, wrap)
end

function _format_encrypted(config::CipherConfig, salt, iv, ciphertext, tag, key_id, wrap)
    if config.envelope == :figgy_v1
        payload = _encode_figgy_payload(config, salt, iv, ciphertext, tag)
        return _wrap_figgy(payload, key_id, something(wrap, true))
    elseif config.envelope == :jasypt
        payload = base64encode(vcat(salt, iv, ciphertext))
        return something(wrap, false) ? "ENC($payload)" : payload
    else
        payload = base64encode(vcat(salt, iv, ciphertext))
        return something(wrap, false) ? "ENC($payload)" : payload
    end
end

function _wrap_figgy(payload, key_id, wrap::Bool)
    encoded = base64encode(payload)
    !wrap && return encoded
    if key_id === nothing
        return "ENC[figgy-v1]($encoded)"
    end
    key_id = String(key_id)
    _valid_key_id(key_id) || throw(ArgumentError("key_id may not contain ':', ']', '(', ')', or whitespace"))
    return "ENC[figgy-v1:$key_id]($encoded)"
end

function _parse_figgy_metadata(metadata::AbstractString)
    if metadata == "figgy-v1"
        return :figgy_v1, nothing
    elseif startswith(metadata, "figgy-v1:")
        key_id = metadata[nextind(metadata, firstindex(metadata), 9):end]
        _valid_key_id(key_id) || throw(ArgumentError("invalid key_id in encrypted value"))
        return :figgy_v1, key_id
    else
        throw(ArgumentError("unsupported encrypted value metadata: $metadata"))
    end
end

function _valid_key_id(key_id::AbstractString)
    isempty(key_id) && return false
    return !any(c -> c == ':' || c == ']' || c == '(' || c == ')' || isspace(c), key_id)
end

function _encode_figgy_payload(config::CipherConfig, salt, iv, ciphertext, tag)
    _fits_uint8(salt, "salt")
    _fits_uint8(iv, "iv")
    _fits_uint8(tag, "tag")
    0 <= length(ciphertext) <= typemax(UInt32) || throw(ArgumentError("ciphertext is too large for Figgy v1 envelope"))
    payload = UInt8[]
    append!(payload, FIGGY_MAGIC)
    push!(payload, _algorithm_id(config.algorithm))
    push!(payload, _digest_id(config.digest))
    _append_u32!(payload, config.iterations)
    push!(payload, UInt8(config.key_bytes))
    push!(payload, UInt8(length(salt)))
    push!(payload, UInt8(length(iv)))
    push!(payload, UInt8(length(tag)))
    _append_u32!(payload, length(ciphertext))
    append!(payload, salt)
    append!(payload, iv)
    append!(payload, ciphertext)
    append!(payload, tag)
    return payload
end

function _parse_figgy_payload(payload::Vector{UInt8})
    minlen = length(FIGGY_MAGIC) + 12
    length(payload) >= minlen || throw(InvalidCiphertextError("Figgy encrypted payload is too short"))
    payload[1:length(FIGGY_MAGIC)] == FIGGY_MAGIC || throw(InvalidCiphertextError("invalid Figgy encrypted payload header"))
    pos = length(FIGGY_MAGIC) + 1
    algorithm = _algorithm_from_id(payload[pos])
    digest = _digest_from_id(payload[pos + 1])
    iterations = _read_u32(payload, pos + 2)
    key_bytes = Int(payload[pos + 6])
    salt_bytes = Int(payload[pos + 7])
    iv_bytes = Int(payload[pos + 8])
    tag_bytes = Int(payload[pos + 9])
    ciphertext_bytes = _read_u32(payload, pos + 10)
    data_pos = pos + 14
    expected = data_pos + salt_bytes + iv_bytes + ciphertext_bytes + tag_bytes - 1
    expected == length(payload) || throw(InvalidCiphertextError("Figgy encrypted payload length does not match header"))
    salt = payload[data_pos:data_pos + salt_bytes - 1]
    iv_start = data_pos + salt_bytes
    iv = payload[iv_start:iv_start + iv_bytes - 1]
    ct_start = iv_start + iv_bytes
    ciphertext = payload[ct_start:ct_start + ciphertext_bytes - 1]
    tag = payload[ct_start + ciphertext_bytes:expected]
    config = CipherConfig(; algorithm=algorithm, digest=digest, iterations=iterations, salt_bytes=salt_bytes, iv_bytes=iv_bytes, tag_bytes=tag_bytes, key_bytes=key_bytes, envelope=:figgy_v1)
    return config, salt, iv, ciphertext, tag
end

function _parse_salt_iv_ciphertext(payload::Vector{UInt8}, config::CipherConfig)
    minlen = config.salt_bytes + config.iv_bytes + 1
    length(payload) >= minlen || throw(InvalidCiphertextError("encrypted payload is too short"))
    salt = payload[1:config.salt_bytes]
    iv_start = config.salt_bytes + 1
    iv = payload[iv_start:iv_start + config.iv_bytes - 1]
    ciphertext = payload[iv_start + config.iv_bytes:end]
    return salt, iv, ciphertext
end

function _evp_encrypt(config::CipherConfig, key, iv, plaintext, aad)
    ctx = _ctx_new()
    try
        cipher = _cipher(config.algorithm)
        _check(ccall((:EVP_EncryptInit_ex, LIBCRYPTO), Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt8}), ctx, cipher, C_NULL, C_NULL, C_NULL), "EVP_EncryptInit_ex")
        if _is_gcm(config.algorithm)
            _check(ccall((:EVP_CIPHER_CTX_ctrl, LIBCRYPTO), Cint, (Ptr{Cvoid}, Cint, Cint, Ptr{Cvoid}), ctx, EVP_CTRL_GCM_SET_IVLEN, length(iv), C_NULL), "EVP_CIPHER_CTX_ctrl(GCM_SET_IVLEN)")
        end
        _check(ccall((:EVP_EncryptInit_ex, LIBCRYPTO), Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt8}), ctx, C_NULL, C_NULL, key, iv), "EVP_EncryptInit_ex(key, iv)")
        _cipher_update_aad(ctx, aad, true)
        out = Vector{UInt8}(undef, length(plaintext) + EVP_MAX_BLOCK_LENGTH)
        total = _cipher_update(ctx, out, 1, plaintext, true)
        finallen = _encrypt_final(ctx, out, total + 1)
        total += finallen
        resize!(out, total)
        tag = _is_gcm(config.algorithm) ? _get_gcm_tag(ctx, config.tag_bytes) : UInt8[]
        return out, tag
    finally
        _ctx_free(ctx)
    end
end

function _evp_decrypt(config::CipherConfig, key, iv, ciphertext, tag, aad)
    ctx = _ctx_new()
    try
        cipher = _cipher(config.algorithm)
        _check(ccall((:EVP_DecryptInit_ex, LIBCRYPTO), Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt8}), ctx, cipher, C_NULL, C_NULL, C_NULL), "EVP_DecryptInit_ex")
        if _is_gcm(config.algorithm)
            length(tag) == config.tag_bytes || throw(InvalidCiphertextError("AES-GCM tag length mismatch"))
            _check(ccall((:EVP_CIPHER_CTX_ctrl, LIBCRYPTO), Cint, (Ptr{Cvoid}, Cint, Cint, Ptr{Cvoid}), ctx, EVP_CTRL_GCM_SET_IVLEN, length(iv), C_NULL), "EVP_CIPHER_CTX_ctrl(GCM_SET_IVLEN)")
        end
        _check(ccall((:EVP_DecryptInit_ex, LIBCRYPTO), Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt8}), ctx, C_NULL, C_NULL, key, iv), "EVP_DecryptInit_ex(key, iv)")
        _cipher_update_aad(ctx, aad, false)
        out = Vector{UInt8}(undef, length(ciphertext) + EVP_MAX_BLOCK_LENGTH)
        total = _cipher_update(ctx, out, 1, ciphertext, false)
        _is_gcm(config.algorithm) && _set_gcm_tag(ctx, tag)
        finallen = _decrypt_final(ctx, out, total + 1)
        total += finallen
        resize!(out, total)
        return out
    finally
        _ctx_free(ctx)
    end
end

function _cipher_update(ctx, out, outpos, input, encrypting::Bool)
    isempty(input) && return 0
    outlen = Ref{Cint}(0)
    if encrypting
        rc = GC.@preserve out input ccall((:EVP_EncryptUpdate, LIBCRYPTO), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}, Ptr{UInt8}, Cint), ctx, pointer(out, outpos), outlen, input, length(input))
        _check(rc, "EVP_EncryptUpdate")
    else
        rc = GC.@preserve out input ccall((:EVP_DecryptUpdate, LIBCRYPTO), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}, Ptr{UInt8}, Cint), ctx, pointer(out, outpos), outlen, input, length(input))
        _check(rc, "EVP_DecryptUpdate")
    end
    return Int(outlen[])
end

function _cipher_update_aad(ctx, aad, encrypting::Bool)
    isempty(aad) && return
    outlen = Ref{Cint}(0)
    if encrypting
        rc = ccall((:EVP_EncryptUpdate, LIBCRYPTO), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}, Ptr{UInt8}, Cint), ctx, C_NULL, outlen, aad, length(aad))
        _check(rc, "EVP_EncryptUpdate(aad)")
    else
        rc = ccall((:EVP_DecryptUpdate, LIBCRYPTO), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}, Ptr{UInt8}, Cint), ctx, C_NULL, outlen, aad, length(aad))
        _check(rc, "EVP_DecryptUpdate(aad)")
    end
    return
end

function _encrypt_final(ctx, out, outpos)
    outlen = Ref{Cint}(0)
    rc = GC.@preserve out ccall((:EVP_EncryptFinal_ex, LIBCRYPTO), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}), ctx, pointer(out, outpos), outlen)
    _check(rc, "EVP_EncryptFinal_ex")
    return Int(outlen[])
end

function _decrypt_final(ctx, out, outpos)
    outlen = Ref{Cint}(0)
    rc = GC.@preserve out ccall((:EVP_DecryptFinal_ex, LIBCRYPTO), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}), ctx, pointer(out, outpos), outlen)
    rc == 1 || throw(InvalidCiphertextError("decrypt failed; wrong key, wrong AAD, or corrupt ciphertext"))
    return Int(outlen[])
end

function _get_gcm_tag(ctx, tag_bytes)
    tag = Vector{UInt8}(undef, tag_bytes)
    rc = GC.@preserve tag ccall((:EVP_CIPHER_CTX_ctrl, LIBCRYPTO), Cint, (Ptr{Cvoid}, Cint, Cint, Ptr{Cvoid}), ctx, EVP_CTRL_GCM_GET_TAG, tag_bytes, pointer(tag))
    _check(rc, "EVP_CIPHER_CTX_ctrl(GCM_GET_TAG)")
    return tag
end

function _set_gcm_tag(ctx, tag)
    rc = GC.@preserve tag ccall((:EVP_CIPHER_CTX_ctrl, LIBCRYPTO), Cint, (Ptr{Cvoid}, Cint, Cint, Ptr{Cvoid}), ctx, EVP_CTRL_GCM_SET_TAG, length(tag), pointer(tag))
    _check(rc, "EVP_CIPHER_CTX_ctrl(GCM_SET_TAG)")
    return
end

function _ctx_new()
    ctx = ccall((:EVP_CIPHER_CTX_new, LIBCRYPTO), Ptr{Cvoid}, ())
    ctx == C_NULL && throw(CryptoError("EVP_CIPHER_CTX_new failed: $(_openssl_error())"))
    return ctx
end

_ctx_free(ctx) = ccall((:EVP_CIPHER_CTX_free, LIBCRYPTO), Cvoid, (Ptr{Cvoid},), ctx)

function _check(rc, context)
    rc == 1 && return
    throw(CryptoError("$context failed: $(_openssl_error())"))
end

function _openssl_error()
    code = ccall((:ERR_get_error, LIBCRYPTO), Culong, ())
    code == 0 && return "OpenSSL returned no error detail"
    buf = Vector{UInt8}(undef, 256)
    ccall((:ERR_error_string_n, LIBCRYPTO), Cvoid, (Culong, Ptr{UInt8}, Csize_t), code, buf, length(buf))
    return unsafe_string(pointer(buf))
end

function _cipher(algorithm::Symbol)
    cipher =
        algorithm == :aes_128_gcm ? ccall((:EVP_aes_128_gcm, LIBCRYPTO), Ptr{Cvoid}, ()) :
        algorithm == :aes_192_gcm ? ccall((:EVP_aes_192_gcm, LIBCRYPTO), Ptr{Cvoid}, ()) :
        algorithm == :aes_256_gcm ? ccall((:EVP_aes_256_gcm, LIBCRYPTO), Ptr{Cvoid}, ()) :
        algorithm == :aes_128_cbc ? ccall((:EVP_aes_128_cbc, LIBCRYPTO), Ptr{Cvoid}, ()) :
        algorithm == :aes_192_cbc ? ccall((:EVP_aes_192_cbc, LIBCRYPTO), Ptr{Cvoid}, ()) :
        algorithm == :aes_256_cbc ? ccall((:EVP_aes_256_cbc, LIBCRYPTO), Ptr{Cvoid}, ()) :
        throw(ArgumentError("unsupported algorithm: $algorithm"))
    cipher == C_NULL && throw(CryptoError("OpenSSL cipher lookup failed for $algorithm"))
    return cipher
end

function _digest(digest::Symbol)
    ptr =
        digest == :sha256 ? ccall((:EVP_sha256, LIBCRYPTO), Ptr{Cvoid}, ()) :
        digest == :sha384 ? ccall((:EVP_sha384, LIBCRYPTO), Ptr{Cvoid}, ()) :
        digest == :sha512 ? ccall((:EVP_sha512, LIBCRYPTO), Ptr{Cvoid}, ()) :
        throw(ArgumentError("unsupported digest: $digest"))
    ptr == C_NULL && throw(CryptoError("OpenSSL digest lookup failed for $digest"))
    return ptr
end

_normalize_algorithm(x::Symbol) = x in (:aes_128_gcm, :aes_192_gcm, :aes_256_gcm, :aes_128_cbc, :aes_192_cbc, :aes_256_cbc) ? x : throw(ArgumentError("unsupported algorithm: $x"))
_normalize_digest(x::Symbol) = x in (:sha256, :sha384, :sha512) ? x : throw(ArgumentError("unsupported digest: $x"))
_is_gcm(algorithm::Symbol) = algorithm in (:aes_128_gcm, :aes_192_gcm, :aes_256_gcm)
_default_iv_bytes(algorithm::Symbol) = _is_gcm(algorithm) ? 12 : 16
_default_tag_bytes(algorithm::Symbol) = _is_gcm(algorithm) ? 16 : 0
_default_key_bytes(::Val{:aes_128_gcm}) = 16
_default_key_bytes(::Val{:aes_192_gcm}) = 24
_default_key_bytes(::Val{:aes_256_gcm}) = 32
_default_key_bytes(::Val{:aes_128_cbc}) = 16
_default_key_bytes(::Val{:aes_192_cbc}) = 24
_default_key_bytes(::Val{:aes_256_cbc}) = 32
_default_key_bytes(algorithm::Symbol) = _default_key_bytes(Val(algorithm))

_algorithm_id(algorithm::Symbol) =
    algorithm == :aes_128_gcm ? 0x01 :
    algorithm == :aes_192_gcm ? 0x02 :
    algorithm == :aes_256_gcm ? 0x03 :
    algorithm == :aes_128_cbc ? 0x11 :
    algorithm == :aes_192_cbc ? 0x12 :
    algorithm == :aes_256_cbc ? 0x13 :
    throw(ArgumentError("unsupported algorithm: $algorithm"))

_algorithm_from_id(id::UInt8) =
    id == 0x01 ? :aes_128_gcm :
    id == 0x02 ? :aes_192_gcm :
    id == 0x03 ? :aes_256_gcm :
    id == 0x11 ? :aes_128_cbc :
    id == 0x12 ? :aes_192_cbc :
    id == 0x13 ? :aes_256_cbc :
    throw(InvalidCiphertextError("unsupported encrypted payload algorithm id: $id"))

_digest_id(digest::Symbol) =
    digest == :sha256 ? 0x01 :
    digest == :sha384 ? 0x02 :
    digest == :sha512 ? 0x03 :
    throw(ArgumentError("unsupported digest: $digest"))

_digest_from_id(id::UInt8) =
    id == 0x01 ? :sha256 :
    id == 0x02 ? :sha384 :
    id == 0x03 ? :sha512 :
    throw(InvalidCiphertextError("unsupported encrypted payload digest id: $id"))

function _secret_bytes(secret::AbstractString, config::CipherConfig)
    s = config.normalize_password ? Base.Unicode.normalize(String(secret), :NFC) : String(secret)
    return Vector{UInt8}(codeunits(s))
end

_secret_bytes(secret::AbstractVector{UInt8}, ::CipherConfig) = Vector{UInt8}(secret)
_bytes(value::AbstractString) = Vector{UInt8}(codeunits(String(value)))
_bytes(value::AbstractVector{UInt8}) = Vector{UInt8}(value)

function _materialize_bytes(value, n, name, rng)
    bytes = value === nothing ? rand(rng, UInt8, n) : Vector{UInt8}(value)
    length(bytes) == n || throw(ArgumentError("$name must be $n bytes"))
    return bytes
end

function _append_u32!(buf, value)
    0 <= value <= typemax(UInt32) || throw(ArgumentError("value does not fit UInt32: $value"))
    push!(buf, UInt8((value >> 24) & 0xff))
    push!(buf, UInt8((value >> 16) & 0xff))
    push!(buf, UInt8((value >> 8) & 0xff))
    push!(buf, UInt8(value & 0xff))
    return buf
end

function _read_u32(buf, pos)
    return (Int(buf[pos]) << 24) | (Int(buf[pos + 1]) << 16) | (Int(buf[pos + 2]) << 8) | Int(buf[pos + 3])
end

function _fits_uint8(bytes, name)
    length(bytes) <= typemax(UInt8) || throw(ArgumentError("$name is too large for Figgy v1 envelope"))
    return
end

"""
    Figgy.Crypt.DEFAULT_CONFIG

Default password-based encryption profile: PBKDF2-HMAC-SHA256 with 210,000
iterations, a 16-byte salt, AES-256-GCM, a 12-byte IV, and a 16-byte
authentication tag in Figgy's self-describing v1 envelope.
"""
const DEFAULT_CONFIG = CipherConfig()

end # module
