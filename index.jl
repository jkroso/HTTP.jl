@require "prospects"
@require "URI" URI
import GnuTLS
import GZip

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
  write_headers(io, verb, resource(uri), meta)
  write(io, data)
  Response(io)
end

# NB: most servers don't require the '\r' before each '\n' but some do
function write_headers(io::IO, verb::String, resource::String, meta::Dict)
  write(io, "$verb $resource HTTP/1.1\r\n")
  for (key, value) in meta
    write(io, "$key: $value\r\n")
  end
  write(io, "\r\n")
end

##
# An opinionated wrapper which handles redirects and throws
# on 4xx and 5xx responses
#
function handle_request(verb, uri, meta, data; max_redirects=5)
  meta = with_bs(meta, uri, data)
  r = request(verb, uri, meta, data)
  redirects = String[]
  while r.status >= 300
    r.status >= 400 && throw(r)
    isloop = uri.path in redirects
    push!(redirects, uri.path)
    isloop && error("redirect loop detected $redirects")
    length(redirects) >= max_redirects && error("too many redirects")
    uri.path = r.meta["Location"]
    r = request("GET", uri, meta, "")
  end
  return r
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
# Parse incoming HTTP data into a `Response`
#
function Response(io::IO)
  line = readline(io)
  status = int(line[9:12])
  meta = Dict{String,String}()
  for line in eachline(io)
    line = strip(line)
    line == "" && break
    key,value = split(line, ": ")
    meta[key] = value
  end

  # TcpSockets don't normally ever reach EOF
  if haskey(meta, "Content-Length")
    io = truncate(io, int(meta["Content-Length"]))
  end

  # Transparently expand gzipped data
  if ismatch(r"gzip"i, get(meta, "Content-Encoding", "none"))
    size,io = gunzip(io)
    meta["Content-Length"] = string(size)
    delete!(meta, "Content-Encoding")
  end

  # Run the data through Base.parse(::MIME,::IO)
  mime = get(meta, "Content-Type", "application/octet-stream")
  mime = MIME(split(mime, "; ")[1])
  body = applicable(parse, mime, io) ? parse(mime, io) : io

  Response(status, meta, body)
end

##
# Unzip a stream
# TODO: extract into another module
#
function gunzip(io::IO)
  f1 = open(tempname(), "w+")
  f2 = open(tempname(), "w+")
  write(f1, io)
  seekstart(f1)
  gz = GZip.gzdopen(f1)
  write(f2, readbytes(gz))
  close(gz)
  close(f1)
  seekstart(f2)
  filesize(f2), f2
end

function Base.write(a::IO, b::GnuTLS.Session)
  total = 0
  while true
    try
      total += write(a, read(b, Uint8))
    catch e
      isa(e, EOFError) && return total
      rethrow(e)
    end
  end
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
# A surprising number of web servers expect to receive esoteric
# crap in their HTTP requests so lets send it to everyone so
# nobody ever needs to think about it
#
function with_bs(meta::Dict, uri::URI, data::String)
  get!(meta, "User-Agent", "Julia/$VERSION")
  get!(meta, "Host", "$(uri.host):$(uri.port)")
  get!(meta, "Accept-Encoding", "gzip")
  get!(meta, "Accept", "*/*")
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
      handle_request($(string(f)), uri, meta, data)
    end
    $f(uri::String, args...) = $f(parseURI(uri), args...)
  end
end
