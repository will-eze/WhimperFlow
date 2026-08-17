APP_NAME := WhimperFlow
BUILD_DIR := .build/release
APP_BUNDLE := $(APP_NAME).app
RECORDER_NAME := WhimperRecorder
RECORDER_BUNDLE := $(RECORDER_NAME).app

# Code signing identity used for every bundle here.
#
# Defaults to "-" (ad-hoc), which is what caused the permissions failure mode
# this app has a whole UI for: TCC binds an ad-hoc grant to the bundle's
# cdhash, every rebuild changes the cdhash, so Microphone / Speech Recognition
# / Accessibility silently stop working after `make app` while System Settings
# still shows them switched on. Run `make signing-identity` once to create a
# stable self-signed identity; grants then survive rebuilds, because the
# signature names a certificate rather than one exact binary.
SIGNING_IDENTITY_NAME := WhimperFlow Dev
SIGNING_IDENTITY_FILE := .signing-identity
CODESIGN_IDENTITY ?= $(shell cat $(SIGNING_IDENTITY_FILE) 2>/dev/null || echo -)

.PHONY: build test app run eval eval-bundle eval-cli recorder record probe clean signing-identity

build:
	swift build -c release

test:
	swift test

# Offline WER measurement over Eval/clips (see Eval/README.md).
#
# Runs from an app bundle on purpose. `prepareCustomLanguageModel` binds the
# compiled model to a client identifier that an unbundled process doesn't own,
# so a plain `swift run` silently measures the text pipeline with NO custom
# language model attached. Use `make eval-cli` only when you want exactly that.
EVAL_NAME := whimpereval
EVAL_BUNDLE := $(EVAL_NAME).app
EVAL_REPORT := Eval/last-run.md

eval: eval-bundle
	@rm -f $(EVAL_REPORT)
	@open -W -n "$(CURDIR)/$(EVAL_BUNDLE)" --args \
		--clips "$(CURDIR)/Eval/clips" \
		--out "$(CURDIR)/$(EVAL_REPORT)" $(ARGS)
	@cat $(EVAL_REPORT)
	@echo ""
	@echo "(report also written to $(EVAL_REPORT))"

eval-bundle:
	swift build -c release --product $(EVAL_NAME)
	rm -rf $(EVAL_BUNDLE)
	mkdir -p $(EVAL_BUNDLE)/Contents/MacOS
	cp $(BUILD_DIR)/$(EVAL_NAME) $(EVAL_BUNDLE)/Contents/MacOS/$(EVAL_NAME)
	cp Resources/EvalInfo.plist $(EVAL_BUNDLE)/Contents/Info.plist
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(EVAL_BUNDLE)

# Unbundled run: no custom language model, text pipeline only.
eval-cli:
	swift run -c release $(EVAL_NAME) $(ARGS)

# Clip Recorder: records the eval test set into Eval/clips.
recorder:
	swift build -c release --product $(RECORDER_NAME)
	rm -rf $(RECORDER_BUNDLE)
	mkdir -p $(RECORDER_BUNDLE)/Contents/MacOS $(RECORDER_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(RECORDER_NAME) $(RECORDER_BUNDLE)/Contents/MacOS/$(RECORDER_NAME)
	cp Resources/RecorderInfo.plist $(RECORDER_BUNDLE)/Contents/Info.plist
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(RECORDER_BUNDLE)

record: recorder
	open $(RECORDER_BUNDLE)

# One-time setup: create a self-signed code signing identity in the login
# keychain and record it for every later `make app`.
#
# The point is the *designated requirement* codesign derives. Ad-hoc signing
# has no certificate to name, so the requirement pins the cdhash of one exact
# binary and TCC drops the app's permissions on every rebuild. Signing with a
# certificate makes the requirement "this bundle id, signed by this leaf",
# which every subsequent build still satisfies — so Microphone, Speech
# Recognition and Accessibility are granted once and stay granted.
#
# Uses /usr/bin/openssl explicitly: a Homebrew or conda openssl earlier on
# PATH is fine too, but this target should not depend on which one wins.
# The throwaway p12 gets a non-empty password ($$p12pw): macOS `security
# import` rejects an empty-password PKCS#12 with "MAC verification failed
# (wrong password?)", so pass: alone fails. The p12 lives in a temp dir wiped
# on exit, so the password guards nothing — it just has to be non-empty.
# Expect two keychain prompts — one to import the key, one the first time
# codesign uses it (choose "Always Allow").
signing-identity:
	@if security find-identity -v -p codesigning | grep -qF "$(SIGNING_IDENTITY_NAME)"; then \
		echo "Identity \"$(SIGNING_IDENTITY_NAME)\" already exists — reusing it."; \
	else \
		set -e; \
		tmp=$$(mktemp -d); \
		trap 'rm -rf "$$tmp"' EXIT; \
		p12pw=whimperflow; \
		/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
			-keyout "$$tmp/key.pem" -out "$$tmp/cert.pem" \
			-subj "/CN=$(SIGNING_IDENTITY_NAME)" \
			-addext "basicConstraints=critical,CA:false" \
			-addext "keyUsage=critical,digitalSignature" \
			-addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1; \
		/usr/bin/openssl pkcs12 -export -inkey "$$tmp/key.pem" -in "$$tmp/cert.pem" \
			-name "$(SIGNING_IDENTITY_NAME)" -out "$$tmp/id.p12" -passout "pass:$$p12pw" >/dev/null 2>&1; \
		security import "$$tmp/id.p12" -k "$$HOME/Library/Keychains/login.keychain-db" \
			-P "$$p12pw" -T /usr/bin/codesign >/dev/null; \
		security add-trusted-cert -r trustRoot -p codeSign \
			-k "$$HOME/Library/Keychains/login.keychain-db" "$$tmp/cert.pem"; \
		echo "Created code signing identity \"$(SIGNING_IDENTITY_NAME)\"."; \
	fi
	@echo "$(SIGNING_IDENTITY_NAME)" > $(SIGNING_IDENTITY_FILE)
	@echo ""
	@echo "Recorded in $(SIGNING_IDENTITY_FILE) — 'make app' will use it from now on."
	@echo "This build's permissions still belong to the old ad-hoc signature, so once:"
	@echo "  make app && rm -rf /Applications/$(APP_BUNDLE) && cp -R $(APP_BUNDLE) /Applications/"
	@echo "  tccutil reset Microphone com.whimperflow.app"
	@echo "  tccutil reset SpeechRecognition com.whimperflow.app"
	@echo "  tccutil reset Accessibility com.whimperflow.app"
	@echo "then relaunch and approve the prompts. Rebuilds after that keep them."

app: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE) — move it to /Applications if you like, then open it."

run: app
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) $(RECORDER_BUNDLE) $(PROBE_BUNDLE) $(EVAL_BUNDLE)

# Diagnostic for the live (streaming) recognition path. Must run from inside a
# bundle: an unbundled process gets kAFAssistantErrorDomain 1107.
PROBE_BUNDLE := SpeechProbe.app
probe:
	swift build -c release --product SpeechProbe
	rm -rf $(PROBE_BUNDLE)
	mkdir -p $(PROBE_BUNDLE)/Contents/MacOS
	cp $(BUILD_DIR)/SpeechProbe $(PROBE_BUNDLE)/Contents/MacOS/SpeechProbe
	cp Resources/ProbeInfo.plist $(PROBE_BUNDLE)/Contents/Info.plist
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(PROBE_BUNDLE)
	./$(PROBE_BUNDLE)/Contents/MacOS/SpeechProbe $(CLIP) $(PADS)
