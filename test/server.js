var app = require("express")()
var zlib = require("zlib")

app.use(require("morgan")("dev"))
app.use(require("errorhandler")())

var subject = "some long long long long string"

app.get("/gzip", function(req, res, next){
  zlib.gzip(subject, function(err, buf){
    if (err) return next(err)
    res.set("Content-Type", "text/plain")
    res.set("Content-Encoding", "gzip")
    res.send(buf)
  })
})

app.get("/", function(req, res){
  res.send("home")
})

app.post("/echo", function(req, res){
  res.writeHead(200, req.headers)
  req.pipe(res)
})

app.get("/json", function(req, res){
  res.type("json")
  res.send(JSON.stringify({name: "jake"}))
})

app.get("/login", function(req, res){
  res.type("html")
  res.send("<form id=\"login\"></form>")
})

app.get("/redirect", function(req, res){
  res.redirect("/redirect/2")
})

app.get("/redirect/2", function(req, res){
  res.send("Oh damn you found me")
})

app.get("/loop/1", function(req, res){
  res.redirect("/loop/2")
})

app.get("/loop/2", function(req, res){
  res.redirect("/loop/1")
})

app.get("/links", function(req, res){
  res.header("Link", "<https://api.github.com/repos/visionmedia/mocha/issues?page=2>; rel=\"next\"")
  res.end()
})

app.get("/error", function(req, res){
  res.status(500).send("boom")
})

app.get("/timeout/:ms", function(req, res){
  var ms = parseInt(req.params.ms, 10)
  setTimeout(function(){
    res.send("hello")
  }, ms)
})

app.listen(8000, function(){
  console.log("server listening on http://localhost:8000")
})
