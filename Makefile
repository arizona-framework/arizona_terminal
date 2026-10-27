.PHONY: all compile compile-test fmt check test cover doc term-demo ssh-server ssh-client clean

# SSH terminal demo (make ssh-server / ssh-client) connection settings; must
# match the constants in scripts/ssh_server.escript.
SSH_DEMO_PORT := 2222
SSH_DEMO_USER := arizona

all: compile

compile:
	rebar3 compile

compile-test:
	rebar3 as test compile

fmt:
	rebar3 fmt

check:
	rebar3 fmt --check
	rebar3 lint
	rebar3 xref
	rebar3 hank
	rebar3 dialyzer

test:
	rebar3 test

cover: test
	rebar3 check_cover

doc:
	rebar3 ex_doc

# Interactive terminal demo: a live Arizona view rendered in an ANSI terminal
# with no HTTP server. Needs a real TTY. Press q to quit.
# Compile under the test profile so the demo view fixture is on the path.
term-demo: compile-test
	./scripts/term_demo.escript

# SSH terminal demo: the same live view as term-demo, served over SSH to a
# remote terminal. Run `make ssh-server` in one shell and `make ssh-client` in
# another. Dev-only host key + fixed password.
ssh-server: compile-test
	./scripts/ssh_server.escript

ssh-client:
	ssh -p $(SSH_DEMO_PORT) \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		$(SSH_DEMO_USER)@localhost

clean:
	rebar3 clean
