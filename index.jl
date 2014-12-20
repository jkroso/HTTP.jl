@require "URI" URI

type Response
  status::Int
  meta::Dict{String,String}
  data::Any
end

##
# establish a TCPSocket with `uri`
#
function connect(uri::URI)
  @assert uri.schema == "http" "https not yet supported"
  ip = Base.getaddrinfo(uri.host)
  Base.connect(ip, uri.port)
end

##
# Make an HTTP request to `uri` blocking until a response is
# received
#
function request(verb, uri::URI, meta::Dict, data)
  io = connect(uri)
  write(io, "$verb $(resource(uri)) HTTP/1.1")
  for (key, value) in meta
    write(io, "\r\n$key: $value")
  end
  write(io, "\r\n" ^ 2)
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
    str = str[1:end-1]
  end
  if !isempty(uri.fragment) str *= "#" * uri.fragment end
  str
end

##
# Parse incomming HTTP data into a `Response`
#
function Response(io::Base.Socket)
  head = readuntil(io, "\r\n" ^ 2)
  lines = split(head, "\r\n")
  status = int(lines[1][9:12])
  meta = Dict{String,String}()
  for line in lines[2:end-2]
    key,value = split(line, ": ")
    meta[key] = value
  end
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
# Create convenience methods for the common HTTP verbs so
# you can simply write `GET("github.com")`
#
for f in [:GET, :POST, :PUT, :DELETE]
  @eval begin
    function $f(uri::URI, data::String="", meta::Dict=Dict())
      request($(string(f)), uri, meta, data)
    end
    $f(uri::String) = $f(parseURI(uri))
  end
end
