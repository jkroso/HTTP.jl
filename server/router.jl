@use "." Request Response verb

# Path-pattern segments: an exact String, a named `:param`/`{param}` capturing one
# segment, `*` matching any one segment, or `**` matching all trailing segments.
struct Param; name::String end
struct AnySeg end
struct AnyRest end
const ANY = AnySeg()
const REST = AnyRest()
const Pattern = Vector{Union{String,Param,AnySeg,AnyRest}}

compile(path::AbstractString) = begin
  out = Pattern()
  for p in split(strip(path, '/'), '/'; keepempty=false)
    push!(out,
      p == "*"  ? ANY :
      p == "**" ? REST :
      startswith(p, ':') ? Param(p[2:end]) :
      (startswith(p, '{') && endswith(p, '}')) ? Param(p[2:end-1]) :
      String(p))
  end
  out
end

segments(path) = split(strip(string(path), '/'), '/'; keepempty=false)

"Match `segs` against a compiled `pattern`; return captured params or `nothing`."
matchpath(pattern::Pattern, segs) = begin
  params = Dict{String,String}()
  i = 1
  for pat in pattern
    pat === REST && (params["rest"] = join(segs[i:end], '/'); return params)
    i > length(segs) && return nothing
    if pat isa Param
      params[pat.name] = String(segs[i])
    elseif pat !== ANY && pat != segs[i]
      return nothing
    end
    i += 1
  end
  i == length(segs) + 1 ? params : nothing
end

"""
A request router. Each path maps to a handler *function* whose methods dispatch
on the request verb (`Request{:GET}`, `Request{:POST}`, …). Define routes with
the [`@route`](@ref) macro and `serve` the router directly — it is itself a
handler:

```julia
const router = Router()
const users = @route router "/users/:id"
users(req::Request{:GET}, params) = Response("user " * params["id"])
users(::Request{:DELETE})         = Response(204)
serve(router, 8080)
```

A handler method may take `(req, params)` or just `(req)`. A path with no method
for the request's verb yields 405; an unmatched path yields 404 — both
overridable via `Router(notfound=…, notallowed=…)`.
"""
mutable struct Router
  routes::Vector{Pair{Pattern,Any}}
  notfound::Any
  notallowed::Any
end

default_404(req) = Response(404, "Not Found")
default_405(req) = Response(405, "Method Not Allowed")
Router(; notfound=default_404, notallowed=default_405) = Router(Pair{Pattern,Any}[], notfound, notallowed)

"Bind handler function `fn` to `path` on the router. Usually written via `@route`."
register!(r::Router, path::AbstractString, fn) = (push!(r.routes, compile(path) => fn); fn)

(r::Router)(req::Request) = begin
  segs = segments(req.uri.path)
  matched = false
  for (pat, fn) in r.routes
    params = matchpath(pat, segs)
    params === nothing && continue
    matched = true
    hasmethod(fn, Tuple{typeof(req), typeof(params)}) && return fn(req, params)
    hasmethod(fn, Tuple{typeof(req)}) && return fn(req)
  end
  matched ? r.notallowed(req) : r.notfound(req)
end

# A shared default router for the one-argument `@route "/path"` form.
const DEFAULT = Router()
default_router() = DEFAULT

"""
    @route [router] path

Mint a fresh handler function, bind it to `path` on `router` (default: the shared
[`default_router`](@ref)), and return it. Give the returned function verb methods:

```julia
const ping = @route "/ping"
ping(::Request{:GET}) = Response("pong")
```
"""
macro route(path)
  f = gensym(:route)
  quote
    function $(esc(f)) end
    register!(default_router(), $(esc(path)), $(esc(f)))
    $(esc(f))
  end
end
macro route(router, path)
  f = gensym(:route)
  quote
    function $(esc(f)) end
    register!($(esc(router)), $(esc(path)), $(esc(f)))
    $(esc(f))
  end
end
