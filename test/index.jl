@require "parse-json"
@require ".." GET Response

suite("default domains") do
  @test readall(GET("http://localhost:8000").data) == "home"
  @test readall(GET("localhost:8000").data) == "home"
  @test readall(GET(":8000").data) == "home"
end

suite("Content-Type based parsing") do
  @test GET(":8000/json").data == {"name" => "jake"}
end

suite("errors based on response status code") do
  @test_throws Response GET(":8000/error")
end

suite("redirects") do
  @test readall(GET(":8000/redirect").data) == "Oh damn you found me"
  @test_throws ErrorException GET(":8000/loop/1")
end

suite("Content-Encoding") do
  r = GET(":8000/gzip")
  @test readall(r.data) == "some long long long long string"
  @test r.meta["Content-Length"] == "31"
end
