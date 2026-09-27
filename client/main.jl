@use "github.com/jkroso/URI.jl" URI encode_query encode ["FSPath.jl" @fs_str FSPath]
@use "github.com/jkroso/Buffer.jl" Buffer
@use "github.com/jkroso/Prospects.jl" assoc @def
@use CodecZlib: transcode, GzipDecompressor, ZlibDecompressor, GzipDecompressorStream, ZlibDecompressorStream
@use "../status.jl" messages
@use "../Header.jl" Header parse_header
@use "./unchunk.jl" Unchunker
@use "./body.jl" Body
@use "./timeout.jl" Timeouts TimeoutError TimedIO timed connect_budget istimeout readall redact
@use "./multipart.jl" Form Multipart content_type body => form_body
@use Reseau: TLS, TCP
@use Dates

const default_uri = URI("http://localhost/")
const CRLF = b"\r\n"

connect(uri::URI{:http}; kw...) = try
  TCP.connect("$(uri.host):$(uri.port)"; kw...)
catch e
  uri.host == "localhost" && !istimeout(e) ? TCP.connect("127.0.0.1:$(uri.port)"; kw...) : rethrow()
end

connect(uri::URI{:https}; kw...) = TLS.connect("$(uri.host):$(uri.port)"; kw...)

"Connect within the `Timeouts`' connect budget, which covers DNS, TCP and the TLS handshake"
connect(uri::URI, t::Timeouts) = begin
  budget = connect_budget(t)
  budget == 0 && return connect(uri)
  try
    connect(uri; timeout_ns=budget)
  catch e
    istimeout(e) ? throw(TimeoutError(:connect, budget / 1e9, uri)) : rethrow()
  end
end

@def mutable struct Request{verb} <: IO
  uri::URI
  sock::IO
  meta::Header=Header()
  max_redirects::Int=5
  headers_started::Bool=false
  headers_finished::Bool=false
  timeouts::Timeouts=Timeouts()
  query::String=""  # already-escaped query params to append to `uri`'s
  stream::Bool=false # leave the response body on the socket for the caller to read
end

"Does `meta` set `name`? Header keys keep the caller's case, so compare lowercased"
hasheader(meta, name::AbstractString) = any(k -> lowercase(k) == name, keys(meta))

send(io::Request, mime::MIME, data) = begin
  io.headers_started || start_headers(io)
  @assert !io.headers_finished
  bytes = sprint(show, mime, data)
  hasheader(io.meta, "content-type") || write(io.sock, "Content-Type: $mime\r\n")
  write(io.sock, "Content-Length: $(sizeof(bytes))\r\n\r\n", bytes)
  flush(io.sock)
  parse_response(io.sock; stream=io.stream)
end

"Send a `multipart/form-data` body"
send(io::Request, form::Form) = write_body(io, form)

send(io::Request, b::UInt8) = begin
  io.headers_finished || start_body(io)
  write(io.sock, string(1, base=16), CRLF)
  write(io.sock , b, CRLF)
end

send(io::Request, b::Vector{UInt8}) = begin
  io.headers_finished || start_body(io)
  write(io.sock, string(sizeof(b), base=16), CRLF)
  write(io.sock , b, CRLF)
end
send(io::Request, b::Union{String,SubString{String}}) = send(io, Vector{UInt8}(b))

"The `Host` header's value: the port too, unless it's the scheme's default."
host_header(uri::URI) =
  uri.port == (uri.protocol == :https ? 443 : 80) || uri.port <= 0 ? uri.host : "$(uri.host):$(uri.port)"

# Defaults only fill in what the caller didn't set. An empty value suppresses a
# header entirely, e.g. `meta=Header("accept-encoding"=>"")`.
start_headers(req::Request{verb}) where verb = begin
  req.headers_started = true
  (;sock, meta) = req
  write(sock, verb, ' ', target(req), " HTTP/1.1\r\n")
  hasheader(meta, "host") || write(sock, "Host: ", host_header(req.uri), CRLF)
  hasheader(meta, "user-agent") || write(sock, "User-Agent: Julia/$VERSION\r\n")
  hasheader(meta, "accept-encoding") || write(sock, "Accept-Encoding: gzip\r\n")
  hasheader(meta, "connection") || write(sock, "Connection: Keep-Alive\r\n")
  hasheader(meta, "accept") || write(sock, "Accept: */*\r\n")
  for (key, value) in meta
    isempty(value) && continue
    write(sock, key, ": ", value, CRLF)
  end
