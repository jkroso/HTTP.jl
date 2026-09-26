@use "." URI Request Response parseURI GET PUT POST DELETE write_body readbody interpret_redirect canreuse connect buffer! send
@use "github.com/jkroso/Prospects.jl" assoc assoc_in @struct @mutable
@use "../Header.jl" Header
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
  pending::Union{Response,Nothing}=nothing
end

Session(uri::URI) = Session(uri=uri, sock=connect(uri))
Session(uri::AbstractString) = Session(parseURI(uri))

Base.isopen(s::Session) = s.sock != nothing && isopen(s.sock) && isreadable(s.sock) && iswritable(s.sock)
Base.close(s::Session) = s.sock != nothing && close(s.sock)
connect(s::Session) = isopen(s) ? s.sock : (s.sock = connect(s.uri))
Base.getindex(s::Session, path) = run(SessionRequest(s, :GET, path, connect(s), Dates.now()))

"Drop a dead keep-alive socket and open a fresh one to the session origin."
reconnect!(s::Session) = begin
  try
    s.sock !== nothing && close(s.sock)
  catch
  end
  s.pending = nothing
  s.sock = connect(s.uri)
end

@struct struct SessionRequest{verb} <: IO
  session::Session
  request::Request{verb}
  max_redirects::Int=5
end

# Before sending on the reused socket, pull any unread body of the previous
# response into memory so it stays readable and the stream is clean for the
# next request. Record this response as the new pending one once it lands.
# Retries on peer-closed keep-alive (TLS reset / ECONNRESET / EPIPE).
Base.run(sr::SessionRequest{:GET}) = begin
  drain!(sr.session)
  attempt = 0
  while true
    attempt += 1
    try
      res = run_request(sr, Dates.now(), [sr.request.uri])
      sr.session.pending = res
      return res
    catch e
      because_closed(e) || rethrow(e)
      attempt >= 3 && rethrow(e)
      reconnect!(sr.session)
      sr = SessionRequest{:GET}(sr.session, assoc(sr.request, :sock, sr.session.sock))
      sleep(min(0.25 * 2^(attempt - 1), 2.0))
    end
  end
end

"""
POST a body on a keep-alive `Session`, reconnecting when the peer dropped the
socket under us (idle TLS reset, ECONNRESET, EPIPE). Used by LLM providers and
any other long-lived Session client.

`attempts` defaults to 3 (1 try + 2 reconnects). Exponential backoff between
retries: 0.25s, 0.5s (capped at 2s).
"""
function send(s::Session, uri::URI, mime, data; meta=Header(), attempts::Int=3)
  drain!(s)
  attempt = 0
  while true
    attempt += 1
    try
      if attempt > 1
        reconnect!(s)
        sleep(min(0.25 * 2^(attempt - 2), 2.0))
      end
      req = Request{:POST}(uri=uri, sock=connect(s), meta=meta)
      res = send(req, mime, data)
      s.pending = res
      return res
    catch e
      because_closed(e) || rethrow(e)
      attempt >= attempts && rethrow(e)
    end
  end
end

drain!(s::Session) = begin
  s.pending === nothing && return
  res = s.pending
  s.pending = nothing
  # If the keep-alive socket already died, that body is unrecoverable — drop it
  # rather than letting it break the next request (which uses a fresh socket).
  try buffer!(res) catch end
end

# ── Transport-dead classification ─────────────────────────────────────
# Keep-alive peers (esp. cloud LLM APIs) silently drop idle TLS sockets.
# Reseau surfaces that as TLSError("peek"|"read"|"write", …) wrapping
# SystemError(ECONNRESET); raw sockets throw IOError/SystemError. Also
# empty-line BoundsError from parse_status when the peer closed mid-request.

const _CLOSED_ERRNOS = (Libc.EPIPE, Libc.ECONNRESET, Libc.ENOTCONN, Libc.ECONNABORTED)

because_closed(e::Base.IOError) = abs(e.code) in _CLOSED_ERRNOS || e.code in (-32,)  # -32 legacy EPIPE
because_closed(e::Base.SystemError) = e.errnum in _CLOSED_ERRNOS
because_closed(e::BoundsError) = e.i == 10:12
because_closed(::EOFError) = true
function because_closed(e)
  # Nested cause (Reseau TLSError, TaskFailedException, etc.)
  if hasproperty(e, :cause)
    c = getfield(e, :cause)
    c isa Exception && because_closed(c) && return true
  end
  # Message fallback: "tls peek failed: unexpected TLS failure [SystemError: read: Connection reset by peer]"
  msg = try sprint(showerror, e) catch; return false end
  occursin(r"(?i)connection reset|broken pipe|connection is closed|not connected|tls (peek|read|write|handshake) failed", msg)
end

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
  meta = Header("cookie"=> join(("$(c.name)=$(c.value)" for c in cookies), "; "))
  SessionRequest{verb}(s, Request{verb}(uri=uri, sock=sock, meta=meta))
end

isexpired(c::Cookie, now::Dates.DateTime=Dates.now()) = c.expires != nothing && c.expires <= now

get_cookies(meta, uri, now=Dates.now()) = begin
  Cookie[parse_cookie(v, uri, now) for (k,v) in meta if k == "set-cookie"]
end
