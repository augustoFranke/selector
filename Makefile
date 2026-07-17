APP_NAME := Selector
BUNDLE_ID := dev.local.Selector
CONFIGURATION := release
BUNDLE_DIR := build/$(APP_NAME).app
CONTENTS_DIR := $(BUNDLE_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS

.PHONY: app build run run-api reset-ax run-fresh clean

app: build
	mkdir -p "$(MACOS_DIR)"
	cp -f ".build/$(CONFIGURATION)/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	cp -f "Resources/Info.plist" "$(CONTENTS_DIR)/Info.plist"
	codesign --force --deep --sign "Apple Development" "$(BUNDLE_DIR)"
	@echo "Built $(BUNDLE_DIR)"

build:
	swift build -c $(CONFIGURATION)

run: app
	open "$(BUNDLE_DIR)"

# Launch via `open` so launchd starts the app (and TCC attributes Screen
# Recording / Accessibility prompts to Selector, not the parent Terminal).
# `open` does not forward shell env, so we push the keys into the launchd
# user session first; the launched app inherits them.
run-api: app
	@if [ -z "$$GROQ_API_KEY" ]; then \
		echo "warning: GROQ_API_KEY is not set in this shell" >&2; \
	fi
	@launchctl setenv GROQ_API_KEY "$$GROQ_API_KEY"
	@if [ -n "$$SELECTOR_GROQ_MODEL" ]; then launchctl setenv SELECTOR_GROQ_MODEL "$$SELECTOR_GROQ_MODEL"; fi
	@if [ -n "$$SELECTOR_GROQ_VISION_MODEL" ]; then launchctl setenv SELECTOR_GROQ_VISION_MODEL "$$SELECTOR_GROQ_VISION_MODEL"; fi
	open "$(BUNDLE_DIR)"

# Wipes the (possibly stale) Accessibility grant so the next launch prompts
# fresh. Only needed when System Settings shows Selector allowed but capture
# stays untrusted — not on every rebuild, since the signing identity is stable.
reset-ax:
	-pkill -x $(APP_NAME)
	tccutil reset Accessibility $(BUNDLE_ID)

run-fresh: reset-ax run

clean:
	rm -rf .build build