end

start_body(req::Request) = begin
  req.headers_started || start_headers(req)
  write(req.sock, "Transfer-Encoding: chunked\r\n\r\n")
  req.headers_finished = true
end

write_body(req::Request, data) = begin
  req.headers_started || start_headers(req)
  write(req.sock, "Content-Length: $(sizeof(data))\r\n\r\n", data)
  req.headers_finished = true
  flush(req.sock)
  parse_response(req.sock; stream=req.stream)
end

write_body(req::Request, form::Form) = begin
  req.headers_started || start_headers(req)
  write(req.sock, "Content-Type: ", content_type(form), CRLF)
  write_body(req, form_body(form))
end

Base.close(req::Request) = begin
  req.headers_finished || start_body(req)
  write(req.sock, "0\r\n\r\n")
  flush(req.sock)
  parse_response(req.sock; stream=req.stream)
end

@def mutable struct Response <: IO
  status::Int16
  meta::Header
  data::IO
end

Base.eof(io::Response) = eof(io.data)
Base.isopen(io::Response) = isopen(io.data)
Base.read(io::Response) = Vector{UInt8}(read(io.data))
Base.read(io::Response, ::Type{UInt8}) = read(io.data, UInt8)
Base.read(io::Response, n::Integer) = read(io.data, n)
Base.bytesavailable(io::Response) = bytesavailable(io.data)
Base.readavailable(io::Response) = readavailable(io.data)

"Bodies still attached to a socket: everything `parse_response` makes except a `Buffer`"
lazy(io::IO) = io isa Union{Unchunker,Body} || io isa GzipDecompressorStream || io isa ZlibDecompressorStream

"""
Pull a still-streaming body fully into memory so the response stays readable
once its socket is closed or reused for another request. A no-op for bodies
that are already buffered (e.g. content-length responses).
"""
buffer!(res::Response) = begin
  lazy(res.data) || return res
  buf = Buffer(copy(read(res.data)))
  close(buf)
  res.data = buf
  res
end

function Base.show(io::IO, r::Response)
  println(io, "HTTP/1.1 ", r.status, ' ', get(messages, r.status, ""))
  for (header, value) in r.meta
    println(io, header, ": ", value)
  end
  println(io)
  println(io, bytesavailable(r), " bytes waiting")
end

"""
Thrown for a 4xx or 5xx response. The status is a type parameter so you can
match on it, `e isa HTTPError{404}`, and a field, `e.status`, for generic
handlers. The body is buffered, so `read(e, String)` and `parse(e)` work after
the connection is gone; `e.meta` is the response headers.
"""
struct HTTPError{status} <: Exception
  status::Int
  verb::Symbol
  uri::URI
  response::Response
end

HTTPError(verb::Symbol, uri::URI, res::Response) = HTTPError{Int(res.status)}(Int(res.status), verb, uri, buffer!(res))

Base.getproperty(e::HTTPError, k::Symbol) =
  k in (:meta, :data) ? getproperty(getfield(e, :response), k) : getfield(e, k)
Base.propertynames(::HTTPError) = (:status, :verb, :uri, :response, :meta, :data)
Base.read(e::HTTPError, args...) = read(e.response, args...)
Base.readavailable(e::HTTPError) = readavailable(e.response)
Base.eof(e::HTTPError) = eof(e.response)
Base.parse(e::HTTPError) = parse(e.response)

Base.showerror(io::IO, e::HTTPError) = begin
  print(io, "HTTP ", e.status, ' ', get(messages, e.status, ""), ": ", e.verb, ' ', redact(e.uri))
  text = excerpt(e.response)
  isempty(text) || print(io, "\n  ", text)
end
Base.show(io::IO, e::HTTPError) = print(io, "HTTPError{", e.status, "}(", e.verb, ' ', redact(e.uri), ')')

"The start of a buffered text body, whether or not it's been read yet"
excerpt(res::Response, n=200) = begin
  res.data isa Buffer || return ""
  type = get(res.meta, "content-type", "text/plain")
  occursin(r"text|json|xml|html|form"i, type) || return ""
  bytes = @view res.data.data[1:min(end, 4n)]
  isvalid(String, bytes) || return ""
  s = strip(replace(String(copy(bytes)), r"\s+" => ' '))
  length(s) > n ? first(s, n) * "…" : s
end

