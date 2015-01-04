
dependencies: dependencies.json
	@packin install --folder $@ --meta $<

test: dependencies
	@$</jest/bin/jest test/index.jl

server: test/node_modules
	@node test/server.js

test/node_modules: test/package.json
	@cd test && npm install
	@touch $@

.PHONY: test
