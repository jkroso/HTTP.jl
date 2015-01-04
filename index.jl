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
  write(io, "$verb $(resource(uri)) HTTP/1.1\n")
  for (key, value) in meta
    write(io, "$key: $value\n")
  end
  write(io, "\n")
  write(io, data)
  Response(io)
end

function handle_request(verb, uri, meta, data; args...)
  r = request(verb, uri, meta, data ;args...)
  r.status >= 300 && return redirect(r, uri, meta; args...)
  return r
end

function redirect(r::Response, uri::URI, meta; max_redirects=5)
  redirects = String[]
  while r.status >= 300
    r.status >= 400 && throw(r)
    push!(redirects, uri.path)
    length(redirects) >= max_redirects && error("too many redirects")
    uri.path = r.meta["Location"]
    r = request("GET", uri, meta, "")
  end
  r
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
  status = int(readline(io)[9:12])
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
    tmp1 = tempname()
    tmp2 = tempname()
    open(f1 -> write(f1, io), tmp1, "w")
    open(tmp2, "w") do f2
      GZip.open(gz -> write(f2, gz), tmp1, "r")
    end
    meta["Content-Length"] = string(filesize(tmp2))
    io = open(tmp2, "r")
  end

  # Run the data through Base.parse(::MIME,::IO)
  mime = get(meta, "Content-Type", "application/octet-stream")
  mime = MIME(split(mime, "; ")[1])
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
# A surprising number of web servers expect to receive esoteric
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
      handle_request($(string(f)), uri, with_bs(meta, uri, data), data)
    end
    $f(uri::String, args...) = $f(parseURI(uri), args...)
  end
end
