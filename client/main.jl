@use "github.com/bicycle1885/CodecZlib.jl" GzipDecompressorStream
@use "github.com/jkroso/AsyncBuffer.jl" Buffer SubStream
@use "github.com/coiljl/URI" URI encode_query encode
@use "github.com/jkroso/Destructure.jl" @destruct
@use "github.com/JuliaWeb/MbedTLS.jl" => MbedTLS
@use "github.com/jkroso/Prospects.jl" assoc
@use "../status" messages
import Sockets: connect, TCPSocket
import Dates

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

# establish a TCPSocket with `uri`
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
  meta::Dict{String,Union{String,Vector{String}}}
  data::IO
  uri::URI
end

Base.eof(io::Response) = eof(io.data)
Base.read(io::Response) = read(io.data)
Base.read(io::Response, T::Type) = read(io.data, T)
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

# Make an HTTP request to `uri` blocking until a response is received
function request(verb, uri::URI, meta::Dict, data, io::IO=connect(uri))
  write(io, verb, ' ', path(uri), b" HTTP/1.1")
  for (key, value) in meta
    write(io, CLRF, string(key), b": ", string(value))
  end
  write(io, CLRF, CLRF, data)
  handle_response(io, uri)
end

const CLRF = b"\r\n"

function path(uri::URI)
  str = encode(uri.path)
  query = encode_query(uri.query)
  if !isempty(query) str *= "?" * query end
  if !isempty(uri.fragment) str *= "#" * encode(uri.fragment) end
  return str
end

# Parse incoming HTTP data into a `Response`
function handle_response(io::IO, uri::URI)
  line = readline(io, keep=true)
  status = parse(Int, line[10:12])
  meta = Dict{String,Union{String,Vector{String}}}()

  for line in eachline(io)
    isempty(line) && break
    key,value = split(line, ": ")
    # Set-Cookie can appear multiple times
    if key == "Set-Cookie"
      push!(get!(Vector{String}, meta, key), value)
    else
      meta[key] = convert(String, value)
    end
  end

  output = io

  if haskey(meta, "Content-Length")
    output = SubStream(output, parse(Int, meta["Content-Length"]))
  elseif get(meta, "Transfer-Encoding", "") == "chunked"
    output = unchunk(output)
  end

  encoding = lowercase(get(meta, "Content-Encoding", ""))
  if encoding != ""
    delete!(meta, "Content-Encoding")
    delete!(meta, "Content-Length")
    if encoding == "gzip" || encoding == "deflate"
      # the special deflate decoder didn't work but gzip works on both types anyway
      output = GzipDecompressorStream(output)
    else
      error("unknown encoding: $encoding")
    end
  end

  Response(status, meta, output, uri)
end

# Unfortunatly MbedTLS doesn't provide a very nice stream so we need to try and adapt it
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
  "Accept-Encoding" => "gzip, deflate",
  "Connection" => "keep-alive",
  "Accept" => "*/*")

# A surprising number of web servers expect to receive esoteric crap in their HTTP
#requests so lets send it to everyone so nobody ever needs to think about it
function with_bs(meta::Dict, uri::URI, data::AbstractString)
  meta = merge(default_headers, meta)
  get!(meta, "Host", "$(uri.host):$(port(uri))")
  get!(meta, "Content-Length", string(sizeof(data)))
  return meta
end

# An opinionated wrapper which handles redirects and throws on 4xx and 5xx responses
function handle_request(verb, uri, meta, data; max_redirects=5)
  meta = with_bs(meta, uri, data)
  io = connect(uri)
  r = request(verb, uri, meta, data, io)
  redirects = URI[]
  while r.status >= 300
    r.status >= 400 && (close(io); throw(r))
    @assert !(uri ∈ redirects) "redirect loop $uri ∈ $redirects"
    push!(redirects, uri)
    length(redirects) > max_redirects && error("too many redirects")
    uri = parse_redirect(r.meta["Location"], uri)
    read(r.data) # skip the data
    r = request("GET", uri, meta, "", io)
  end
  close(io)
  return r
end

"Use the Response's mime type to parse a richer data type from its body"
function Base.parse(r::Response)
  mime = split(get(r.meta, "Content-Type", ""), ';')[1] |> MIME
  @assert applicable(parse, mime, r.data)
  parse(mime, r.data)
end

