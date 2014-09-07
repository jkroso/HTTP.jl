import JSON
import Base: get, put, write, TcpSocket
@require "URI" URI

export get, post, put, delete, head

##
# Content-Type specific parsers
#
const parsers = [
  "application/json" => (s, h) -> JSON.parse(buffer(s, h))
]

##
# establish a TCPSocket with `uri`
#
function connect(uri)
  if uri.schema != "http"
    error("Unsupported schema: $(uri.schema)")
  end
  ip = Base.getaddrinfo(uri.host)
  port = uri.port == 0 ? 80 : uri.port
  Base.connect(ip, port)
end

typealias Headers Dict{String,String}

##
# make an HTTP request to `uri` blocking until a response is
# received
#
function request(verb::String, uri::URI, headers::Headers, data)
  stream = connect(uri)
  write(stream, "$verb $(uri.path) HTTP/1.1")
  for (key, value) in headers
    write(stream, "\r\n$key: $value")
  end
  write(stream, "\r\n" ^ 2)
  write(stream, data)
  Response(stream)
end

##
# Read all the data from `stream` into a String
#
function buffer(stream::TcpSocket, meta::Headers)
  len = int(get(meta, "Content-Length", -1))
  if len < 0 len = Inf end
  out = ""
  while isopen(stream)
    out *= readavailable(stream)
    if length(out) >= len
      close(stream)
      break
    end
  end
  out
end

immutable Response
  status::Int
  meta::Headers
  data::Any
end

##
# Parse a `Response` from a TCPSocket with incomming
# HTTP data
#
function Response(stream::TcpSocket)
  head = readuntil(stream, "\r\n" ^ 2)
  lines = split(head, "\r\n")
  status = int(lines[1][9:12])
  meta = Headers()
  for line in lines[2:end-2]
    key,value = split(line, ": ")
    meta[key] = value
  end
  typ = get(meta, "Content-Type", nothing)
  typ = split(typ, "; ")[1]
  parse = get(parsers, typ, buffer)
  Response(status, meta, parse(stream, meta))
end

##
# Wraps the standard URI parser to provide sane defaults
# for HTTP requests
#
# - schema (http)
# - port (80 for http and 443 for https)
# - path ("/")
#
parseURI(uri::String) = begin
  if !ismatch(r"^https?://", uri)
    uri = replace(uri, r"^(//)?", "http://")
  end
  uri = URI(uri)
  if uri.port == 0
    uri.port = uri.schema == "http" ? 80 : 443
  end
  if uri.path == "" uri.path = "/" end
  uri
end

##
# Create convenience methods for the common HTTP verbs so
# instead of `request("GET", URI("http://github.com"), Headers(), "")`
# you can simply write `get("github.com")`
#
for f in [:get, :post, :put, :delete, :head]
  @eval begin
    function $f(uri::URI, data::String="", headers::Headers=Headers())
      request($(uppercase(string(f))), uri, headers, data)
    end
    $f(uri::String) = $f(parseURI(uri))
  end
end
