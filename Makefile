# SousLens — one entry point for checks and dev loops. See CLAUDE.md.
SHELL := /bin/bash
SIM ?= iPhone 15
# Newest installed runtime that has a simulator named $(SIM). A bare `name=` resolves to OS:latest,
# which fails whenever the newest runtime lacks that model (e.g. iPhone 15 only ships with iOS 17.x).
SIM_OS ?= $(shell ios/scripts/sim-os.sh "$(SIM)")

.PHONY: check backend-check ios-check ios-smoke env db-up db-down backend-dev seed ios-project

check: backend-check ios-check

backend-check:
	$(MAKE) -C backend check

env:
	$(MAKE) -C backend env

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

# Ad-hoc signing (identity "-") needs no certificate or profile, but unlike CODE_SIGNING_ALLOWED=NO
# it embeds the keychain-access-groups entitlement, which the simulator Keychain requires (-34018).
ios-check: ios-project
	cd ios && xcodebuild test -project SousLens.xcodeproj -scheme SousLens \
		-destination 'platform=iOS Simulator,name=$(SIM),OS=$(SIM_OS)' \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO -quiet

# Live smoke: fresh install → two-step dev sign-in (code read from the backend log) → seeded
# recipe. Needs `make backend-dev` running with its log at SMOKE_LOG (default below).
SMOKE_LOG ?= $(CURDIR)/backend/dev.log
ios-smoke: ios-project
	cd ios && xcrun simctl uninstall "$$(xcrun simctl list devices available -j | python3 -c "import json,sys; d=json.load(sys.stdin); print([x['udid'] for k,v in d['devices'].items() if k.endswith('iOS-$(subst .,-,$(SIM_OS))') for x in v if x['name']=='$(SIM)'][0])")" com.souslens.ios 2>/dev/null; \
	xcodebuild test -project SousLens.xcodeproj -scheme SousLensSmoke \
		-destination 'platform=iOS Simulator,name=$(SIM),OS=$(SIM_OS)' \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
		SOUSLENS_SMOKE_LOG="$(SMOKE_LOG)" -quiet
