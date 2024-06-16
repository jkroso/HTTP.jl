@use "github.com/jkroso/URI.jl" URI encode_query encode ["FSPath.jl" @fs_str FSPath]
@use "github.com/jkroso/Prospects.jl" assoc
@use "../status" messages
@use "./SSL.jl"
@use CodecZlib: transcode, GzipDecompressor
@use SimpleBufferStream: BufferStream, mem_usage
@use Sockets: connect, TCPSocket
@use Dates

# TODO: PR this into upstream project
Base.bytesavailable(io::BufferStream) = mem_usage(io)

const default_uri = URI("http://localhost/")

connect(uri::URI{:http}) = connect(uri.host, uri.port)

mutable struct Response <: IO
  status::Int16
  meta::AbstractDict
  data::IO
  uri::URI
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

"Make an HTTP request to `uri` blocking until a response is received"
function request(verb, uri::URI, meta::Dict, data, io::IO=connect(uri))
  write(io, verb, ' ', path(uri), " HTTP/1.1", CRLF)
  for (key, value) in meta
    write(io, key, ": ", value, CRLF)
  end
  write(io, "Content-Length: $(sizeof(data))", CRLF)
  write(io, "Host: $(uri.host)", CRLF)
  write(io, CRLF, data)
  handle_response(io, uri)
end

const CRLF = b"\r\n"

function path(uri::URI)
  str = encode(string(uri.path))
  query = encode_query(uri.query)
  if !isempty(query) str *= "?" * query end
  if !isempty(uri.fragment) str *= "#" * encode(uri.fragment) end
  return str
end

"Parse incoming HTTP data into a `Response`"
function handle_response(io::IO, uri::URI)
  line = readline(io)
  status = parse(Int, line[10:12])
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

  Response(status, meta, body, uri)
end

parse_header(io) = begin
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

const default_headers = assoc(Base.ImmutableDict{AbstractString,AbstractString}(),
  "User-Agent", "Julia/$VERSION",
  "Accept-Encoding", "gzip",
  "Connection", "Keep-Alive",
  "Accept", "*/*")

"An opinionated wrapper which handles redirects and throws on 4xx and 5xx responses"
function handle_request(verb, uri, meta, data; max_redirects=5)
  meta = merge(default_headers, meta)
  io = connect(uri)
  resp = request(verb, uri, meta, data, io)
  seen = URI[uri]
  while resp.status >= 300
    resp.status >= 400 && (close(io); throw(resp))
    redirect = interpret_redirect(uri, resp.meta["location"])
    @assert !(redirect ∈ seen) "redirect loop $uri ∈ $seen"
    push!(seen, redirect)
    length(seen) > max_redirects && error("too many redirects")
    if !canreuse(resp.meta, uri, redirect)
      close(io)
      io = connect(redirect)
    end
    readbody(resp) # skip the data
    uri = redirect
    resp = request("GET", uri, meta, "", io)
  end
  close(io)
  resp
end

canreuse(meta, a, b) = samehost(a, b) && get(meta, "connection", "") == "keep-alive"
samehost(a::URI, b::URI) = a.host == b.host && a.port == b.port

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
    function $f(uri::URI; meta::Dict=Dict(), data::AbstractString="", kwargs...)
      handle_request($(string(f)), uri, meta, data; kwargs...)
    end
    $f(uri::AbstractString; args...) = $f(parseURI(uri); args...)
  end
end
