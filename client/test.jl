# The server should first be started with:
# `docker run -p 8000:80 kennethreitz/httpbin`
using Test
@use "github.com/jkroso/JSON.jl/write.jl"
@use "github.com/jkroso/JSON.jl/read.jl"
@use "./unchunk.jl" Unchunker
@use "../Header.jl" Header
@use "." GET POST PUT DELETE Response
@use "./Session.jl" Session

@testset "status codes" begin
  @test GET(":8000/status/200").status == 200
  @test GET(":8000/status/201").status == 201
  @test GET(":8000/status/204").status == 204
  @test_throws Response GET(":8000/status/400")
  @test_throws Response GET(":8000/status/404")
  @test_throws Response GET(":8000/status/500")
end

@testset "GET" begin
  data = parse(GET(":8000/get"))
  @test haskey(data, "headers")
  @test haskey(data, "origin")
  @test haskey(data, "url")
  @test haskey(data, "args")
end

@testset "POST" begin
  res = write(POST(":8000/post"), MIME("application/json"), Dict("a"=>1))
  data = parse(res)
  @test data["json"] == Dict("a"=>1)
  @test data["headers"]["Content-Type"] == "application/json"
end

@testset "PUT" begin
  res = write(PUT(":8000/put"), MIME("application/json"), [1,2,3])
  @test parse(res)["json"] == [1,2,3]
end

@testset "DELETE" begin
  data = parse(DELETE(":8000/delete"))
  @test haskey(data, "headers")
  @test haskey(data, "origin")
end

@testset "anything" begin
  data = parse(GET(":8000/anything"))
  @test data["method"] == "GET"
  @test haskey(data, "headers")
  @test haskey(data, "url")
end

@testset "ip" begin
  data = parse(GET(":8000/ip"))
  @test haskey(data, "origin")
  @test data["origin"] isa String
end

@testset "user-agent" begin
  data = parse(GET(":8000/user-agent"))
  @test startswith(data["user-agent"], "Julia/")
end

@testset "headers" begin
  data = parse(GET(":8000/headers"))
  @test data["headers"]["Host"] == "localhost"
  @test startswith(data["headers"]["User-Agent"], "Julia/")
end

@testset "response-headers" begin
  res = GET(":8000/response-headers?X-Foo=bar")
  @test res.meta["x-foo"] == "bar"
  data = parse(res)
  @test data["X-Foo"] == "bar"
end

@testset "redirects" begin
  @test GET(":8000/redirect/1").status == 200
  @test GET(":8000/redirect/3").status == 200
  @test GET(":8000/relative-redirect/3").status == 200
  @test GET(":8000/absolute-redirect/3").status == 200
  @test GET(":8000/redirect-to?url=http%3A%2F%2Flocalhost%3A8000%2Fget").status == 200
end

@testset "Content-Encoding" begin
  data = parse(GET(":8000/gzip"))
  @test data isa Dict
  @test data["gzipped"] == true
  data = parse(GET(":8000/deflate"))
  @test data isa Dict
  @test data["deflated"] == true
end

@testset "bytes" begin
  @test length(read(GET(":8000/bytes/16"))) == 16
  @test length(read(GET(":8000/bytes/64"))) == 64
  @test length(read(GET(":8000/bytes/0"))) == 0
end

@testset "stream-bytes" begin
  res = GET(":8000/stream-bytes/32")
  @test res.status == 200
end

@testset "stream" begin
  res = GET(":8000/stream/3")
  @test res.status == 200
  @test occursin("application/json", res.meta["content-type"])
end

@testset "delay" begin
  @test GET(":8000/delay/0").status == 200
end

@testset "drip" begin
  res = GET(":8000/drip?numbytes=5&duration=0&delay=0")
  @test res.status == 200
  @test length(read(res)) == 5
end

@testset "range" begin
  body = String(read(GET(":8000/range/26")))
  @test body == "abcdefghijklmnopqrstuvwxyz"
end

@testset "deny" begin
  @test occursin("YOU SHOULDN'T BE HERE", String(read(GET(":8000/deny"))))
end

@testset "encoding/utf8" begin
  res = GET(":8000/encoding/utf8")
  @test res.status == 200
  @test occursin("UTF-8", String(read(res)))
end

@testset "html" begin
  res = GET(":8000/html")
  @test res.status == 200
  @test occursin("text/html", res.meta["content-type"])
  @test occursin("<html>", String(read(res)))
end

