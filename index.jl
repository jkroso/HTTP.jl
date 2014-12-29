@require "URI" URI
import GnuTLS

type Response
  status::Int
  meta::Dict{String,String}
  data::Any
end

##
# establish a TCPSocket with `uri`
#
function connect(uri::URI)
  ip = Base.getaddrinfo(uri.host)
  sock = Base.connect(ip, uri.port)

  if uri.schema == "http"
    return sock
  end

  if uri.schema == "https"
    stream = GnuTLS.Session()
    GnuTLS.set_priority_string!(stream)
    GnuTLS.set_credentials!(stream, GnuTLS.CertificateStore())
    GnuTLS.associate_stream(stream, sock)
    GnuTLS.handshake!(stream)
    return stream
  end

  error("$(uri.schema) not supported")
end

##
# Make an HTTP request to `uri` blocking until a response is
# received
#
function request(verb, uri::URI, meta::Dict, data)
  io = connect(uri)
  write(io, "$verb $(resource(uri)) HTTP/1.1\n")
  for (key, value) in meta
    write(io, "$key: $value\n")
  end
  write(io, "\n")
  write(io, data)
  Response(io)
end

function resource(uri::URI)
  str = uri.path
  if !isempty(uri.query)
    str *= "?"
    for (key, value) in uri.query
      str *= "$key=$value&"
    end
    str = chop(str)
  end
  if !isempty(uri.fragment) str *= "#" * uri.fragment end
  str
end

##
# Parse incomming HTTP data into a `Response`
#
function Response(io::IO)
  status = int(readline(io)[9:12])
  meta = Dict{String,String}()
  for line in eachline(io)
    line = strip(line)
    line == "" && break
    key,value = split(line, ": ")
    meta[key] = value
  end
  mime = get(meta, "Content-Type", "application/octet-stream")
  mime = MIME(split(mime, "; ")[1])
  if haskey(meta, "Content-Length")
    io = truncate(io, int(meta["Content-Length"]))
  end
  body = applicable(parse, mime, io) ? parse(mime, io) : io
  Response(status, meta, body)
end

##
# Wraps the standard URI parser to provide sane defaults
# for HTTP requests
#
# - schema (http)
# - port (80 for http and 443 for https)
# - path ("/")
#
function parseURI(uri::String)
  if !ismatch(r"^https?://", uri)
    uri = replace(uri, r"^(//)?", "http://")
  end
  uri = URI(uri)
  if uri.port == 0
    uri.port = uri.schema == "http" ? 80 : 443
  end
  if uri.path == "" uri.path = "/" end
  if uri.host == "" uri.host = "localhost" end
  uri
end

##
# A suprising number of web servers expect to receive esoteric
# crap in their HTTP requests so lets send it to everyone so
# nobody ever needs to think about it
#
function with_bs(meta::Dict, uri::URI, data::String)
  get!(meta, "User-Agent", "Julia")
  get!(meta, "Host", "$(uri.host):$(uri.port)")
  isempty(data) || get!(meta, "Content-Length", string(sizeof(data)))
  meta
end

##
# Create convenience methods for the common HTTP verbs so
# you can simply write `GET("github.com")`
#
for f in [:GET, :POST, :PUT, :DELETE]
  @eval begin
    function $f(uri::URI, data::String="", meta::Dict=Dict())
      request($(string(f)), uri, with_bs(meta, uri, data), data)
    end
    $f(uri::String, args...) = $f(parseURI(uri), args...)
  end
end

##
# AsyncStream's in Julia don't do a very good job of being API
# compatible with other types of IO. TruncatedStream is an attempt
# to rectify this
#
type TruncatedStream <: IO
  stream::Base.AsyncStream
  nb::Int
  buff::String
  cursor::Int
end

Base.truncate(io::Base.AsyncStream, n::Integer) = TruncatedStream(io, n, "", 0)
Base.eof(io::TruncatedStream) = io.nb == 0
Base.read(io::TruncatedStream, ::Type{Uint8}) = begin
  io.nb -= 1
  if io.cursor >= length(io.buff)
    io.buff = readavailable(io.stream)
    io.cursor = 0
  end
  uint8(io.buff[io.cursor += 1])
end
# TODO: implement a decent `skip(::TruncatedStream, ::Int)`
