@use "github.com/jkroso/URI.jl" URI encode_query encode ["FSPath.jl" @fs_str FSPath]
@use "github.com/jkroso/Prospects.jl" assoc @mutable
@use "../status" messages
@use "./SSL.jl"
@use CodecZlib: transcode, GzipDecompressor
@use SimpleBufferStream: BufferStream, mem_usage
@use Sockets: connect, TCPSocket
@use Dates

# TODO: PR this into upstream project
Base.bytesavailable(io::BufferStream) = mem_usage(io)

const default_uri = URI("http://localhost/")
const CRLF = b"\r\n"

connect(uri::URI{:http}) = connect(uri.host, uri.port)

@mutable struct Request{verb} <: IO
  uri::URI
  sock::IO
  meta::AbstractDict=Base.ImmutableDict{String,String}()
  max_redirects::Int=5
  headers_started::Bool=false
  headers_finished::Bool=false
end

Base.write(io::Request, mime::MIME, data) = begin
  io.headers_started || start_headers(io)
  @assert !io.headers_finished
  bytes = sprint(show, mime, data)
  write(io.sock, "Content-Type: $mime\r\n")
  write(io.sock, "Content-Length: $(sizeof(bytes))\r\n\r\n", bytes)
  parse_response(io.sock)
end

Base.write(io::Request, b::UInt8) = begin
  io.headers_finished || start_body(io)
  write(io.sock, string(1, base=16), CRLF)
  write(io.sock , b, CRLF)
end

Base.write(io::Request, b::Vector{UInt8}) = begin
  io.headers_finished || start_body(io)
  write(io.sock, string(sizeof(b), base=16), CRLF)
  write(io.sock , b, CRLF)
end
Base.write(io::Request, b::Union{String,SubString{String}}) = write(io, Vector{UInt8}(b))

start_headers(req::Request{verb}) where verb = begin
  req.headers_started = true
  write(req.sock, verb, ' ', path(req.uri), " HTTP/1.1\r\n")
  write(req.sock, "Host: $(req.uri.host)\r\n")
  write(req.sock, "User-Agent: Julia/$VERSION\r\n")
  write(req.sock, "Accept-Encoding: gzip\r\n")
  write(req.sock, "Connection: Keep-Alive\r\n")
  haskey(req.meta, "accept") || write(req.sock, "Accept: */*\r\n")
  for (key, value) in req.meta
    write(req.sock, key, ": ", value, CRLF)
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
  parse_response(req.sock)
end

Base.close(req::Request) = begin
  req.headers_finished || start_body(req)
  write(req.sock, "0\r\n\r\n")
  parse_response(req.sock)
end

@mutable struct Response <: IO
  status::Int16
  meta::AbstractDict
  data::IO
end

Base.eof(io::Response) = eof(io.data)
Base.isopen(io::Response) = isopen(io.data)
Base.read(io::Response) = read(io.data)
Base.read(io::Response, ::Type{UInt8}) = read(io.data, UInt8)
Base.read(io::Response, n::Integer) = read(io.data, n)
Base.bytesavailable(io::Response) = bytesavailable(io.data)
Base.readavailable(io::Response) = readavailable(io.data)

function Base.show(io::IO, r::Response)
  println(io, "HTTP/1.1 ", r.status, ' ', messages[r.status])
  for (header, value) in r.meta
    println(io, header, ": ", value)
  end
  println(io)
  println(io, bytesavailable(r), " bytes waiting")
end

function path(uri::URI)
  str = encode(string(uri.path))
  query = encode_query(uri.query)
  if !isempty(query) str *= "?" * query end
  if !isempty(uri.fragment) str *= "#" * encode(uri.fragment) end
  return str
end

"Parse incoming HTTP data into a `Response`"
function parse_response(io::IO)
  status = parse_status(io)
  meta = parse_header(io)
  body = readbody(meta, io)

  encoding = lowercase(get(meta, "content-encoding", ""))
  if !isempty(encoding)
    if encoding == "gzip"
      buf = read(body)
      body = IOBuffer(transcode(GzipDecompressor, buf))
    else
      error("unknown encoding: $encoding")
    end
  end

  Response(status, meta, body)
end

parse_status(io::IO) = parse(Int, readline(io)[10:12])

parse_header(io::IO) = begin
  meta = Base.ImmutableDict{AbstractString,AbstractString}()
  for line in eachline(io)
    isempty(line) && break
    key,value = split(line, ':', limit=2)
    meta = assoc(meta, lowercase(key), strip(value))
  end
  meta
end

readbody(r::Response) = readbody(r.meta, r.data)
readbody(meta, io) = begin
  get(meta, "transfer-encoding", "") == "chunked" && return unchunk(io)
  len = get(meta, "content-length", "")
  if !isempty(len)
    buffer = BufferStream()
    write(buffer, read(io, parse(Int, len)))
    close(buffer)
    return buffer
  end
  error("unknown content length")
end

unchunk(io) = begin
  buffer = BufferStream()
  errormonitor(@async begin
    while !eof(io)
      line = readline(io)
      len = parse(Int, line, base=16)
      len == 0 && break
      @assert write(buffer, read(io, len)) == len
      @assert read(io, 2) == CRLF
    end
    # discard trailer
    while !eof(io)
      isempty(readline(io)) && break
    end
    close(buffer)
  end)
  buffer
end

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

# Create convenience methods for the common HTTP verbs so you can simply write `GET("github.com")`
for f in [:GET, :POST, :PUT, :DELETE]
  @eval begin
    $f(uri::AbstractString; kwargs...) = $f(parseURI(uri); kwargs...)
    $f(uri::URI; data=nothing, kwargs...) = begin
      req = Request{$(QuoteNode(f))}(uri=uri, sock=connect(uri); kwargs...)
      isnothing(data) || return run(req, data)
      $(f in (:GET, :DELETE) ? :(run(req)) : :(req))
    end
  end
end

Base.run(req::Request, data="") = begin
  res = write_body(req, data)
  res = handle_response(res, req, [req.uri], data)
  close(req.sock)
  res
end

"An opinionated wrapper which handles redirects and throws on 4xx and 5xx responses"
handle_response(res::Response, (;sock,uri,meta,max_redirects)::Request{verb}, seen::Vector, data::Any="") where verb = begin
  res.status >= 400 && (close(sock); throw(res))
  if res.status >= 300
    redirect = interpret_redirect(uri, res.meta["location"])
    @assert !(redirect in seen) "redirect loop $uri in $seen"
    max_redirects < 1 && error("too many redirects")
    if !canreuse(res.meta, uri, redirect)
      close(sock)
      sock = connect(redirect)
    end
    readbody(res) # skip the data
    req = Request{verb}(uri=redirect, meta=meta, sock=sock, max_redirects=max_redirects-1)
    return handle_response(write_body(req, data), req, push!(seen, redirect), data)
  end
  res
end

canreuse(meta, a, b) = samehost(a, b) && get(meta, "connection", "") == "keep-alive"
samehost(a::URI, b::URI) = a.host == b.host && a.port == b.port