@testset "json" begin
  data = parse(GET(":8000/json"))
  @test haskey(data, "slideshow")
  @test data["slideshow"]["author"] == "Yours Truly"
  @test data["slideshow"]["title"] == "Sample Slide Show"
end

@testset "robots.txt" begin
  body = String(read(GET(":8000/robots.txt")))
  @test occursin("User-agent: *", body)
  @test occursin("Disallow: /deny", body)
end

@testset "xml" begin
  res = GET(":8000/xml")
  @test occursin("application/xml", res.meta["content-type"])
  @test occursin("<?xml", String(read(res)))
end

@testset "base64" begin
  @test String(read(GET(":8000/base64/SFRUUEJpbiBpcyBhd2Vzb21l"))) == "HTTPBin is awesome"
end

@testset "uuid" begin
  data = parse(GET(":8000/uuid"))
  @test occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", data["uuid"])
end

@testset "links" begin
  body = String(read(GET(":8000/links/3/0")))
  @test occursin("<a href=", body)
  @test occursin("text/html", GET(":8000/links/3/0").meta["content-type"])
end

@testset "image" begin
  @test occursin("image/png", GET(":8000/image/png").meta["content-type"])
  @test occursin("image/jpeg", GET(":8000/image/jpeg").meta["content-type"])
  @test occursin("image/svg+xml", GET(":8000/image/svg").meta["content-type"])
  @test occursin("image/webp", GET(":8000/image/webp").meta["content-type"])
  @test length(read(GET(":8000/image/png"))) > 0
end

@testset "image content negotiation" begin
  res = GET(":8000/image", meta=Header("accept"=>"image/png"))
  @test occursin("image/png", res.meta["content-type"])
  res = GET(":8000/image", meta=Header("accept"=>"image/jpeg"))
  @test occursin("image/jpeg", res.meta["content-type"])
end

@testset "basic-auth" begin
  res = GET(":8000/basic-auth/user/passwd", meta=Header("authorization"=>"Basic dXNlcjpwYXNzd2Q="))
  data = parse(res)
  @test data["authenticated"] == true
  @test data["user"] == "user"
  @test_throws Response GET(":8000/basic-auth/user/passwd")
end

@testset "hidden-basic-auth" begin
  res = GET(":8000/hidden-basic-auth/user/passwd", meta=Header("authorization"=>"Basic dXNlcjpwYXNzd2Q="))
  data = parse(res)
  @test data["authenticated"] == true
  @test_throws Response GET(":8000/hidden-basic-auth/user/passwd")
end

@testset "bearer" begin
  res = GET(":8000/bearer", meta=Header("authorization"=>"Bearer mytoken"))
  data = parse(res)
  @test data["authenticated"] == true
  @test data["token"] == "mytoken"
  @test_throws Response GET(":8000/bearer")
end

@testset "etag" begin
  res = GET(":8000/etag/test")
  @test res.status == 200
  @test res.meta["etag"] == "test"
end

@testset "cache" begin
  @test GET(":8000/cache").status == 200
  res = GET(":8000/cache/10")
  @test res.status == 200
  @test res.meta["cache-control"] == "public, max-age=10"
end

@testset "cookies" begin
  s = Session(":8000")
  @test parse(s["/cookies/set?a=1"]) == Dict("cookies"=>Dict("a"=>"1"))
  @test parse(s["/cookies/set?b=2"]) == Dict("cookies"=>Dict("a"=>"1","b"=>"2"))
  @test parse(s["/cookies"]) == Dict("cookies"=>Dict("a"=>"1","b"=>"2"))
  close(s)
end

@testset "cookies/set/{name}/{value}" begin
  s = Session(":8000")
  parse(s["/cookies/set/foo/bar"])
  data = parse(s["/cookies"])
  @test data["cookies"]["foo"] == "bar"
  close(s)
end

@testset "unchunk" begin
  io = PipeBuffer()
  write(io, string(2, base=16), "\r\n")
  write(io, "ab\r\n")
  write(io, string(1, base=16), "\r\n")
  write(io, "c\r\n")
  write(io, string(10, base=16), "\r\n")
  write(io, string(('d':'m')...), "\r\n")
  write(io, string(13, base=16), "\r\n")
  write(io, string(('n':'z')...), "\r\n")
  write(io, string(0, base=16), "\r\n")
  write(io, "A: b\r\n")
  write(io, "B: c\r\n")
  write(io, "\r\n")
  body = Unchunker(io)
  @test read(body) == UInt8[('a':'z')...]
  @test wait(body.trailers) == Header("b"=>"c", "a"=>"b")
end
