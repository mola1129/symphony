.PHONY: help all setup deps build run fmt fmt-check lint test coverage ci dialyzer e2e

MIX ?= mix
WORKFLOW ?= ./WORKFLOW.md
PORT ?= 4000
LOGS_ROOT ?=
RUN_ARGS ?=

ACK_FLAG := --i-understand-that-this-will-be-running-without-the-usual-guardrails
PORT_ARG = $(if $(PORT),--port $(PORT),)
LOGS_ROOT_ARG = $(if $(LOGS_ROOT),--logs-root $(LOGS_ROOT),)

help:
	@echo "Targets: setup, deps, build, run, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

run: build
	./bin/symphony $(ACK_FLAG) $(LOGS_ROOT_ARG) $(PORT_ARG) $(RUN_ARGS) $(WORKFLOW)

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
