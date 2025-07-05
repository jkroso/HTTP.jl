@use Crayons: @crayon_str
@use "." Request verb

logger(next) = req -> logger(next, req)
logger(next, req::Request) = begin
  println(" → ", BOLD, verb(req), RESET, ' ', req.uri)
  LoggedResponse(next, req)
end

struct LoggedResponse
  next::Any
  req::Request
end

Base.write(io::IO, r::LoggedResponse) = begin
  start = time_ns()
  res = r.next(r.req)
  bytes = write(io, res)
  time = time_ns() - start
  print(" ← ", BOLD, verb(r.req), RESET, ' ', r.req.uri, ' ')
  print(color[Int(floor(res.status/100))], res.status, ' ')
  print(RESET, humantime(time), ' ')
  println(humanbytes(bytes))
  bytes
end

const RESET = crayon"reset"
const BOLD = crayon"bold"
const color = [crayon"green", crayon"green", crayon"cyan", crayon"yellow", crayon"red"]

const units = [:B, :kB, :MB, :GB, :TB, :PB, :EB, :ZB, :YB]

humanbytes(n::Integer) = begin
  n == 0 && return "0B"
  exp = min(floor(log(n)/log(1000)), length(units))
  "$(tidynumber(n/1000^exp))$(units[Int(exp) + 1])"
end

humantime(ns::Integer) = begin
  ns > 1e9 && return tidynumber(ns/1e9) * "s"
  ns > 1e6 && return tidynumber(ns/1e6) * "ms"
  ns > 1e3 && return tidynumber(ns/1e3) * "μs"
  "$(ns)ns"
end

tidynumber(n::Real) = string(round(n, digits=1))
