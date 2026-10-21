# SousLens — one entry point for checks and dev loops. See CLAUDE.md.
SHELL := /bin/bash
SIM ?= iPhone 15

.PHONY: check backend-check ios-check db-up db-down backend-dev seed ios-project

check: backend-check ios-check

backend-check:
	$(MAKE) -C backend check

db-up:
	$(MAKE) -C backend db-up

db-down:
	$(MAKE) -C backend db-down

backend-dev:
	$(MAKE) -C backend dev

seed:
	$(MAKE) -C backend seed

ios-project:
	cd ios && xcodegen generate

ios-check: ios-project
	cd ios && xcodebuild test -project SousLens.xcodeproj -scheme SousLens \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		CODE_SIGNING_ALLOWED=NO -quiet
