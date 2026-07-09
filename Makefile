SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

APP_DIR := $(CURDIR)/codex-app
NEXT_APP_DIR := $(CURDIR)/codex-app-next
REBUILD_REPORT_DIR := $(CURDIR)/dist-next/rebuild
UPSTREAM_INTEL_CANDIDATE ?= $(strip $(DMG))
UPSTREAM_INTEL_HOST_CANDIDATE := $(if $(strip $(UPSTREAM_INTEL_CANDIDATE)),$(UPSTREAM_INTEL_CANDIDATE),$(CURDIR)/Codex.dmg)
UPSTREAM_INTEL_BASELINE ?=
UPSTREAM_INTEL_PATCH_REPORT ?= $(REBUILD_REPORT_DIR)/patch-report.json
UPSTREAM_INTEL_IMAGE ?= codex-desktop-linux-devcontainer:local
PACKAGE_NAME := codex-desktop
DEV_APP_ID ?= codex-cua-lab
DEV_APP_NAME ?= Codex CUA Lab
DEV_APP_DIR ?= $(CURDIR)/$(DEV_APP_ID)-app
DEV_APP_BIN ?= $(CURDIR)/bin/$(DEV_APP_ID)
.DEFAULT_GOAL := help

.PHONY: help inspect-upstream inspect-upstream-intel inspect-upstream-intel-devcontainer build-app build-app-fresh rebuild-next run-app build-dev-app run-dev-app appimage clean-dist

help:
	@printf '\nCodex Desktop Linux Make Targets\n\n'
	@printf '  %-22s %s\n' "make build-app" "Run install.sh and regenerate codex-app/ (reuses cached Codex.dmg)"
	@printf '  %-22s %s\n' "make build-app-fresh" "Remove cached Codex.dmg and regenerate codex-app/"
	@printf '  %-22s %s\n' "make inspect-upstream" "Inspect a DMG and write rebuild reports without changing codex-app/"
	@printf '  %-22s %s\n' "make inspect-upstream-intel" "Inventory protected upstream DMG surfaces and write drift reports"
	@printf '  %-22s %s\n' "make inspect-upstream-intel-devcontainer" "Run upstream DMG intelligence inside the devcontainer image"
	@printf '  %-22s %s\n' "make rebuild-next" "Build a side-by-side candidate in codex-app-next/"
	@printf '  %-22s %s\n' "make appimage" "Build the AppImage into dist/"
	@printf '  %-22s %s\n' "make run-app" "Launch the local generated Electron app from codex-app/"
	@printf '  %-22s %s\n' "make build-dev-app" "Build a side-by-side test app with a distinct app id/bin"
	@printf '  %-22s %s\n' "make run-dev-app" "Launch the side-by-side test app"
	@printf '  %-22s %s\n' "make clean-dist" "Remove generated dist/ artifacts"
	@printf '\nVariables:\n\n'
	@printf '  %-22s %s\n' "DMG=/path/file.dmg" "Override the DMG; commands otherwise auto-find ./Codex.dmg"
	@printf '  %-22s %s\n' "UPSTREAM_INTEL_BASELINE=..." "Optional known-good DMG/.app; defaults to ./Codex.dmg when different"
	@printf '  %-22s %s\n' "UPSTREAM_INTEL_PATCH_REPORT=..." "Optional patch-report.json folded into upstream intelligence drift"
	@printf '  %-22s %s\n' "UPSTREAM_INTEL_IMAGE=..." "Docker image for make inspect-upstream-intel-devcontainer"
	@printf '  %-22s %s\n' "NEXT_APP_DIR=..." "Override side-by-side rebuild candidate directory"
	@printf '  %-22s %s\n' "APP_DIR=..." "Override final app directory"
	@printf '  %-22s %s\n' "REBUILD_REPORT_DIR=..." "Override inspect/rebuild report output directory"
	@printf '  %-22s %s\n' "DEV_APP_ID=..." "Override side-by-side test app id/bin (default: codex-cua-lab)"
	@printf '  %-22s %s\n' "DEV_APP_NAME=..." "Override side-by-side test app display name"
	@printf '  %-22s %s\n' "PACKAGE_VERSION=..." "Override the AppImage package version"
	@printf '  %-22s %s\n' "APPIMAGETOOL=..." "Override the appimagetool executable for make appimage"
	@printf '  %-22s %s\n' "APPIMAGE_UPDATE_INFO=..." "Embed AppImage update info (gh-releases-zsync|...). Leave unset for local dev builds."
	@printf '\nExamples:\n\n'
	@printf '  %s\n' "make build-app DMG=/tmp/Codex.dmg"
	@printf '  %s\n' "make build-app-fresh"
	@printf '  %s\n' "make inspect-upstream DMG=/tmp/Codex.dmg"
	@printf '  %s\n' "make inspect-upstream-intel DMG=/tmp/Codex-new.dmg"
	@printf '  %s\n' "make inspect-upstream-intel-devcontainer"
	@printf '  %s\n' "make inspect-upstream-intel-devcontainer DMG=/tmp/Codex-new.dmg"
	@printf '  %s\n' "make rebuild-next DMG=/tmp/Codex.dmg"
	@printf '  %s\n' "make run-app"
	@printf '  %s\n' "make build-dev-app"
	@printf '  %s\n' "./bin/codex-cua-lab"
	@printf '  %s\n\n' "make appimage PACKAGE_VERSION=2026.05.18.073012+ab12cd34"

