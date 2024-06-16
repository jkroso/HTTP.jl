@use "." URI Response default_uri GET PUT POST default_headers request handle_request
@use "github.com/jkroso/Prospects.jl" assoc
@use Sockets: connect, TCPSocket
@use Dates

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
  (kv, attrs...) = split(str, ';')
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
Session(uri::AbstractString) = Session(URI(uri, defaults=default_uri))

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
    uri = URI(path, defaults=s.uri)
    meta = merge(default_headers, meta)
    res = request(s, now, verb, uri, meta, body, io)
    redirects = URI[]
    while res.status >= 300
      res.status >= 400 && throw(r)
      @assert !(uri ∈ redirects) "redirect loop $uri ∈ $redirects"
      push!(redirects, uri)
      length(redirects) > max_redirects && error("too many redirects")
      uri = URI(res.meta["location"], defaults=uri)
      res = request(s, now, "GET", uri, meta, "")
    end
    res
  end

request(s::Session, now::Dates.DateTime, verb::String, uri::URI, meta, data, io=connect(s)) = begin
  cookies = filter(collect(values(s.cookies))) do c
    if c.hostonly
      uri.host == c.domain
    else
      endswith(uri.host, c.domain)
    end
  end
  if !isempty(cookies)
    meta = assoc(meta, "cookie", join(("$(c.name)=$(c.value)" for c in cookies), "; "))
  end
  res = request(verb, uri, meta, data, io)
  add_cookies(s, res, now)
  # needs to be buffered since the TCPSocket might get used for other requests
  # before anyone has had the chance the fully read the data from this request
  res.data = IOBuffer(read(res.data))
  if get(res.meta, "connection", "keep-alive") == "close"
    close(io)
  end
  res
end

isexpired(now::Dates.DateTime, c::Cookie) = c.expires != nothing && c.expires <= now

get_cookies(r::Response, now=Dates.now()) = begin
  Cookie[parse_cookie(v, r.uri, now) for (k,v) in r.meta if k == "set-cookie"]
end

add_cookies(s::Session, res::Response, now::Dates.DateTime) = begin
  for c in get_cookies(res, now)
    if isexpired(now, c)
      delete!(s.cookies, c.name)
    else
      s.cookies[c.name] = c
    end
  end
end

for f in [:GET, :POST, :PUT, :DELETE]
  @eval begin
    $f(s::Session, path::AbstractString; meta=Dict(), body="") = handle_request(s, $(string(f)), path, meta, body)
  end
end