struct Cookie
  name::String
  value::String
  path::String
  domain::String
  expires::Union{Nothing,Dates.DateTime}
  secure::Bool    # restrict to https requests
  hostonly::Bool  # should this cookie be sent to subdomains
end

parse_cookie(str::AbstractString, uri::URI, now::Dates.DateTime) = begin
  @destruct [kv, attrs...] = split(str, ';')
  name, value = map(strip, split(kv, '='))
  dict = Dict{String,String}()
  for attr in attrs
    kv = split(attr, '=')
    dict[strip(kv[1])] = strip(get(kv, 2, ""))
  end
  Cookie(name,
         value,
         get(dict, "Path", "/"),
         get(dict, "Domain", uri.host),
         if haskey(dict, "Expires")
           Dates.DateTime(dict["Expires"], Dates.dateformat"e, d u y H:M:S G\MT")
         elseif haskey(dict, "Max-Age")
           now + Dates.Second(parse(Int, dict["Max-Age"]))
         else
           nothing
         end,
         haskey(dict, "Secure"),
         !haskey(dict, "Domain"))
end

mutable struct Session
  uri::URI
  cookies::Dict{String,Cookie}
  connection::Union{IO,Nothing}
  lock::ReentrantLock
end

Session(uri::URI) = Session(uri, Dict{String,Cookie}(), nothing, ReentrantLock())
Session(uri::AbstractString) = Session(parseURI(uri))

"Get an active TCPSocket associated with the sessions server"
connect(s::Session) = begin
  if !isopen(s)
    s.connection = connect(s.uri)
  end
  s.connection
end

Base.isopen(s::Session) = s.connection != nothing && isopen(s.connection)

handle_request(s::Session, verb::AbstractString, path::AbstractString, meta, body; max_redirects=5) =
  lock(s.lock) do
    io = connect(s)
    now = Dates.now()
    filter!(kv -> !isexpired(now, kv[2]), s.cookies)
    uri = assoc(s.uri, :path, joinpath(abspath("/", s.uri.path), path))
    meta = with_bs(assoc(meta, "Connection", "keep-alive"), uri, body)
    res = request(s, now, verb, uri, meta, body, io)
    redirects = URI[]
    while res.status >= 300
      res.status >= 400 && throw(r)
      @assert !(uri ∈ redirects) "redirect loop $uri ∈ $redirects"
      push!(redirects, uri)
      length(redirects) > max_redirects && error("too many redirects")
      uri = parse_redirect(res.meta["Location"], uri)
      res = request(s, now, "GET", uri, meta, "")
    end
    res
  end

parse_redirect(location::AbstractString, defaults::URI) =
  URI(location, Dict(:host=>defaults.host,
                     :port=>defaults.port,
                     :username=>defaults.username,
                     :password=>defaults.password))

request(s::Session, now::Dates.DateTime, verb::String, uri::URI, meta, data, io=connect(s)) = begin
  cookies = filter(collect(values(s.cookies))) do c
    if c.hostonly
      uri.host == c.domain
    else
      endswith(uri.host, c.domain)
    end
  end
  if !isempty(cookies)
    meta = assoc(meta, "Cookie", join(("$(c.name)=$(c.value)" for c in cookies), "; "))
  end
  res = request(verb, uri, meta, data, io)
  add_cookies(s, res, now)
  # needs to be buffered since the TCPSocket might get used for other requests
  # before anyone has had the chance the fully read the data from this request
  res.data = IOBuffer(read(res.data))
  if get(res.meta, "Connection", "keep-alive") == "close"
    close(io)
  end
  res
end

isexpired(now::Dates.DateTime, c::Cookie) = c.expires != nothing && c.expires <= now

add_cookies(s::Session, res::Response, now::Dates.DateTime) =
  for str in get(Vector{String}, res.meta, "Set-Cookie")
    c = parse_cookie(str, res.uri, now)
    if isexpired(now, c)
      delete!(s.cookies, c.name)
    else
      s.cookies[c.name] = c
    end
  end

# Create convenience methods for the common HTTP verbs so you can simply write `GET("github.com")`
for f in [:GET, :POST, :PUT, :DELETE]
  @eval begin
    function $f(uri::URI; meta::Dict=Dict(), data::AbstractString="")
      handle_request($(string(f)), uri, meta, data)
    end
    $f(uri::AbstractString; args...) = $f(parseURI(uri); args...)
    $f(s::Session, path::AbstractString; meta=Dict(), body="") = handle_request(s, $(string(f)), path, meta, body)
  end
end
