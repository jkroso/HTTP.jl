# HTTP.jl

A client and server side implementation of HTTP and WebSocket for Julia.

To use it you will need the [Kip](https://github.com/jkroso/Kip.jl) module system.

## HTTP Server

`serve` takes any `req -> Response` handler:

```julia
@use "github.com/jkroso/HTTP.jl/server" serve Response

server = serve(3000) do req
  Response("Hello world")
end
wait(server)
```

## Routing

A `Router` is itself a handler, so you `serve` it directly. Each path is bound to
a handler *function* whose methods dispatch on the request verb — so the HTTP
method is just Julia multiple dispatch on `Request{:GET}`, `Request{:POST}`, …:

```julia
@use "github.com/jkroso/HTTP.jl/server" serve Request Response
@use "github.com/jkroso/HTTP.jl/server/router" Router @route

const router = Router()

const ping = @route router "/ping"
ping(::Request{:GET}) = Response("pong")

const signup = @route router "/signup"        # one path, two verbs
signup(::Request{:POST})    = Response("thanks")
signup(::Request{:OPTIONS}) = Response(204)

const users = @route router "/users/:id"
users(req::Request{:GET}, params) = Response("user " * params["id"])

serve(router, 3000)
```

`@route` mints a fresh handler function, binds it to the path, and returns it;
you add verb methods to it. A method may take `(req, params)` or just `(req)`.
Paths support `:name`/`{name}` params, `*` (one segment) and `**` (the rest). A
path with no method for the request's verb returns 405; an unmatched path returns
404 — override both with `Router(notfound=…, notallowed=…)`. `@route "/path"`
(one argument) registers into a shared default router.

## HTTP Client

Returns a `Response` object which contains all the meta data needed to parse the response data into a rich data type such as HTML nodes or JSON objects. Because `Response` is also an IO, you can work directly with the byte stream.

```julia
@use "github.com/jkroso/HTTP.jl/client" GET POST PUT send

read(GET("google.com"), String) # a string of html

@use "github.com/jkroso/DOM.jl/html"
dom = parse(GET("google.com")) # a DOM object

send(PUT("gewgle.com"), MIME("text/html"), dom)
send(POST("httpbin.org/post"), MIME("application/json"), Dict("a"=>1))
```

`GET`/`POST`/`PUT`/`DELETE` take these keywords:

| keyword | default | |
|---|---|---|
| `meta` | `Header()` | request headers; also accepts a pair or vector of pairs |
| `data` | `nothing` | the body. Without it `POST`/`PUT` return the open `Request` for `send` |
| `query` | `nothing` | a Dict, NamedTuple or vector of pairs appended to the URL's query, escaped with `escapeuri` |
| `connect_timeout` | `0` | seconds for DNS lookup + TCP connect + TLS handshake |
| `readtimeout` | `0` | seconds the server may go without sending a byte |
| `timeout` | `0` | seconds for the whole request, redirects and body included |
| `max_redirects` | `5` | |

A timeout of `0` means none, as before.

### Errors

A 4xx or 5xx response throws an `HTTPError`. Its status is a type parameter so
you can match on it, and a field for generic handlers. The body is buffered
before the connection closes, so you can still read it:

```julia
@use "github.com/jkroso/HTTP.jl/client" GET HTTPError

try
  GET("api.example.com/thing/1")
catch e
  e isa HTTPError{404} && return nothing   # or: e isa HTTPError && e.status == 404
  rethrow()
end
```

`e.status`, `e.meta` (the response headers), `e.uri`, `e.verb` and `e.response`
are there, and `read(e, String)`/`parse(e)` read the body. Uncaught it reads
`HTTP 404 Not Found: GET https://api.example.com/thing/1` plus the start of a
text body. The query string is left out of the message since it often carries
keys.

`send(req, …)` doesn't throw: it returns the `Response` whatever the status, so
check `res.status` there.

### Retries

A dropped or refused connection, a connect timeout, or a 408, 429, 502, 503 or
504 is tried again, after a short backoff (~0.25s, then ~0.5s) or the server's
`Retry-After` if it sends one. GET, PUT and DELETE get 2 retries by default;
POST gets none, since sending it twice may do the thing twice. Set `retries` to
change that:

```julia
GET(url; retries=0)          # fail fast
POST(url; data, retries=3)   # you know this POST is safe to repeat
```

Not retried: a read timeout (the server is slow, not gone), a 4xx other than
408/429, a body that can't be sent again (an `IO`), a `Retry-After` longer than
10s (you get the error), and a streamed request once your function has the
response. `timeout` covers every try and wait together.

### Timeouts

```julia
@use "github.com/jkroso/HTTP.jl/client" GET TimeoutError

GET("slow.example.com"; connect_timeout=5, readtimeout=15)
```

Running out of time throws `TimeoutError`, whose `phase` is `:connect`,
`:read` or `:request` (the overall `timeout`). `readtimeout` is an idle limit,
not a total: a big download that keeps flowing never trips it, but a server that
goes quiet for that long does. Timeouts also bound the body writes of the
request.

### Headers

The client sends `Host`, `User-Agent: Julia/$VERSION`, `Accept-Encoding: gzip`,
`Connection: Keep-Alive` and `Accept: */*` unless `meta` already sets them (in
any case). An empty value drops the header entirely:
`meta=Header("accept-encoding"=>"")`.

Only gzip and deflate are decoded. If a server sends another encoding anyway
(say `br`), the body is returned as it came; check `res.meta["content-encoding"]`.

### Streaming

Pass a function first and the body isn't buffered. The function gets the
`Response` with the status and headers already read and the body still on the
socket, which closes when the function returns. That's how to download a file
too big for memory, and how to resume one:

```julia
@use "github.com/jkroso/HTTP.jl/client" GET Header

have = isfile(path) ? filesize(path) : 0
GET(url; readtimeout=30, meta=Header("range"=>"bytes=$have-", "accept-encoding"=>"identity")) do res
  # 206: the rest of the file. 200: the server ignored the range, so start over
  open(io -> write(io, res), path, res.status == 206 ? "a" : "w")
end
```

`read(res, n)`, `readavailable(res)` and `eof(res)` work piecewise too. A body
cut short of its Content-Length throws `EOFError` rather than looking finished.
A response with no Content-Length and no chunking is read until the server
closes the connection, streamed or not.

### Query strings

`escapeuri` percent-encodes a value (UTF-8, everything but `A-Za-z0-9-._~`), or
builds a whole query string from a Dict, NamedTuple or vector of pairs:

```julia
escapeuri("fish & chips")                  # "fish%20%26%20chips"
escapeuri(["q" => "café", "n" => 2])       # "q=caf%C3%A9&n=2"
GET("api.example.com/search"; query=["q" => "fish & chips"])
```

Prefer `query=` to splicing `escapeuri` output into the URL string: the URL is
parsed and re-encoded, which turns `%2B` back into a bare `+` and mangles
escaped UTF-8.

### Multipart uploads

```julia
@use "github.com/jkroso/HTTP.jl/client" POST send Form Multipart

POST("api.example.com/transcribe"; data=Form("model" => "whisper-1",
                                             "file" => Multipart("memo.m4a", bytes, "audio/mp4")))
send(POST(url), Form(Dict("doc" => open("report.pdf"))))  # an open file becomes a file part
```

`Form` takes pairs, a Dict or a NamedTuple. A `Multipart(filename, data,
content_type="application/octet-stream")` or an open `IOStream` is a file part;
anything else is a text field. The Content-Type header with its boundary and
the Content-Length are set for you, so don't set them in `meta`.

## Session

Keeps track of cookies, reuses sockets, and provides an ORM-like API for interacting with HTTP servers.

```julia
@use "github.com/jkroso/HTTP.jl/client/Session" Session

httpbin = Session("httpbin.org")
response = httpbin["/cookies/set?a=1"]
parse(response) # Dict("cookies"=>Dict("a"=>"1"))
```

`Session(url; connect_timeout, readtimeout, timeout)` applies those timeouts to
every request through it; `send(session, uri, mime, data; readtimeout=…)`
overrides them per call, and `data` may be a `Form`. A timeout is never retried
(dropped keep-alive sockets are) and leaves the session to reconnect on its
next request. `session["/path"]` throws `HTTPError` on 4xx/5xx like `GET`.

## WebSocket Client

A WebSocket client with full protocol support including fragmentation, ping/pong, close handshake, and UTF-8 validation.

```julia
@use "github.com/jkroso/HTTP.jl/client/websocket" WebSocket send receive Message TEXT BINARY CLOSE

ws = WebSocket("ws://localhost:8080/chat")
send(ws, "hello")              # send text
send(ws, UInt8[1, 2, 3])      # send binary
msg = receive(ws)              # returns a Message
String(msg)                    # get text content
close(ws)
```
