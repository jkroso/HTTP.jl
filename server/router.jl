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

struct Route
  method::String
  pattern::Pattern
  handler::Any
end

"""
A request router: maps `(method, path)` to a handler. The router is itself a
handler, so you pass it straight to `serve`:

```julia
router = Router()
register!(router, "GET", "/ping", req -> Response("pong"))
register!(router, "GET", "/users/:id") do req, params
  Response("user " * params["id"])
end
serve(router, 8080)
```

Paths support `:name`/`{name}` params, `*` (one segment) and `**` (the rest,
captured as `"rest"`). A matched handler is called as `handler(req, params)`
when it accepts two arguments, else `handler(req)`. An unmatched path hits
`notfound` (404); a path that exists only under another method hits
`notallowed` (405). Both are overridable: `Router(notfound=…, notallowed=…)`.
"""
mutable struct Router
  routes::Vector{Route}
  notfound::Any
  notallowed::Any
end

default_404(req) = Response(404, "Not Found")
default_405(req) = Response(405, "Method Not Allowed")
Router(; notfound=default_404, notallowed=default_405) = Router(Route[], notfound, notallowed)

"Register `handler` for `method` + `path`. Also usable as a `do` block."
register!(r::Router, method::AbstractString, path::AbstractString, handler) =
  (push!(r.routes, Route(uppercase(method), compile(path), handler)); r)
register!(handler, r::Router, method::AbstractString, path::AbstractString) =
  register!(r, method, path, handler)

(r::Router)(req::Request) = begin
  segs = segments(req.uri.path)
  method = verb(req)
  pathmatched = false
  for rt in r.routes
    params = matchpath(rt.pattern, segs)
    params === nothing && continue
    pathmatched = true
    rt.method == method || continue
    return applicable(rt.handler, req, params) ? rt.handler(req, params) : rt.handler(req)
  end
  pathmatched ? r.notallowed(req) : r.notfound(req)
end