inspect-upstream:
	@echo "[make] Inspecting upstream DMG"
	./install.sh --inspect --report-dir "$(REBUILD_REPORT_DIR)" "$(DMG)"

inspect-upstream-intel:
	@echo "[make] Building upstream DMG intelligence report"
	@args=(--candidate "$(UPSTREAM_INTEL_HOST_CANDIDATE)"); \
	if [ -n "$(UPSTREAM_INTEL_BASELINE)" ]; then \
		args+=("--baseline" "$(UPSTREAM_INTEL_BASELINE)"); \
	fi; \
	if [ -f "$(UPSTREAM_INTEL_PATCH_REPORT)" ]; then \
		args+=("--patch-report" "$(UPSTREAM_INTEL_PATCH_REPORT)"); \
	fi; \
	node scripts/dev/upstream-dmg-intel.js "$${args[@]}"

inspect-upstream-intel-devcontainer:
	@echo "[make] Building upstream DMG intelligence report in devcontainer"
	@args=(--image "$(UPSTREAM_INTEL_IMAGE)"); \
	if [ -n "$(UPSTREAM_INTEL_CANDIDATE)" ]; then \
		args+=("--candidate" "$(UPSTREAM_INTEL_CANDIDATE)"); \
	fi; \
	if [ -n "$(UPSTREAM_INTEL_BASELINE)" ]; then \
		args+=("--baseline" "$(UPSTREAM_INTEL_BASELINE)"); \
	fi; \
	if [ -f "$(UPSTREAM_INTEL_PATCH_REPORT)" ]; then \
		args+=("--patch-report" "$(UPSTREAM_INTEL_PATCH_REPORT)"); \
	fi; \
	scripts/dev/upstream-dmg-intel-devcontainer "$${args[@]}"

build-app:
	@echo "[make] Regenerating codex-app from DMG"
	./install.sh "$(DMG)"

build-app-fresh:
	@echo "[make] Regenerating codex-app from fresh DMG"
	./install.sh --fresh "$(DMG)"

rebuild-next:
	@echo "[make] Building side-by-side rebuild candidate"
	CODEX_INSTALL_DIR="$(NEXT_APP_DIR)" \
	CODEX_PATCH_REPORT_JSON="$(REBUILD_REPORT_DIR)/patch-report.json" \
	CODEX_REBUILD_REPORT_JSON="$(REBUILD_REPORT_DIR)/rebuild-report.json" \
	REBUILD_REPORT_DIR="$(REBUILD_REPORT_DIR)" \
		./install.sh "$(DMG)"
	@echo "[make] Candidate app: $(NEXT_APP_DIR)"
	@echo "[make] Rebuild report: $(REBUILD_REPORT_DIR)/rebuild-report.json"

run-app:
	@echo "[make] Launching local Electron app"
	@[ -x "$(APP_DIR)/start.sh" ] || { echo "[make] Missing launcher: $(APP_DIR)/start.sh. Run make build-app first." >&2; exit 1; }
	"$(APP_DIR)/start.sh"

build-dev-app:
	@echo "[make] Building side-by-side Electron app as $(DEV_APP_ID)"
	CODEX_APP_ID="$(DEV_APP_ID)" \
	CODEX_APP_DISPLAY_NAME="$(DEV_APP_NAME)" \
	CODEX_INSTALL_DIR="$(DEV_APP_DIR)" \
		./install.sh "$(DMG)"
	@mkdir -p "$(CURDIR)/bin"
	@ln -sfn "$$(realpath --relative-to="$$(dirname "$(DEV_APP_BIN)")" "$(DEV_APP_DIR)/start.sh")" "$(DEV_APP_BIN)"
	@echo "[make] Side-by-side launcher: $(DEV_APP_BIN)"

run-dev-app:
	@echo "[make] Launching side-by-side Electron app"
	"$(DEV_APP_BIN)"

appimage:
	@echo "[make] Building AppImage"
	PACKAGE_VERSION="$(or $(PACKAGE_VERSION),)" ./scripts/build-appimage.sh

clean-dist:
	@echo "[make] Removing dist/"
	rm -rf "$(CURDIR)/dist"
