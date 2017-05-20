@require "github.com/jkroso/parse-json.jl"
@require "." GET

testset("errors based on response status code") do
  @test nothing != @catch GET(":8000/status/400")
end

testset("redirects") do
  @test GET(":8000/redirect/3").status == 200
  @test GET(":8000/relative-redirect/3").status == 200
  @test GET(":8000/absolute-redirect/3").status == 200
end

testset("Content-Encoding") do
  @test parse(MIME("application/json"), GET(":8000/gzip")) != nothing
end
