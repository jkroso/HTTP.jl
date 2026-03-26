# Start the Autobahn fuzzing server first:
#   docker run -it --rm \
#     -v "$(pwd)/client/test/autobahn:/config" \
#     -v "$(pwd)/client/test/autobahn/reports:/reports" \
#     -p 9001:9001 \
#     crossbario/autobahn-testsuite \
#     wstest -m fuzzingserver -s /config/fuzzingserver.json

using Test
@use "../websocket.jl" WebSocket send receive Message TEXT BINARY CLOSE

const SERVER = "ws://localhost:9001"
const AGENT = "HTTP.jl"

ws = WebSocket("$SERVER/getCaseCount")
n = parse(Int, String(receive(ws)))
close(ws)

for i in 1:n
  print("\rRunning case $i/$n")
  local ws = WebSocket("$SERVER/runCase?case=$i&agent=$AGENT")
  try
    while true
      msg = receive(ws)
      msg.opcode == CLOSE && break
      msg.opcode == TEXT ? send(ws, String(msg)) : send(ws, msg.data)
    end
  catch end
  try close(ws) catch end
end
println()

ws = WebSocket("$SERVER/updateReports?agent=$AGENT")
close(ws)

@use "github.com/jkroso/JSON.jl/read.jl"
report_path = joinpath(@__DIR__, "autobahn", "reports", "clients", "index.json")
report = open(io->parse(MIME("application/json"), io), report_path)
results = report[AGENT]
passed = count(r->r["behavior"] in ("OK", "NON-STRICT", "INFORMATIONAL"), values(results))
println("Passed: $passed/$(length(results))")

@testset "WebSocket (Autobahn)" begin
  for (case_id, result) in sort(collect(results), by=first)
    @testset "$case_id" begin
      @test result["behavior"] in ("OK", "NON-STRICT", "INFORMATIONAL")
    end
  end
end
