# The server should first be started with:
# `docker run -p 8000:80 kennethreitz/httpbin`
@use "github.com/jkroso/Rutherford.jl/test.jl" testset @test @catch
@use "github.com/jkroso/JSON.jl/write.jl"
@use "github.com/jkroso/JSON.jl/read.jl"
@use "./unchunk.jl" Unchunker
@use "../Header.jl" Header
@use "." GET PUT Response
@use "./Session.jl" Session

testset("errors based on response status code") do
  @test @catch(GET(":8000/status/400")) isa Response
end

testset("redirects") do
  @test GET(":8000/redirect/3").status == 200
  @test GET(":8000/relative-redirect/3").status == 200
  @test GET(":8000/absolute-redirect/3").status == 200
end

testset("Content-Encoding") do
  @test parse(GET(":8000/gzip")) isa Dict
end

testset("write") do
  @test parse(write(PUT(":8000/put"), MIME("application/json"), [1,2,3]))["json"] == [1,2,3]
end

testset("Session") do
  s = Session(":8000")
  @test parse(s["/cookies/set?a=1"]) == Dict("cookies"=>Dict("a"=>"1"))
  @test parse(s["/cookies/set?b=2"]) == Dict("cookies"=>Dict("a"=>"1","b"=>"2"))
end

testset("unchunk") do
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
