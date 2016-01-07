@require "github.com/coiljl/querystring@c627b5d" serialize => encode_query
@require "github.com/BioJulia/Libz.jl@27332bc" ZlibInflateInputStream
@require "github.com/JuliaWeb/MbedTLS.jl@0136c58" => MbedTLS
@require "github.com/jkroso/prospects@48c234b" TruncatedIO
@require "github.com/coiljl/status@4ce12d1" messages
@require "github.com/coiljl/URI@aa106e0" URI

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
Base.connect{schema}(uri::URI{schema}) = error("$schema not supported")
Base.connect(uri::URI{:http}) = Base.connect(uri.host, port(uri))
Base.connect(uri::URI{:https}) = begin
	sock = Base.connect(uri.host, port(uri))
	stream = MbedTLS.SSLContext()
	MbedTLS.setup!(stream, tls_conf)
	MbedTLS.set_bio!(stream, sock)
	MbedTLS.hostname!(stream, uri.host)
	MbedTLS.handshake(stream)
	return stream
end

type Response <: IO
	status::UInt16
	meta::Dict{AbstractString,AbstractString}
	socket::IO
	length::Real
end

Base.eof(io::Response) = io.length == 0 || eof(io.socket)
Base.read(io::Response, ::Type{UInt8}) = begin
	io.length -= 1
	read(io.socket, UInt8)
end

function Base.show(io::IO, r::Response)
  print(io, "Response(", string(r.status), ' ', messages[r.status], ", ",
												 length(r.meta), " headers, ",
												 r.length," bytes in body)")
end

##
# Make an HTTP request to `uri` blocking until a response is received
#
function request(verb, uri::URI, meta::Dict, data)
	io = connect(uri)
	write_headers(io, verb, uri, meta)
	write(io, data)
	Response(io)
end

# NB: most servers don't require the '\r' before each '\n' but some do
function write_headers(io::IO, verb::AbstractString, uri::URI, meta::Dict)
	write(io, verb, ' ', path(uri), " HTTP/1.1\r\n")
	for (key, value) in meta
		write(io, key, ": ", value, "\r\n")
	end
	write(io, "\r\n")
end

function path(uri::URI)
	str = uri.path
	query = encode_query(uri.query)
	if !isempty(query) str *= "?" * query end
	if !isempty(uri.fragment) str *= "#" * uri.fragment end
	return str
end

##
# Parse incoming HTTP data into a `Response`
#
function Response(io::IO)
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

	Response(status, meta, io, length)
end

const uri_defaults = Dict(:protocol => :http,
													:host => "localhost",
													:path => "/")

parseURI(uri::AbstractString) = URI(uri, uri_defaults)

port(uri::URI{:http}) = uri.port == 0 ? 80 : uri.port
port(uri::URI{:https}) = uri.port == 0 ? 443 : uri.port

##
# A surprising number of web servers expect to receive esoteric
# crap in their HTTP requests so lets send it to everyone so
# nobody ever needs to think about it
#
function with_bs(meta::Dict, uri::URI, data::AbstractString)
	get!(meta, "User-Agent", "Julia/$VERSION")
	get!(meta, "Host", "$(uri.host):$(port(uri))")
	get!(meta, "Accept-Encoding", "gzip")
	get!(meta, "Accept", "*/*")
	isempty(data) || get!(meta, "Content-Length", string(sizeof(data)))
	meta
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
		uri = URI(uri, path=r.meta["Location"])
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
		function $f(uri::URI, data::AbstractString="", meta::Dict=Dict())
			handle_request($(string(f)), uri, meta, data)
		end
		$f(uri::AbstractString, args...) = $f(parseURI(uri), args...)
	end
end
