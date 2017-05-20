@require "github.com/BioJulia/BufferedStreams.jl" BufferedInputStream
@require "github.com/BioJulia/Libz.jl" ZlibInflateInputStream
@require "github.com/coiljl/URI" URI encode_query encode
@require "github.com/JuliaWeb/MbedTLS.jl" => MbedTLS
@require "github.com/jkroso/Prospects.jl" TruncatedIO
@require "github.com/coiljl/status" messages

# taken from JuliaWeb/Requests.jl
function get_default_tls_config()
  conf = MbedTLS.SSLConfig()
  MbedTLS.config_defaults!(conf)

  rng = MbedTLS.CtrDrbg()
  MbedTLS.seed!(rng, MbedTLS.Entropy())
  MbedTLS.rng!(conf, rng)

  MbedTLS.authmode!(conf, MbedTLS.MBEDTLS_SSL_VERIFY_REQUIRED)
  MbedTLS.dbg!(conf, function(level, filename, number, msg)
    warn("MbedTLS emitted debug info: $msg in $filename:$number")
  end)
  MbedTLS.ca_chain!(conf)

  return conf
end

const tls_conf = get_default_tls_config()

##
# establish a TCPSocket with `uri`
#
Base.connect{protocol}(uri::URI{protocol}) = error("$protocol not supported")
Base.connect(uri::URI{:http}) = Base.connect(uri.host, port(uri))
Base.connect(uri::URI{:https}) = begin
  stream = MbedTLS.SSLContext()
  MbedTLS.setup!(stream, tls_conf)
  MbedTLS.set_bio!(stream, Base.connect(uri.host, port(uri)))
  MbedTLS.hostname!(stream, uri.host)
  MbedTLS.handshake(stream)
  return stream
end

mutable struct Response <: IO
  status::UInt16
  meta::Dict{String,String}
  socket::IO
  length::Real
  uri::URI
end

Base.eof(io::Response) = io.length == 0 || eof(io.socket)
Base.read(io::Response, ::Type{UInt8}) = begin
  io.length -= 1
  read(io.socket, UInt8)
end

function Base.show(io::IO, r::Response)
  print(io, "Response(\"", r.uri, "\" ",
                      r.status, ' ', messages[r.status], ", ",
                      length(r.meta), " headers, ",
                      r.length, " bytes in body)")
end

##
# Make an HTTP request to `uri` blocking until a response is received
#
function request(verb, uri::URI, meta::Dict, data)
  io = connect(uri)
  write_headers(io, verb, uri, meta)
  write(io, data)
  Response(io, uri)
end

const CLRF = b"\r\n"

# NB: most servers don't require the '\r' before each '\n' but some do
function write_headers(io::IO, verb::AbstractString, uri::URI, meta::Dict)
  write(io, verb, b" ", path(uri), b" HTTP/1.1\r\n")
  for (key, value) in meta
    write(io, string(key), b": ", string(value), CLRF)
  end
  write(io, CLRF)
end

function path(uri::URI)
  str = encode(uri.path)
  query = encode_query(uri.query)
  if !isempty(query) str *= "?" * query end
  if !isempty(uri.fragment) str *= "#" * encode(uri.fragment) end
  return str
end

##
# Parse incoming HTTP data into a `Response`
#
function Response(io::IO, uri::URI)
  line = readline(io)
  status = parse(Int, line[9:12])
  meta = Dict{AbstractString,AbstractString}()

  for line in eachline(io)
    line = strip(line)
    line == "" && break
    key,value = split(line, ": ")
    meta[key] = value
  end

  length = (haskey(meta, "Content-Length")
    ? parse(Int, meta["Content-Length"])
    : Inf)

  # Expand gzipped data
  if ismatch(r"gzip|deflate"i, get(meta, "Content-Encoding", ""))
    io = ZlibInflateInputStream(TruncatedIO(io, length))
    delete!(meta, "Content-Encoding")
    delete!(meta, "Content-Length")
    length = Inf # no way to know how long it will be now
  end

  Response(status, meta, io, length, uri)
end

const uri_defaults = Dict(:protocol => :http,
                          :host => "localhost",
                          :path => "/")

parseURI(uri::AbstractString) = URI(uri, uri_defaults)

port(uri::URI{:http}) = uri.port == 0 ? 80 : uri.port
port(uri::URI{:https}) = uri.port == 0 ? 443 : uri.port

const default_headers = Dict(
  "User-Agent" => "Julia/$VERSION",
  "Accept-Encoding" => "gzip",
  "Accept" => "*/*")

##
# A surprising number of web servers expect to receive esoteric
# crap in their HTTP requests so lets send it to everyone so
# nobody ever needs to think about it
#
function with_bs(meta::Dict, uri::URI, data::AbstractString)
  meta = merge(default_headers, meta)
  get!(meta, "Host", "$(uri.host):$(port(uri))")
  get!(meta, "Content-Length", string(sizeof(data)))
  return meta
end

##
# An opinionated wrapper which handles redirects and throws
# on 4xx and 5xx responses
#
function handle_request(verb, uri, meta, data; max_redirects=5)
  meta = with_bs(meta, uri, data)
  r = request(verb, uri, meta, data)
  redirects = URI[]
  while r.status >= 300
    r.status >= 400 && throw(r)
    isloop = uri in redirects
    push!(redirects, uri)
    isloop && error("redirect loop detected $redirects")
    length(redirects) > max_redirects && error("too many redirects")
    uri = URI(r.meta["Location"], uri)
    r = request("GET", uri, meta, "")
  end
  return r
end

##
# Create convenience methods for the common HTTP verbs so
# you can simply write `GET("github.com")`
#
for f in [:GET, :POST, :PUT, :DELETE]
  @eval begin
    function $f(uri::URI; meta::Dict=Dict(), data::AbstractString="")
      handle_request($(string(f)), uri, meta, data)
    end
    $f(uri::AbstractString; args...) = $f(parseURI(uri); args...)
  end
end
