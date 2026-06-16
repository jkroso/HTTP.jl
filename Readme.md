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
