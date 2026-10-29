PREFIX ?= $(shell [ -w /usr/local/bin ] && echo /usr/local || echo $(HOME)/.local)
CORPUS ?=
CORPUS_OUT ?= .build/corpus

.PHONY: build test install corpus template

build:
	swift build -c release

test:
	swift test

# Re-embed Sources/XcpurgeKit/Resources/report.html after editing it (ReportTemplateTests catches drift).
template:
	Scripts/embed-report-template.sh

install: build
	mkdir -p $(PREFIX)/bin
	cp .build/release/xcpurge $(PREFIX)/bin/xcpurge
	@echo "installed $(PREFIX)/bin/xcpurge"

# Read-only scans of real projects: make corpus CORPUS="~/src/AppA ~/src/AppB"
corpus: build
	@test -n "$(CORPUS)" || (echo 'set CORPUS="path1 path2 ..."' && exit 2)
	@mkdir -p $(CORPUS_OUT)
	@for repo in $(CORPUS); do \
		name=$$(basename $$repo); \
		start=$$(date +%s); \
		.build/release/xcpurge scan $$repo --format json > $(CORPUS_OUT)/$$name.json; \
		.build/release/xcpurge scan $$repo --format json > $(CORPUS_OUT)/$$name.2.json; \
		cmp -s $(CORPUS_OUT)/$$name.json $(CORPUS_OUT)/$$name.2.json && det=deterministic || det=NONDETERMINISTIC; \
		echo "$$name: $$(( $$(date +%s) - start ))s for 2 runs, $$det, $$(grep -c '"confidence" : "high"' $(CORPUS_OUT)/$$name.json) high"; \
	done
