@require "github.com/BioJulia/Libz.jl" ZlibInflateInputStream
@require "github.com/coiljl/URI" URI encode_query encode
@require "github.com/jkroso/AsyncBuffer.jl" Buffer Take asyncpipe
@require "github.com/JuliaWeb/MbedTLS.jl" => MbedTLS
@require "github.com/coiljl/status" messages
import Sockets.connect

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
connect(uri::URI{protocol}) where protocol = error("$protocol not supported")
connect(uri::URI{:http}) = connect(uri.host, port(uri))
connect(uri::URI{:https}) = begin
  stream = MbedTLS.SSLContext()
  MbedTLS.setup!(stream, tls_conf)
  MbedTLS.set_bio!(stream, connect(uri.host, port(uri)))
  MbedTLS.hostname!(stream, uri.host)
  MbedTLS.handshake(stream)
  return stream
end

mutable struct Response <: IO
  status::UInt16
  meta::Dict{String,String}
  data::IO
  uri::URI
end

Base.eof(io::Response) = eof(io.data)
Base.read(io::Response) = read(io.data)
Base.read(io::Response, T::Type{UInt8}) = read(io.data, T)
Base.read(io::Response, n::Number) = read(io.data, n)
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

##
# Make an HTTP request to `uri` blocking until a response is received
#
function request(verb, uri::URI, meta::Dict, data)
  io = connect(uri)
  write_headers(io, verb, uri, meta)
  write(io, data)
  handle_response(io, uri)
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
function handle_response(io::IO, uri::URI)
  line = readline(io, keep=true)
  status = parse(Int, line[9:12])
  meta = Dict{AbstractString,AbstractString}()

  for line in eachline(io)
    isempty(line) && break
    key,value = split(line, ": ")
    meta[key] = value
  end

  output = io

  if haskey(meta, "Content-Length")
    output = asyncpipe(output, Take(parse(Int, meta["Content-Length"])))
  elseif get(meta, "Transfer-Encoding", "") == "chunked"
    output = unchunk(output)
  end

  if occursin(r"gzip|deflate"i, get(meta, "Content-Encoding", ""))
    delete!(meta, "Content-Encoding")
    delete!(meta, "Content-Length")
    output = ZlibInflateInputStream(output)
  end

  Response(status, meta, output, uri)
end

##
# Unfortunatly MbedTLS doesn't provide a very nice stream so
# we need to try and adapt it
#
function handle_response(io::IO, uri::URI{:https})
  buffer = Buffer()
  main_task = current_task()
  @async try
    while !eof(io) && isopen(buffer)
      write(buffer, read(io, 1))
      write(buffer, read(io, bytesavailable(io)))
    end
    close(buffer)
    close(io)
  catch e
    Base.throwto(main_task, e)
  end
  invoke(handle_response, Tuple{IO, URI}, buffer, uri)
end

"""
Handle the [HTTP chunk format](https://tools.ietf.org/html/rfc2616#section-3.6)
"""
function unchunk(io::IO)
  main_task = current_task()
  out = Buffer()
  @async try
    while !eof(io)
      line = readuntil(io, "\r\n")
      len = parse(Int, line, base=16)
      if len == 0
        trailer = readuntil(io, "\r\n")
        close(out)
        break
      else
        write(out, read(io, len))
        @assert read(io, 2) == CLRF
      end
    end
  catch e
    Base.throwto(main_task, e)
  end
  out
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
    @assert !(uri ∈ redirects) "redirect loop $uri ∈ $redirects"
    push!(redirects, uri)
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

"""
Use the Response's mime type to parse a richer data type from its body
"""
function Base.parse(r::Response)
  mime = split(get(r.meta, "Content-Type", ""), ';')[1] |> MIME
  @assert applicable(parse, mime, r.data)
  parse(mime, r.data)
end
