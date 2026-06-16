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

For more than a couple of endpoints use a `Router` (itself a handler) instead of
branching by hand:

```julia
@use "github.com/jkroso/HTTP.jl/server" serve Response
@use "github.com/jkroso/HTTP.jl/server/router" Router register!

router = Router()
register!(router, "GET", "/ping", req -> Response("pong"))
register!(router, "GET", "/users/:id") do req, params
  Response("user " * params["id"])
end

serve(router, 3000)
```

Paths support `:name`/`{name}` params, `*` (one segment) and `**` (the rest). A
handler is called as `handler(req, params)` when it takes two arguments, else
`handler(req)`. Unmatched paths return 404; a path that exists only under another
method returns 405 — override both with `Router(notfound=…, notallowed=…)`.

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

## Session

Keeps track of cookies, reuses sockets, and provides an ORM-like API for interacting with HTTP servers.

```julia
@use "github.com/jkroso/HTTP.jl/client/Session" Session

httpbin = Session("httpbin.org")
response = httpbin["/cookies/set?a=1"]
parse(response) # Dict("cookies"=>Dict("a"=>"1"))
```

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
