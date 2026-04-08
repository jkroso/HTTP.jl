@use "." Request Response Headers
@use Random: randstring

mutable struct CookieSession <: AbstractDict{String,Any}
  id::String
  data::Dict{String,Any}
  isnew::Bool
end

CookieSession(id::String) = CookieSession(id, Dict{String,Any}(), true)

Base.getindex(s::CookieSession, key::String) = s.data[key]
Base.setindex!(s::CookieSession, value, key::String) = s.data[key] = value
Base.get(s::CookieSession, key::String, default) = get(s.data, key, default)
Base.haskey(s::CookieSession, key::String) = haskey(s.data, key)
Base.delete!(s::CookieSession, key::String) = delete!(s.data, key)
Base.keys(s::CookieSession) = keys(s.data)
Base.values(s::CookieSession) = values(s.data)
Base.length(s::CookieSession) = length(s.data)
Base.iterate(s::CookieSession, args...) = iterate(s.data, args...)
Base.isempty(s::CookieSession) = isempty(s.data)

const store = Dict{String,CookieSession}()
const COOKIE_NAME = "sid"

"""
Get the session for a request, creating a new one if none exists.

```julia
serve(3000) do req
  s = session(req)
  s["visits"] = get(s, "visits", 0) + 1
  set_cookie(Response("You've visited \$(s["visits"]) times"), s)
end
```
"""
session(req::Request) = begin
  id = session_id(req)
  if id !== nothing && haskey(store, id)
    return store[id]
  end
  s = CookieSession(randstring(32))
  store[s.id] = s
  s
end

session_id(req::Request) = begin
  header = get(req.meta, "Cookie", nothing)
  header === nothing && return nothing
  for part in split(header, "; ")
    kv = split(part, '=', limit=2)
    length(kv) == 2 && strip(kv[1]) == COOKIE_NAME && return strip(String(kv[2]))
  end
  nothing
end

"""
Set the session cookie on a Response
"""
set_cookie(res::Response, s::CookieSession) = begin
  cookie = "$(s.id); Path=/; HttpOnly; SameSite=Lax"
  existing = get(res.meta, "Set-Cookie", Tuple{String,String}[])
  Response(res.status,
           merge(res.meta, Dict("Set-Cookie" => vcat(existing, [(COOKIE_NAME, cookie)]))),
           res.data)
end

"""
Destroy a session and remove it from the store
"""
destroy!(s::CookieSession) = (delete!(store, s.id); empty!(s.data); nothing)
