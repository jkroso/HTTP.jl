@use "." URI Request Response parseURI GET PUT POST DELETE write_body readbody interpret_redirect canreuse
@use "github.com/jkroso/Prospects.jl" assoc assoc_in @struct @mutable
@use Sockets: connect, TCPSocket
@use Dates

@struct struct Cookie
  name::String
  value::String
  path::String
  domain::String
  expires::Union{Nothing,Dates.DateTime}=nothing
  secure::Bool=false # restrict to https requests
  hostonly::Bool=false# should this cookie be sent to subdomains
end

parse_cookie(str::AbstractString, uri::URI, now::Dates.DateTime) = begin
  (kv, attrs...) = split(str, ';')
  name, value = map(strip, split(kv, '='))
  dict = Dict{String,String}()
  for attr in attrs
    kv = split(attr, '=')
    dict[strip(kv[1])] = strip(get(kv, 2, ""))
  end
  expires = if haskey(dict, "Expires")
    Dates.DateTime(dict["Expires"], Dates.dateformat"e, d u y H:M:S G\MT")
  elseif haskey(dict, "Max-Age")
    now + Dates.Second(parse(Int, dict["Max-Age"]))
  else
    nothing
  end
  Cookie(name=name,
         value=value,
         path=get(dict, "Path", "/"),
         domain=get(dict, "Domain", uri.host),
         expires=expires,
         secure=haskey(dict, "Secure"),
         hostonly=!haskey(dict, "Domain"))
end

@mutable struct Session
  uri::URI
  cookies::Dict{String,Cookie}=Dict{String,Cookie}()
  sock::Union{IO,Nothing}=nothing
  lock::ReentrantLock=ReentrantLock()
end

Session(uri::URI) = Session(uri=uri, sock=connect(uri))
Session(uri::AbstractString) = Session(parseURI(uri))

Base.isopen(s::Session) = s.sock != nothing && isopen(s.sock) && isreadable(s.sock) && iswritable(s.sock)
connect(s::Session) = isopen(s) ? s.sock : (s.sock = connect(s.uri))
Base.getindex(s::Session, path) = run(SessionRequest(s, :GET, path, connect(s), Dates.now()))

@struct struct SessionRequest{verb} <: IO
  session::Session
  request::Request{verb}
  max_redirects::Int=5
end

Base.run(sr::SessionRequest{:GET}) = begin
  try
    run_request(sr, Dates.now(), [sr.request.uri])
  catch e
    because_closed(e) || rethrow(e)
    sock = connect(sr.session.uri)
    sr.session.sock = sock
    run(SessionRequest{:GET}(sr.session, assoc(sr.request, :sock, sock)))
  end
end

because_closed(e::Base.IOError) = e.code == -32
because_closed(e::BoundsError) = e.i == 10:12
because_closed(e) = false

run_request((;session,request)::SessionRequest{:GET}, now, seen) = begin
  (;max_redirects, uri, sock, meta) = request
  res = write_body(request, "")
  for cookie in get_cookies(res.meta, uri, now)
    isexpired(cookie, now) && continue
    session.cookies[cookie.name] = cookie
  end
  res.status >= 400 && throw(res)
  if res.status >= 300
    redirect = interpret_redirect(uri, res.meta["location"])
    @assert !(redirect in seen) "redirect loop $uri in $seen"
    max_redirects < 1 && error("too many redirects")
    if !canreuse(res.meta, uri, redirect)
      sock = connect(redirect)
    end
    readbody(res) # skip the data
    sr = SessionRequest(session, :GET, redirect, sock, now)
    sr = assoc_in(sr, [:request, :max_redirects]=>max_redirects-1)
    return run_request(sr, now, push!(seen, redirect))
  end
  res
end

SessionRequest(s::Session, verb::Symbol, path, sock, now) = begin
  uri = parseURI(path, s.uri)
  uri = assoc(uri, :path, s.uri.path * uri.path)
  SessionRequest(s, verb, uri, sock, now)
end

SessionRequest(s::Session, verb::Symbol, uri::URI, sock, now) = begin
  cookies = Iterators.filter(values(s.cookies)) do c
    isexpired(c, now) && return false
    c.hostonly ? uri.host == c.domain : endswith(uri.host, c.domain)
  end
  meta = Base.ImmutableDict{String,String}()
  if !isempty(cookies)
    meta = assoc(meta, "cookie", join(("$(c.name)=$(c.value)" for c in cookies), "; "))
  end
  SessionRequest{verb}(s, Request{verb}(uri, sock, meta))
end

isexpired(c::Cookie, now::Dates.DateTime=Dates.now()) = c.expires != nothing && c.expires <= now

get_cookies(meta, uri, now=Dates.now()) = begin
  Cookie[parse_cookie(v, uri, now) for (k,v) in meta if k == "set-cookie"]
end
