# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

HTTP.jl is a from-scratch HTTP client and server implementation for Julia. It uses the [Kip](https://github.com/jkroso/Kip.jl) module system (`@use` directives) instead of standard Julia `Pkg` imports.

## Module System

All imports use `@use` syntax, not `using`/`import`:
```julia
@use "github.com/jkroso/URI.jl" URI
@use Sockets: connect, TCPSocket
@use "./local_file.jl" ExportedName
```

## Running Tests

Client tests require httpbin running locally:
```bash
docker run -p 8000:80 kennethreitz/httpbin
```

Then run tests:
```bash
julia -e 'using Kip; @use "github.com/jkroso/HTTP.jl/client/test"'
```

The test framework is `Test` from Base (using `@testset`, `@test`, `@test_throws`).

## Architecture

The codebase has two independent halves — **client** and **server** — sharing only `Header.jl` and `status.jl` at the root.

### Shared (`/`)
- `Header.jl` — Case-insensitive HTTP header dict wrapping `ImmutableDict`. Used by client; server uses plain `Dict{String,String}`.
- `status.jl` — `Dict{UInt16,String}` mapping status codes to reason phrases.

### Client (`client/`)
- `main.jl` — Core client. Defines `Request{verb}` (IO-writable) and `Response` (IO-readable). Provides `GET`/`POST`/`PUT`/`DELETE` convenience functions. Handles redirects, keep-alive, chunked transfer encoding, gzip decompression, and HTTPS via MbedTLS.
- `Session.jl` — Stateful session with cookie jar, persistent connections, and ORM-style API (`session["/path"]`). Imports heavily from `main.jl`.
- `unchunk.jl` — `Unchunker` struct implementing `AbstractReadBuffer` for reading chunked transfer encoding. Stores trailers in a `Future{Header}`.
- `Logger.jl` — Debug IO wrapper that logs all reads/writes to separate streams.
- `test.jl` — Integration tests against httpbin.

### Server (`server/`)
- `main.jl` — `HTTPServer`, server-side `Request{method}` (parametric on HTTP verb), and `Response{T}`. The `serve(fn, port)` function accepts a callback and handles keep-alive, async connections, and error responses.
- `logger.jl` — Middleware-style logger with colored output via Crayons. Wraps handler to log method, URI, status, timing, and bytes.
- `examples/` — Sample server usage.

### Key Patterns
- Both client and server `Request`/`Response` types are parametric — `Request{:GET}`, `Response{T}` — enabling dispatch on HTTP method and body type.
- Client `Request` and `Response` both subtype `IO`, allowing streaming reads/writes.
- Client uses `write_body` for content-length bodies and chunked encoding via `Base.write` overloads on `Request`.
- Server `Response` rendering (`Base.write(io, ::Response)`) auto-selects chunked vs content-length encoding based on body type.

## Dependencies

Key external Kip packages: URI.jl, Buffer.jl, Prospects.jl (assoc/mutable helpers), Promises.jl (Future), JSON.jl, DOM.jl.
Standard libraries: MbedTLS (TLS/SSL), CodecZlib (gzip), Sockets, Dates.
Server additionally uses Crayons for terminal colors.
