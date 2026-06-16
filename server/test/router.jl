using Test
@use ".." Request Response
@use "../router" Router register! compile matchpath segments

req(s) = Request(s * " HTTP/1.1\r\n\r\n")

@testset "Router" begin
  @testset "path matching" begin
    @test matchpath(compile("/api/ping"), segments("/api/ping")) == Dict()
    @test matchpath(compile("/api/ping"), segments("/api/pong")) === nothing
    @test matchpath(compile("/users/:id"), segments("/users/42")) == Dict("id" => "42")
    @test matchpath(compile("/users/{id}"), segments("/users/42")) == Dict("id" => "42")
    @test matchpath(compile("/users/:id"), segments("/users")) === nothing
    @test matchpath(compile("/users/:id"), segments("/users/42/x")) === nothing
    @test matchpath(compile("/a/*/c"), segments("/a/b/c")) == Dict()
    @test matchpath(compile("/a/*/c"), segments("/a/c")) === nothing
    @test matchpath(compile("/static/**"), segments("/static/a/b"))["rest"] == "a/b"
    @test matchpath(compile("/static/**"), segments("/static"))["rest"] == ""
    @test matchpath(compile("/"), segments("/")) == Dict()
  end

  @testset "dispatch" begin
    r = Router()
    register!(r, "GET", "/ping", req -> Response(200, "pong"))
    register!(r, "POST", "/feedback", req -> Response(200, "thanks"))
    register!(r, "GET", "/users/:id") do req, params
      Response(200, "user " * params["id"])
    end

    @test r(req("GET /ping")).data == "pong"
    @test r(req("POST /feedback")).data == "thanks"
    @test r(req("GET /users/42")).data == "user 42"
    @test r(req("GET /feedback")).status == 405   # path exists, wrong method
    @test r(req("GET /nope")).status == 404        # no such path
  end

  @testset "custom 404/405" begin
    r = Router(notfound = req -> Response(404, "nope"),
               notallowed = req -> Response(405, "nah"))
    register!(r, "POST", "/x", req -> Response(200, "ok"))
    @test r(req("GET /missing")).data == "nope"
    @test r(req("GET /x")).data == "nah"
  end
end
