# Self-contained client tests: every server runs in-process, so no docker or
# network is needed (except the one non-routable address used for the connect
# timeout, which never leaves the machine's routing table).
# Run: julia -e 'using Kip; @use "<abs path>/client/test/local.jl"'
using Test
@use "github.com/jkroso/JSON.jl/write.jl"
@use "github.com/jkroso/JSON.jl/read.jl"
@use CodecZlib: transcode, GzipCompressor
@use Reseau: TCP
@use "../../Header.jl" Header
@use ".." GET POST PUT DELETE Response HTTPError TimeoutError Form Multipart escapeuri send parseURI retryable
@use "../body.jl" Body
@use "../unchunk.jl" Unchunker
@use "../Session.jl" Session because_closed
@use "../../server" serve
@use "../../server" Request => SRequest Response => SResponse

const PORT = Ref(24000 + rand(0:4000))
nextport() = (PORT[] += 1)

"A raw TCP server: `handler(conn)` gets each accepted connection"
rawserver(handler) = begin
  port = nextport()
  l = TCP.listen("tcp", "127.0.0.1:$port")
  @async while isopen(l)
    conn = try TCP.accept(l) catch; break end
    @async try handler(conn) catch e
      e isa Union{EOFError,SystemError} || @warn "raw handler failed" exception=e
    finally
      try close(conn) catch end
    end
  end
  l, port
end

"Read a request head off `conn`: (request line, header lines)"
readhead(conn) = begin
  line = readline(conn)
  headers = String[]
  while true
    h = readline(conn)
    isempty(h) && break
    push!(headers, h)
  end
  line, headers
end

elapsed(f) = (t = time(); try f() catch e; (time() - t, e) end)

# ── the library's own server, for ordinary responses ─────────────────
const BIG = rand(UInt8, 5_000_000)
const APP_PORT = nextport()
const app = serve(APP_PORT) do req
  p = string(req.uri.path)
  body() = read(req.data, parse(Int, get(req.meta, "Content-Length", "0")))
  if p == "/ok"
    SResponse("ok")
  elseif p == "/missing"
    SResponse(404, Dict("Content-Type"=>"text/plain", "X-Reason"=>"gone"), "nope, not here")
  elseif p == "/boom"
    SResponse(500, Dict("Content-Type"=>"application/json"), """{"error":"kaboom"}""")
  elseif p == "/redirect"
    SResponse(302, Dict("Location"=>"/ok"), "")
  elseif p == "/chunked"
    SResponse(200, Dict("Content-Type"=>"text/plain"), IOBuffer("streamed in chunks"))
  elseif p == "/nocontent"
    SResponse(204, Dict{String,String}(), "")
  elseif p == "/echo"
    SResponse(200, Dict("Content-Type"=>get(req.meta, "Content-Type", "application/octet-stream")), body())
  elseif p == "/big"
    SResponse(200, Dict("Content-Type"=>"application/octet-stream"), BIG)
  else
    SResponse(404, "no route $p")
  end
end
const BASE = "http://127.0.0.1:$APP_PORT"

