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

The test framework is `Test` from Base (using `@testset`, `@test`, `@test_throws`).

### HTTP client tests
`client/test/local.jl` is self-contained: it starts the library's own server and
raw TCP listeners in-process (timeouts, streaming, multipart, close-delimited
bodies, header precedence, `HTTPError`), so it needs no docker or network:
```bash
julia -e 'using Kip; include("client/test/local.jl")'          # from the repo root
julia -e 'using Kip; include("client/test/session_retry.jl")'
```
`include` rather than `@use`: Kip precompiles a `@use`d file, so a failing test
file runs twice.

The older integration suite needs httpbin running locally:
```bash
docker run -p 8000:80 kennethreitz/httpbin
julia -e 'using Kip; @use "github.com/jkroso/HTTP.jl/client/test/http"'
```

### WebSocket client tests
Requires the Autobahn fuzzing server:
```bash
docker run -it --rm \
  -v "$(pwd)/client/test/autobahn:/config" \
  -v "$(pwd)/client/test/autobahn/reports:/reports" \
  -p 9001:9001 \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingserver -s /config/fuzzingserver.json
julia -e 'using Kip; @use "github.com/jkroso/HTTP.jl/client/test/websocket"'
```

## Architecture

The codebase has two independent halves — **client** and **server** — sharing only `Header.jl` and `status.jl` at the root.

### Shared (`/`)
- `Header.jl` — Case-insensitive HTTP header dict wrapping `ImmutableDict`. Used by client; server uses plain `Dict{String,String}`.
- `status.jl` — `Dict{UInt16,String}` mapping status codes to reason phrases.

### Client (`client/`)
- `main.jl` — Core client. Defines `Request{verb}` (IO-writable) and `Response` (IO-readable). Provides `GET`/`POST`/`PUT`/`DELETE` convenience functions (keywords `meta`, `data`, `query`, `connect_timeout`, `readtimeout`, `timeout`, `max_redirects`; a leading function argument streams the body). Handles redirects, keep-alive, chunked and close-delimited bodies, gzip/deflate decompression (other encodings pass through), and HTTPS via Reseau. Throws `HTTPError{status}` (body buffered) on 4xx/5xx; `send(req, …)` returns the Response instead. Also `escapeuri`.
- `timeout.jl` — `Timeouts` (a request's budget), `TimedIO` (wraps a Reseau socket and re-arms its absolute deadlines before reads/writes so `readtimeout` is an idle limit) and `TimeoutError`. Connect timeouts go to Reseau's `timeout_ns`, which covers DNS, TCP and the TLS handshake. Without timeouts sockets aren't wrapped.
- `body.jl` — `Body`, the lazy `AbstractReadBuffer` used for streamed Content-Length and close-delimited bodies.
- `multipart.jl` — `Form` and `Multipart` for `multipart/form-data` uploads.
- `Session.jl` — Stateful session with cookie jar, persistent connections, and ORM-style API (`session["/path"]`). Imports heavily from `main.jl`. Session-wide timeouts; timeouts are never retried and hang up the socket.
- `unchunk.jl` — `Unchunker` struct implementing `AbstractReadBuffer` for reading chunked transfer encoding. Stores trailers in a `Future{Header}`.
- `websocket.jl` — WebSocket client. `WebSocket(url)` connects and upgrades; `send`/`receive` for messaging; handles framing, masking, fragmentation, ping/pong, close handshake, and UTF-8 validation.
- `Logger.jl` — Debug IO wrapper that logs all reads/writes to separate streams.
- `test/local.jl` — self-contained client tests (in-process servers).
- `test/session_retry.jl` — reconnect classification unit tests.
- `test/http.jl` — HTTP integration tests against httpbin.
- `test/websocket.jl` — WebSocket tests against the Autobahn fuzzing suite.

### Server (`server/`)
- `main.jl` — `HTTPServer`, server-side `Request{method}` (parametric on HTTP verb), and `Response{T}`. The `serve(fn, port)` function accepts a callback and handles keep-alive, async connections, and error responses.
- `logger.jl` — Middleware-style logger with colored output via Crayons. Wraps handler to log method, URI, status, timing, and bytes.
- `examples/` — Sample server usage.

### Key Patterns
- Both client and server `Request`/`Response` types are parametric — `Request{:GET}`, `Response{T}` — enabling dispatch on HTTP method and body type.
- Client `Request` and `Response` both subtype `IO`, allowing streaming reads/writes.
- Client uses `write_body` for content-length bodies and chunked encoding via `send` on `Request`.
- Server `Response` rendering (`Base.write(io, ::Response)`) auto-selects chunked vs content-length encoding based on body type.

## Dependencies

Key external Kip packages: URI.jl, Buffer.jl, Prospects.jl (assoc/mutable helpers), Promises.jl (Future), JSON.jl, DOM.jl.
Reseau.jl (TCP/TLS sockets, DNS, deadlines), CodecZlib (gzip), Dates.
Server additionally uses Crayons for terminal colors.
