@require "github.com/jkroso/parse-json@4d9f46b" parse => parseJSON
@require "./main" GET

test("errors based on response status code") do
  @test nothing != @catch GET(":8000/status/400")
end

test("redirects") do
  @test GET(":8000/redirect/3").status == 200
  @test GET(":8000/relative-redirect/3").status == 200
  @test GET(":8000/absolute-redirect/3").status == 200
end

test("Content-Encoding") do
  @test parseJSON(GET(":8000/gzip")) != nothing
end