"The request line's target: path, the uri's query, and any extra `query` params"
target(req::Request) = begin
  isempty(req.query) && return path(req.uri)
  p = path(assoc(req.uri, :fragment, ""))
  p * (occursin('?', p) ? '&' : '?') * req.query
end

function path(uri::URI)
  str = encode(string(uri.path))
  query = encode_query(uri.query)
  if !isempty(query) str *= "?" * query end
  if !isempty(uri.fragment) str *= "#" * encode(uri.fragment) end
  return str
end

const unreserved = Set(codeunits("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))

"""
Percent-encode a query key or value (RFC 3986: all but `A-Za-z0-9-._~`, as
UTF-8 bytes). Given a Dict, NamedTuple or vector of pairs, build a whole query
string; a vector value repeats its key.

```julia
escapeuri("a b&c")                        # "a%20b%26c"
escapeuri(Dict("q" => "café", "n" => 2))  # "q=caf%C3%A9&n=2"
```
"""
escapeuri(s::AbstractString) = begin
  io = IOBuffer()
  for b in codeunits(String(s))
    b in unreserved ? write(io, b) : print(io, '%', uppercase(string(b, base=16, pad=2)))
  end
  String(take!(io))
end
escapeuri(x) = escapeuri(string(x))
escapeuri(q::Union{AbstractDict,NamedTuple,AbstractVector{<:Pair}}) =
  join((param(k, v) for (k, v) in kvs(q)), '&')

kvs(q::AbstractVector{<:Pair}) = q
kvs(q) = pairs(q)
param(k, v) = string(escapeuri(k), '=', escapeuri(v))
param(k, vs::AbstractVector) = join((param(k, v) for v in vs), '&')

query_string(::Nothing) = ""
query_string(q::AbstractString) = String(q)
query_string(q) = escapeuri(q)

"""
Parse incoming HTTP data into a `Response`. With `stream=true` the body is left
on `io` to be read on demand (see `Body`); otherwise it's read into memory.
"""
function parse_response(io::IO; stream::Bool=false)
  status = parse_status(io)
  meta = parse_header(io)
  body = readbody(status, meta, io; stream)
  Response(status, meta, decode(body, meta, stream))
end

"""
Undo gzip or deflate content-encoding. We only ever ask for gzip, so anything
else (e.g. `br` from a server ignoring Accept-Encoding) is passed through as is:
check `res.meta["content-encoding"]` if you need to know.
"""
decode(body, meta, stream) = begin
  encoding = lowercase(get(meta, "content-encoding", ""))
  codec = encoding in ("gzip", "x-gzip") ? GzipDecompressor :
          encoding == "deflate" ? ZlibDecompressor : nothing
  codec === nothing && return body
  if stream
    codec === GzipDecompressor ? GzipDecompressorStream(body) : ZlibDecompressorStream(body)
  else
    bytes = copy(read(body))
    isempty(bytes) ? closed(bytes) : closed(transcode(codec, bytes))
  end
end

closed(bytes::AbstractVector{UInt8}) = (b = Buffer(Vector{UInt8}(bytes)); close(b); b)

parse_status(io::IO) = parse(Int, readline(io)[10:12])

chunked(meta) = occursin("chunked", lowercase(get(meta, "transfer-encoding", "")))

"No length and not chunked: the body runs until the server closes the connection"
delimited_by_close(status, meta) =
  !(status in (204, 304) || 100 <= status < 200) && !chunked(meta) && isempty(get(meta, "content-length", ""))
delimited_by_close(r::Response) = delimited_by_close(r.status, r.meta)

readbody(r::Response) = readbody(r.status, r.meta, r.data)
readbody(status, meta, io; stream::Bool=false) = begin
  chunked(meta) && return Unchunker(io)
  len = get(meta, "content-length", "")
  if !isempty(len)
    n = parse(Int, len)
    stream && return Body(io, n)
    return closed(read(io, n))
  end
  (status in (204, 304) || 100 <= status < 200) && return closed(UInt8[])
  stream ? Body(io, -1) : closed(readall(io))
end

"Consume a body we don't want, e.g. a redirect's"
skip!(r::Response) = (read(r.data); r)

interpret_redirect(uri, redirect) = begin
  if startswith(redirect, "/")
    URI(redirect, defaults=uri)
  elseif occursin(r"^\w+://", redirect)
    parseURI(redirect, uri)
  else
    assoc(uri, :path, fs"/" * uri.path * ("../" * redirect))
  end
end

"Use the Response's mime type to parse a richer data type from its body"
Base.parse(r::Response) = parse(MIME(split(r.meta["content-type"], ';')[1]), r.data)

parseURI(str, defaults=default_uri) = begin
   uri = URI(str, defaults=defaults)
   uri.port > 0 && return uri
   assoc(uri, :port, uri.protocol == :http ? 80 : 443)
end

"""
Open a connection for a `verb` request to `uri`. Timeouts are in seconds:
`connect_timeout` bounds DNS + TCP + TLS handshake, `readtimeout` how long the
server may go quiet, `timeout` the whole request. `query` is appended to the
uri's query, escaped with `escapeuri`.
"""
request(verb::Symbol, uri::URI; connect_timeout::Real=0, readtimeout::Real=0, timeout::Real=0, query=nothing, kwargs...) = begin
  t = Timeouts(connect_timeout, readtimeout, timeout)
  sock = timed(connect(uri, t), t, uri)
  Request{verb}(; uri=uri, sock=sock, timeouts=t, query=query_string(query), kwargs...)
end

# Create convenience methods for the common HTTP verbs so you can simply write `GET("github.com")`
for f in [:GET, :POST, :PUT, :DELETE]
  @eval begin
    $f(uri::AbstractString; kwargs...) = $f(parseURI(uri); kwargs...)
    $f(uri::URI; data=nothing, kwargs...) = begin
      req = request($(QuoteNode(f)), uri; kwargs...)
      if isnothing(data)
        $(f in (:GET, :DELETE) ? :(data = "") : :(return req))
      end
      sock = req.sock
      try
        res, last = follow(write_body(req, data), req, [req.uri], data)
        sock = last.sock
        buffer!(res)
      finally
        safeclose(sock)
        sock === req.sock || safeclose(req.sock)
      end
    end
    $f(fn::Function, uri::AbstractString; kwargs...) = $f(fn, parseURI(uri); kwargs...)
    $f(fn::Function, uri::URI; data="", kwargs...) = begin
      req = request($(QuoteNode(f)), uri; stream=true, kwargs...)
      sock = req.sock
      try
        res, last = follow(write_body(req, data), req, [req.uri], data)
        sock = last.sock
        fn(res)
      finally
        safeclose(sock)
        sock === req.sock || safeclose(req.sock)
      end
    end
  end
end

@doc """
    GET(url; meta, query, data, connect_timeout, readtimeout, timeout, max_redirects)
    GET(fn, url; ...)

Make a request and return its `Response`, following redirects and throwing an
`HTTPError` for 4xx/5xx. `POST`/`PUT` without `data` return the open `Request`
for you to `send` a body on.

Given a function, the body isn't buffered: `fn` gets the `Response` with its
status and headers read and its body still on the socket, which is closed once
`fn` returns. Use it to stream large downloads to disk:

```julia
GET(url; meta=Header("range" => "bytes=\$(filesize(path))-")) do res
  open(io -> write(io, res), path, "a")
end
```
""" GET

"An opinionated wrapper which handles redirects and throws on 4xx and 5xx responses"
handle_response(res::Response, req::Request, seen::Vector, data::Any="") = first(follow(res, req, seen, data))

"Like `handle_response` but also returns the request that got the final response"
follow(res::Response, req::Request{verb}, seen::Vector, data::Any="") where verb = begin
  (;sock,uri,meta,max_redirects,timeouts,stream) = req
  res.status >= 400 && (err = HTTPError(verb, uri, res); safeclose(sock); throw(err))
  if res.status >= 300
    redirect = interpret_redirect(uri, res.meta["location"])
    @assert !(redirect in seen) "redirect loop $uri in $seen"
    max_redirects < 1 && error("too many redirects")
    if canreuse(res, uri, redirect)
      skip!(res)
    else
      close(sock)
      sock = timed(connect(redirect, timeouts), timeouts, redirect)
    end
    req = Request{verb}(uri=redirect, meta=meta, sock=sock, max_redirects=max_redirects-1,
                        timeouts=timeouts, stream=stream)
    return follow(write_body(req, data), req, push!(seen, redirect), data)
  end
  res, req
end

safeclose(io) = try close(io) catch end

canreuse(res::Response, a, b) = !delimited_by_close(res) && canreuse(res.meta, a, b)
canreuse(meta, a, b) = samehost(a, b) && get(meta, "connection", "") == "keep-alive"
samehost(a::URI, b::URI) = a.host == b.host && a.port == b.port
