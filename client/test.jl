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
  @test_throws Response GET(":8000/status/400")
  @test_throws Response GET(":8000/status/404")
  @test_throws Response GET(":8000/status/500")
end

@testset "GET" begin
  data = parse(GET(":8000/get"))
  @test haskey(data, "headers")
  @test haskey(data, "origin")
  @test haskey(data, "url")
end

@testset "POST" begin
  res = write(POST(":8000/post"), MIME("application/json"), Dict("a"=>1))
  data = parse(res)
  @test data["json"] == Dict("a"=>1)
end

@testset "PUT" begin
  res = write(PUT(":8000/put"), MIME("application/json"), [1,2,3])
  @test parse(res)["json"] == [1,2,3]
end

@testset "DELETE" begin
  @test DELETE(":8000/delete").status == 200
end

@testset "anything" begin
  data = parse(GET(":8000/anything"))
  @test data["method"] == "GET"
  @test haskey(data, "headers")
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
end

@testset "redirects" begin
  @test GET(":8000/redirect/3").status == 200
  @test GET(":8000/relative-redirect/3").status == 200
  @test GET(":8000/absolute-redirect/3").status == 200
  @test GET(":8000/redirect-to?url=http%3A%2F%2Flocalhost%3A8000%2Fget").status == 200
end

@testset "Content-Encoding" begin
  @test parse(GET(":8000/gzip")) isa Dict
  @test parse(GET(":8000/gzip"))["gzipped"] == true
end

@testset "bytes" begin
  res = GET(":8000/bytes/16")
  @test length(read(res)) == 16
end

@testset "deny" begin
  res = GET(":8000/deny")
  @test occursin("YOU SHOULDN'T BE HERE", String(read(res)))
end

@testset "encoding/utf8" begin
  res = GET(":8000/encoding/utf8")
  @test res.status == 200
  body = String(read(res))
  @test occursin("UTF-8", body)
end

@testset "html" begin
  res = GET(":8000/html")
  @test res.status == 200
  @test occursin("text/html", res.meta["content-type"])
end

@testset "json" begin
  data = parse(GET(":8000/json"))
  @test haskey(data, "slideshow")
  @test data["slideshow"]["author"] == "Yours Truly"
end

@testset "robots.txt" begin
  res = GET(":8000/robots.txt")
  body = String(read(res))
  @test occursin("Disallow: /deny", body)
end

@testset "xml" begin
  res = GET(":8000/xml")
  @test occursin("application/xml", res.meta["content-type"])
end

@testset "base64" begin
  res = GET(":8000/base64/SFRUUEJpbiBpcyBhd2Vzb21l")
  @test String(read(res)) == "HTTPBin is awesome"
end

@testset "uuid" begin
  data = parse(GET(":8000/uuid"))
  @test occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", data["uuid"])
end

@testset "cache" begin
  res = GET(":8000/cache")
  @test res.status == 200
end

@testset "delay" begin
  res = GET(":8000/delay/0")
  @test res.status == 200
end

@testset "cookies" begin
  s = Session(":8000")
  @test parse(s["/cookies/set?a=1"]) == Dict("cookies"=>Dict("a"=>"1"))
  @test parse(s["/cookies/set?b=2"]) == Dict("cookies"=>Dict("a"=>"1","b"=>"2"))
  @test parse(s["/cookies"]) == Dict("cookies"=>Dict("a"=>"1","b"=>"2"))
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