# ── raw servers, for protocol edge cases and timeouts ────────────────
const heads = Channel{Any}(32)
const (_, CAPTURE) = rawserver() do conn
  put!(heads, readhead(conn))
  write(conn, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
end

const (_, CLOSE_DELIMITED) = rawserver() do conn
  readhead(conn)
  write(conn, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nread me until the end")
end

const (_, GZIP) = rawserver() do conn
  readhead(conn)
  z = transcode(GzipCompressor, Vector{UInt8}("squashed then restored"))
  write(conn, "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: $(length(z))\r\n\r\n", z)
end

const (_, BROTLI) = rawserver() do conn
  readhead(conn)
  write(conn, "HTTP/1.1 200 OK\r\nContent-Encoding: br\r\nContent-Length: 4\r\n\r\n\x0b\x02\x80x")
end

const (_, CHUNKED_404) = rawserver() do conn
  readhead(conn)
  write(conn, "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n",
              "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
end

const (_, HANG) = rawserver() do conn   # accepts, reads the request, never answers
  readhead(conn)
  sleep(30)
end

const (_, SILENT) = rawserver() do conn # accepts TCP, never speaks (TLS handshake stalls)
  sleep(30)
end

# a body trickled in 5 pieces 0.4s apart: 2s in all, but never quiet for 1s
const (_, TRICKLE) = rawserver() do conn
  readhead(conn)
  write(conn, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n")
  for c in "abcde"
    sleep(0.4)
    write(conn, c)
  end
end

const (_, STALL_MID_BODY) = rawserver() do conn
  readhead(conn)
  write(conn, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n0123456789")
  sleep(30)
end

const (_, TRUNCATED) = rawserver() do conn
  readhead(conn)
  write(conn, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n0123456789")
end

const (_, NOCONTENT) = rawserver() do conn   # 204 with no Content-Length
  readhead(conn)
  write(conn, "HTTP/1.1 204 No Content\r\n\r\n")
  sleep(5)
end

const (_, SLOW) = rawserver() do conn   # 2s to first byte: fine without timeouts
  readhead(conn)
  sleep(2)
  write(conn, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nslow")
end

# honours `Range: bytes=N-` over BIG
const (_, RANGED) = rawserver() do conn
  _, headers = readhead(conn)
  range = filter(h -> startswith(lowercase(h), "range:"), headers)
  if isempty(range)
    write(conn, "HTTP/1.1 200 OK\r\nContent-Length: $(length(BIG))\r\n\r\n", BIG)
  else
    from = parse(Int, match(r"bytes=(\d+)-", range[1])[1])
    rest = BIG[from+1:end]
    write(conn, "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes $from-$(length(BIG)-1)/$(length(BIG))\r\n",
                "Content-Length: $(length(rest))\r\n\r\n", rest)
  end
end

url(port, path="/") = "http://127.0.0.1:$port$path"
sleep(0.2)

@testset "defaults are unchanged" begin
  res = GET("$BASE/ok")
  @test res.status == 200
  @test read(res, String) == "ok"
  @test read(GET("$BASE/redirect"), String) == "ok"
  res = GET("$BASE/chunked")
  @test res.status == 200
  @test read(res, String) == "streamed in chunks" # buffered: readable after the socket closed
  @test read(GET(url(GZIP)), String) == "squashed then restored"
  @test read(GET("$BASE/nocontent")) == UInt8[]
  @test read(GET(url(NOCONTENT))) == UInt8[] # no length, but no body either: doesn't wait for a close
  @test_throws HTTPError GET("$BASE/missing")
  @test_throws HTTPError{500} GET("$BASE/boom")
  res = send(POST("$BASE/echo"), MIME("application/json"), Dict("a"=>1))
  @test parse(res) == Dict("a"=>1)
  @test read(POST("$BASE/echo", data="raw body"), String) == "raw body"
  @test read(PUT("$BASE/echo", data="put body"), String) == "put body"
  @test read(DELETE("$BASE/ok"), String) == "ok"
  # the default request head
  GET(url(CAPTURE, "/path?a=1"))
  line, headers = take!(heads)
  @test line == "GET /path?a=1 HTTP/1.1"
  @test headers == ["Host: 127.0.0.1:$CAPTURE", "User-Agent: Julia/$VERSION", "Accept-Encoding: gzip",
                    "Connection: Keep-Alive", "Accept: */*", "Content-Length: 0"]
end

@testset "HTTPError" begin
  e = try GET("$BASE/missing") catch e; e end
  @test e isa HTTPError{404}
  @test e isa HTTPError && e isa Exception
  @test e.status == 404
  @test e.verb == :GET
  @test e.meta["x-reason"] == "gone"
  @test e.response isa Response
  @test read(e, String) == "nope, not here"
  msg = sprint(showerror, e)
  @test startswith(msg, "HTTP 404 Not Found: GET http://127.0.0.1:$APP_PORT/missing")
  @test occursin("nope, not here", msg)
  @test sprint(show, e) == "HTTPError{404}(GET http://127.0.0.1:$APP_PORT/missing)"
  e = try GET("$BASE/boom?key=secret") catch e; e end
  @test parse(e) == Dict("error"=>"kaboom")
  @test !occursin("secret", sprint(showerror, e)) # query values stay out of logs
  # a chunked error body is buffered before its socket closes
  e = try GET(url(CHUNKED_404)) catch e; e end
  @test e isa HTTPError{404}
  @test read(e, String) == "hello world"
  @test !because_closed(e)
  # the do-block form throws before calling back
  called = false
  @test_throws HTTPError{404} GET(_ -> (called = true), "$BASE/missing")
  @test !called
end

@testset "caller-set headers win" begin
  GET(url(CAPTURE); meta=Header("User-Agent"=>"fred/1", "ACCEPT-ENCODING"=>"identity",
                                "connection"=>"close", "Host"=>"example.com", "accept"=>"text/csv"))
  _, headers = take!(heads)
  lower = map(lowercase, headers)
  n(h) = count(startswith(h), lower)
  @test n("user-agent:") == 1 && "User-Agent: fred/1" in headers
  @test n("accept-encoding:") == 1 && "ACCEPT-ENCODING: identity" in headers
  @test n("connection:") == 1 && "connection: close" in headers
  @test n("host:") == 1 && "Host: example.com" in headers
  @test n("accept:") == 1 && "accept: text/csv" in headers
  # an empty value suppresses the default outright
  GET(url(CAPTURE); meta=Header("accept-encoding"=>""))
  _, headers = take!(heads)
  @test !any(h -> startswith(lowercase(h), "accept-encoding"), headers)
  # send(mime) leaves a caller's content-type alone
  req = POST(url(CAPTURE); meta=Header("Content-Type"=>"application/vnd.api+json"))
  send(req, MIME("application/json"), Dict("a"=>1))
  _, headers = take!(heads)
  @test count(h -> startswith(lowercase(h), "content-type"), headers) == 1
  @test "Content-Type: application/vnd.api+json" in headers
end

@testset "timeouts" begin
  # nothing answers at a non-routable address
  t, e = elapsed(() -> GET("http://10.255.255.1:81/"; connect_timeout=1, retries=0))
  @test e isa TimeoutError && e.phase == :connect
  @test 0.9 < t < 3
  @test occursin("connect timed out", sprint(showerror, e))
  # retried by default: three tries, each with the full connect budget
  t, e = elapsed(() -> GET("http://10.255.255.1:81/"; connect_timeout=0.5))
  @test e isa TimeoutError && e.phase == :connect
  @test 1.5 < t < 3
  # TCP connects but the TLS handshake never completes: still the connect budget
  t, e = elapsed(() -> GET("https://127.0.0.1:$SILENT/"; connect_timeout=1, retries=0))
  @test e isa TimeoutError && e.phase == :connect
  @test 0.9 < t < 3
  # the overall timeout bounds connecting too
  t, e = elapsed(() -> GET("http://10.255.255.1:81/"; timeout=1))
  @test e isa TimeoutError
  @test t < 3
  # the server takes the request and goes quiet
  t, e = elapsed(() -> GET(url(HANG); readtimeout=1))
  @test e isa TimeoutError && e.phase == :read
  @test 0.8 < t < 3
  @test !because_closed(e) # a Session won't retry it
  # readtimeout is an idle limit: a slow but steady body is fine...
  @test read(GET(url(TRICKLE); readtimeout=1), String) == "abcde"
  # ...unless the overall timeout is shorter
  t, e = elapsed(() -> GET(url(TRICKLE); readtimeout=1, timeout=1))
  @test e isa TimeoutError && e.phase == :request
  @test t < 2
  # a stall part way through the body
  _, e = elapsed(() -> GET(url(STALL_MID_BODY); readtimeout=1))
  @test e isa TimeoutError && e.phase == :read
  # no timeout by default
  @test read(GET(url(SLOW)), String) == "slow"
  @test read(GET(url(SLOW); connect_timeout=1, readtimeout=5), String) == "slow"
  # a request built for `send` carries its timeouts
  _, e = elapsed(() -> send(POST(url(HANG); readtimeout=1), MIME("application/json"), Dict("a"=>1)))
  @test e isa TimeoutError && e.phase == :read
  # and in streaming mode the body reads are bounded as well
  _, e = elapsed(() -> GET(res -> read(res), url(STALL_MID_BODY); readtimeout=1))
  @test e isa TimeoutError && e.phase == :read
end

@testset "Session" begin
  s = Session(BASE)
  @test read(s["/ok"], String) == "ok"
  e = try s["/missing"] catch e; e end
  @test e isa HTTPError{404}
  @test read(e, String) == "nope, not here"
  @test read(s["/ok"], String) == "ok" # the socket is still usable
  close(s)
  # timeouts on a session, and it recovers afterwards
  s = Session(url(HANG); readtimeout=1)
  _, e = elapsed(() -> s["/"])
  @test e isa TimeoutError && e.phase == :read
  _, e = elapsed(() -> send(s, s.uri, MIME("application/json"), Dict("a"=>1)))
  @test e isa TimeoutError
  close(s)
  s = Session(BASE; readtimeout=5)
  @test parse(send(s, parseURI("$BASE/echo"), MIME("application/json"), Dict("b"=>2))) == Dict("b"=>2)
  # per-call override
  @test read(send(s, parseURI("$BASE/echo"), MIME("text/plain"), "x"; readtimeout=1)) == Vector{UInt8}(repr("x"))
  close(s)
  # a close-delimited response hangs up, and the next request reconnects
  s = Session(url(CLOSE_DELIMITED))
  @test read(s["/"], String) == "read me until the end"
  @test read(s["/"], String) == "read me until the end"
  close(s)
end

@testset "streaming" begin
  seen = GET("$BASE/big") do res
    @test res.status == 200
    @test res.meta["content-length"] == string(length(BIG))
    @test res.data isa Body # left on the socket, not buffered
    @test bytesavailable(res) == 0
    path = tempname()
    open(io -> write(io, res), path, "w")
    @test isopen(res)
    (read(path), res)
  end
  bytes, res = seen
  @test bytes == BIG
  @test !isopen(res) # the socket closes when the block returns
  # resume a download with a Range header
  path = tempname()
  write(path, BIG[1:1_234_567])
  GET(url(RANGED); meta=Header("range"=>"bytes=$(filesize(path))-")) do res
    @test res.status == 206
    open(io -> write(io, res), path, "a")
  end
  @test read(path) == BIG
  # chunked, gzip and close-delimited bodies all stream too
  @test GET(res -> read(res, String), "$BASE/chunked") == "streamed in chunks"
  @test GET(res -> read(res, String), url(GZIP)) == "squashed then restored"
  @test GET(res -> read(res, String), url(CLOSE_DELIMITED)) == "read me until the end"
  @test GET(res -> read(res), "$BASE/nocontent") == UInt8[]
  # piecewise reads
  GET(url(CLOSE_DELIMITED)) do res
    @test String(read(res, 4)) == "read"
    @test read(res, UInt8) == UInt8(' ')
    @test String(read(res)) == "me until the end"
    @test eof(res)
  end
  # a Content-Length body cut short is an error, not a quiet end
  @test_throws EOFError GET(res -> read(res), url(TRUNCATED))
  # the result of the block is returned; redirects are followed first
  @test GET(res -> (res.status, read(res, String)), "$BASE/redirect") == (200, "ok")
end

@testset "multipart" begin
  audio = rand(UInt8, 100_000)
  form = Form("model" => "whisper-1", "n" => 3,
              "file" => Multipart("memo.m4a", audio, "audio/mp4"))
  res = POST("$BASE/echo"; data=form)
  @test startswith(res.meta["content-type"], "multipart/form-data; boundary=$(form.boundary)")
  body = read(res)
  text = String(copy(body))
  @test startswith(text, "--$(form.boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n")
  @test occursin("name=\"n\"\r\n\r\n3\r\n", text)
  @test occursin("Content-Disposition: form-data; name=\"file\"; filename=\"memo.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n", text)
  @test endswith(text, "\r\n--$(form.boundary)--\r\n")
  i = findfirst(Vector{UInt8}("audio/mp4\r\n\r\n"), body)
  @test body[i[end]+1:i[end]+length(audio)] == audio # bytes arrive intact
  # send(req, form), open files, dict forms, and quoting
  path = tempname() * ".txt"
  write(path, "file contents")
  res = open(path) do io
    send(POST("$BASE/echo"), Form(Dict("doc" => io)))
  end
  text = read(res, String)
  @test occursin("filename=\"$(basename(path))\"\r\nContent-Type: application/octet-stream\r\n\r\nfile contents\r\n", text)
  res = send(POST("$BASE/echo"), Form("a\"b" => "c"))
  @test occursin("name=\"a%22b\"", read(res, String))
  # the Content-Length the server trusted matched the body
  s = Session(BASE)
  res = send(s, parseURI("$BASE/echo"), nothing, Form((model="tiny", file=Multipart("x.bin", UInt8[1,2,3]))))
  @test occursin("filename=\"x.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n\x01\x02\x03\r\n", read(res, String))
  close(s)
end

@testset "close-delimited bodies" begin
  res = GET(url(CLOSE_DELIMITED))
  @test res.status == 200
  @test read(res, String) == "read me until the end"
end

@testset "unknown content-encoding is passed through" begin
  res = GET(url(BROTLI))
  @test res.meta["content-encoding"] == "br"
  @test read(res) == UInt8[0x0b, 0x02, 0x80, UInt8('x')]
end

@testset "escapeuri and query" begin
  @test escapeuri("a b&c=d/e?f#g+h%i") == "a%20b%26c%3Dd%2Fe%3Ff%23g%2Bh%25i"
  @test escapeuri("AZaz09-._~") == "AZaz09-._~"
  @test escapeuri("café") == "caf%C3%A9"
  @test escapeuri(42) == "42"
  @test escapeuri(["q" => "a b", "tag" => ["x", "y"]]) == "q=a%20b&tag=x&tag=y"
  @test escapeuri((q="1+1", n=2)) == "q=1%2B1&n=2"
  GET(url(CAPTURE, "/search"); query=["q" => "fish & chips", "city" => "Wagga Wagga", "é" => "ü"])
  line, _ = take!(heads)
  @test line == "GET /search?q=fish%20%26%20chips&city=Wagga%20Wagga&%C3%A9=%C3%BC HTTP/1.1"
  GET(url(CAPTURE, "/search?page=2"); query=Dict("q" => "a+b"))
  line, _ = take!(heads)
  @test line == "GET /search?page=2&q=a%2Bb HTTP/1.1"
end

@testset "unchunk" begin
  io = PipeBuffer()
  write(io, "2\r\nab\r\n1\r\nc\r\n0\r\nA: b\r\n\r\n")
  body = Unchunker(io)
  @test read(body) == UInt8[('a':'c')...]
  @test wait(body.trailers) == Header("a"=>"b")
end

close(app)
println("local client tests OK")

# ── retries ──────────────────────────────────────────────────────────
"A raw server answering the nth request with `script(n)`: (status, extra header lines) or :drop"
scripted(script) = begin
  hits = Ref(0)
  _, port = rawserver() do conn
    readhead(conn)
    hits[] += 1
    r = script(hits[])
    r === :drop && return
    status, extra = r
    body = status == 200 ? "fine" : "busy"
    write(conn, "HTTP/1.1 $status X\r\n", join(("$h\r\n" for h in extra)),
          "Content-Length: $(sizeof(body))\r\nConnection: close\r\n\r\n", body)
  end
  hits, port
end

@testset "retries" begin
  # busy twice, then fine: a GET gets there
  hits, port = scripted(n -> n < 3 ? (503, ["Retry-After: 0"]) : (200, String[]))
  @test read(GET(url(port)), String) == "fine" && hits[] == 3
  # one more than the default two retries is an error, the last one
  hits, port = scripted(n -> (503, ["Retry-After: 0"]))
  @test_throws HTTPError{503} GET(url(port))
  @test hits[] == 3
  # retries=0 asks once
  hits, port = scripted(n -> (503, ["Retry-After: 0"]))
  @test_throws HTTPError{503} GET(url(port); retries=0)
  @test hits[] == 1
  # a POST isn't sent twice unless asked
  hits, port = scripted(n -> n < 2 ? (503, ["Retry-After: 0"]) : (200, String[]))
  @test_throws HTTPError{503} POST(url(port); data="x")
  @test hits[] == 1
  hits, port = scripted(n -> n < 2 ? (503, ["Retry-After: 0"]) : (200, String[]))
  @test read(POST(url(port); data="x", retries=1), String) == "fine" && hits[] == 2
  # nor is a body that can't be re-read
  hits, port = scripted(n -> n < 2 ? (503, ["Retry-After: 0"]) : (200, String[]))
  @test_throws HTTPError{503} PUT(url(port); data=IOBuffer("x"))
  @test hits[] == 1
  # a client error is the answer, not a hiccup
  hits, port = scripted(n -> n < 2 ? (404, String[]) : (200, String[]))
  @test_throws HTTPError{404} GET(url(port))
  @test hits[] == 1
  # a dropped connection is retried
  hits, port = scripted(n -> n < 2 ? :drop : (200, String[]))
  @test read(GET(url(port)), String) == "fine" && hits[] == 2
  # a server asking for longer than a retry waits gets its error at once
  hits, port = scripted(n -> (429, ["Retry-After: 60"]))
  t, e = elapsed(() -> GET(url(port)))
  @test e isa HTTPError{429} && hits[] == 1 && t < 1
  # waits that would overrun `timeout` aren't taken
  hits, port = scripted(n -> (503, ["Retry-After: 2"]))
  t, e = elapsed(() -> GET(url(port); timeout=1))
  @test e isa HTTPError{503} && hits[] == 1 && t < 1
  # Retry-After is honoured
  hits, port = scripted(n -> n < 2 ? (503, ["Retry-After: 1"]) : (200, String[]))
  t = @elapsed GET(url(port))
  @test hits[] == 2 && t >= 1
  # backoff without Retry-After
  hits, port = scripted(n -> n < 2 ? (502, String[]) : (200, String[]))
  @test read(GET(url(port)), String) == "fine" && hits[] == 2
  # a slow server isn't asked again
  slowhits = Ref(0)
  _, slow = rawserver() do conn
    readhead(conn); slowhits[] += 1; sleep(3)
  end
  t, e = elapsed(() -> GET(url(slow); readtimeout=0.5))
  @test e isa TimeoutError && e.phase == :read && slowhits[] == 1
  # streamed: retried before `fn` sees a response, never after
  hits, port = scripted(n -> n < 2 ? (503, ["Retry-After: 0"]) : (200, String[]))
  calls = Ref(0)
  @test GET(res -> (calls[] += 1; read(res, String)), url(port)) == "fine"
  @test calls[] == 1 && hits[] == 2
  hits, port = scripted(n -> (200, String[]))
  @test_throws EOFError GET(res -> (calls[] += 1; throw(EOFError())), url(port))
  @test hits[] == 1
  # what counts as worth another go
  @test retryable(EOFError()) && !retryable(ArgumentError("x"))
  @test retryable(TimeoutError(:connect, 1, parseURI("http://x/"))) && !retryable(TimeoutError(:read, 1, parseURI("http://x/")))
end
