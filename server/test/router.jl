using Test
@use ".." Request Response
@use "../router" Router @route register! compile matchpath segments default_router

req(s) = Request(s * " HTTP/1.1\r\n\r\n")

# routes are defined at module top level (verb methods dispatch on Request{verb})
const app = Router()

const pinghandler = @route app "/ping"
pinghandler(::Request{:GET}) = Response(200, "pong")

const signhandler = @route app "/signup"     # one path, two verbs via dispatch
signhandler(::Request{:POST})    = Response(200, "ok")
signhandler(::Request{:OPTIONS}) = Response(204, "")

const usrhandler = @route app "/users/:id"
usrhandler(req::Request{:GET}, p) = Response(200, "user " * p["id"])

const custom = Router(notfound = r -> Response(404, "nf"), notallowed = r -> Response(405, "na"))
const xhandler = @route custom "/x"
xhandler(::Request{:POST}) = Response(200, "ok")

const dhandler = @route "/dping"             # one-arg form → default router
dhandler(::Request{:GET}) = Response(200, "dpong")

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
    @test matchpath(compile("/"), segments("/")) == Dict()
  end

  @testset "@route dispatch" begin
    @test app(req("GET /ping")).data == "pong"
    @test app(req("POST /signup")).data == "ok"
    @test app(req("OPTIONS /signup")).status == 204   # same path, different verb
    @test app(req("GET /users/42")).data == "user 42"
    @test app(req("DELETE /ping")).status == 405       # path exists, no DELETE method
    @test app(req("GET /nope")).status == 404
  end

  @testset "custom 404/405 + default router" begin
    @test custom(req("GET /missing")).data == "nf"
    @test custom(req("GET /x")).data == "na"           # path exists, wrong verb
    @test default_router()(req("GET /dping")).data == "dpong"
  end
end
