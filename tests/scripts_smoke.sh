#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"

export CODEX_LINUX_FEATURES_CONFIG="$REPO_DIR/linux-features/features.example.json"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

info() {
    echo "[smoke] $*" >&2
}

fail() {
    echo "[smoke][FAIL] $*" >&2
    exit 1
}

assert_file_exists() {
    local path="$1"
    [ -f "$path" ] || fail "Expected file to exist: $path"
}

assert_file_not_exists() {
    local path="$1"
    [ ! -e "$path" ] || fail "Expected file not to exist: $path"
}

assert_mode() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(python3 - "$path" <<'PY'
import os
import sys

print(format(os.lstat(sys.argv[1]).st_mode & 0o777, "o"))
PY
)"
    [ "$actual" = "$expected" ] || fail "Expected mode $expected for $path, got $actual"
}

assert_contains() {
    local path="$1"
    local pattern="$2"
    grep -q -- "$pattern" "$path" || fail "Expected '$pattern' in $path"
}

assert_not_contains() {
    local path="$1"
    local pattern="$2"
    if grep -q -- "$pattern" "$path"; then
        fail "Did not expect '$pattern' in $path"
    fi
}

assert_occurrence_count() {
    local path="$1"
    local pattern="$2"
    local expected="$3"
    local actual
    actual="$(grep -o -- "$pattern" "$path" | wc -l | tr -d ' ')"
    [ "$actual" = "$expected" ] || fail "Expected '$pattern' to appear $expected times in $path, found $actual"
}

make_fake_browser_use_upstream_app() {
    local app_dir="$1"
    local resources_dir="$app_dir/Contents/Resources"
    mkdir -p \
        "$resources_dir/plugins/openai-bundled/.agents/plugins" \
        "$resources_dir/plugins/openai-bundled/plugins/browser-use/.codex-plugin" \
        "$resources_dir/plugins/openai-bundled/plugins/browser-use/scripts"
    cat > "$resources_dir/plugins/openai-bundled/.agents/plugins/marketplace.json" <<'JSON'
{"plugins":[{"name":"browser-use","source":{"source":"local","path":"./plugins/browser-use"},"policy":{"installation":"AVAILABLE"}}]}
JSON
    cat > "$resources_dir/plugins/openai-bundled/plugins/browser-use/.codex-plugin/plugin.json" <<'JSON'
{"name":"browser-use","version":"0.1.0-alpha1"}
JSON
    cat > "$resources_dir/plugins/openai-bundled/plugins/browser-use/scripts/browser-client.mjs" <<'JS'
class Uf{async fetchBlocked(e){let r=await bS(e.endpoint,{method:"GET"});if(!r.ok)throw new Error(ae(`Browser Use cannot determine if ${e.displayUrl} is allowed. Please try again later or use another source.`));let n=await r.json();return TF(n)}}export function setupAtlasRuntime() {}
JS
}

make_fake_app() {
    local app_dir="$1"
    bash "$REPO_DIR/tests/fixtures/create-packaged-app-fixture.sh" "$app_dir"
}

make_stub_bin_dir() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
}

test_extract_webview_replaces_linux_icon_assets() {
    info "Checking webview extraction applies the Linux icon asset"
    local workspace="$TMP_DIR/webview-icon"
    local install_dir="$workspace/install"
    local work_dir="$workspace/work"
    local icon_source="$workspace/codex-linux.png"
    local assets_dir="$install_dir/content/webview/assets"
    local output_log="$workspace/output.log"

    mkdir -p "$work_dir/app-extracted/webview/assets" "$install_dir"
    printf '%s\n' 'linux-icon' > "$icon_source"
    printf '%s\n' 'upstream-main' > "$work_dir/app-extracted/webview/assets/app-main.png"
    printf '%s\n' 'upstream-alt' > "$work_dir/app-extracted/webview/assets/app-alt.png"
    printf '%s\n' '<style>--startup-background: transparent</style>' > "$work_dir/app-extracted/webview/index.html"

    (
        SCRIPT_DIR="$REPO_DIR"
        INSTALL_DIR="$install_dir"
        WORK_DIR="$work_dir"
        ICON_SOURCE="$icon_source"
        CODEX_LINUX_ICON_SOURCE="$icon_source"
        # shellcheck disable=SC1091
        source "$REPO_DIR/scripts/lib/webview-install.sh"
        extract_webview "$workspace/Codex.app"
    ) >"$output_log" 2>&1

    assert_file_exists "$assets_dir/app-main.png"
    assert_file_exists "$assets_dir/app-alt.png"
    cmp -s "$icon_source" "$assets_dir/app-main.png" \
        || fail "Expected extracted app-main.png to be replaced with the Linux icon"
    cmp -s "$icon_source" "$assets_dir/app-alt.png" \
        || fail "Expected extracted app-alt.png to be replaced with the Linux icon"
    assert_contains "$install_dir/content/webview/index.html" "--startup-background: #1e1e1e"
    assert_contains "$output_log" "Linux app icon applied to 2 webview asset(s)"
}

test_common_helper_sourcing() {
    info "Checking shared packaging helpers"
    local probe_file="$TMP_DIR/probe.txt"
    touch "$probe_file"

    # shellcheck disable=SC1091
    source "$REPO_DIR/scripts/lib/package-common.sh"
    ensure_file_exists "$probe_file" "probe file"
}

test_deb_builder_smoke() {
    info "Running Debian packaging smoke test"
    local workspace="$TMP_DIR/deb"
    local bin_dir="$workspace/bin"
    local app_dir="$workspace/app"
    local dist_dir="$workspace/dist"
    local pkg_root="$workspace/deb-root"
    local updater_bin="$workspace/codex-update-manager"

    mkdir -p "$workspace" "$dist_dir"
    make_stub_bin_dir "$bin_dir"
    make_fake_app "$app_dir"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$updater_bin"
    chmod +x "$updater_bin"

    cat > "$bin_dir/dpkg" <<'SCRIPT'
#!/usr/bin/env bash
if [ "$1" = "--print-architecture" ]; then
    echo amd64
    exit 0
fi
exit 0
SCRIPT
    cat > "$bin_dir/dpkg-deb" <<'SCRIPT'
#!/usr/bin/env bash
output="${@: -1}"
mkdir -p "$(dirname "$output")"
touch "$output"
SCRIPT
    cat > "$bin_dir/cargo" <<'SCRIPT'
#!/usr/bin/env bash
echo "cargo should not be called when UPDATER_BINARY_SOURCE exists" >&2
exit 99
SCRIPT
    chmod +x "$bin_dir/dpkg" "$bin_dir/dpkg-deb" "$bin_dir/cargo"

    PATH="$bin_dir:$PATH" \
    APP_DIR_OVERRIDE="$app_dir" \
    PKG_ROOT_OVERRIDE="$pkg_root" \
    DIST_DIR_OVERRIDE="$dist_dir" \
    UPDATER_BINARY_SOURCE="$updater_bin" \
    PACKAGE_VERSION="2026.03.24.120000+deadbeef" \
    bash "$REPO_DIR/scripts/build-deb.sh"

    assert_file_exists "$dist_dir/codex-desktop_2026.03.24.120000+deadbeef_amd64.deb"
    assert_file_exists "$pkg_root/DEBIAN/prerm"
    assert_file_exists "$pkg_root/DEBIAN/postrm"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/lib/package-common.sh"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/lib/patch-chrome-plugin.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/lib/node-runtime.sh"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/lib/linux-update-bridge-patch.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/lib/patch-report.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/lib/rebuild-report.sh"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/lib/linux-features.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/lib/linux-features.sh"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/lib/linux-target-context.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/patches/descriptor.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/patches/engine.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/patches/runner.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/patches/lib/assets.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/patches/lib/minified-js.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/patches/lib/settings-keys.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/patches/impl/webview/index.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/patches/core/all-linux/main-process/lifecycle/patch.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/patches/core/all-linux/webview/theme-and-sunset/patch.js"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/patches/core/distro/nixos/README.md"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/patches/core/desktop/i3/README.md"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/patches/core/package/deb/README.md"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/linux-features/README.md"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/linux-features/example-feature/feature.json"
    assert_file_not_exists "$pkg_root/opt/codex-desktop/update-builder/linux-features/features.json"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/node-runtime/bin/node"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/Cargo.toml"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/computer-use-linux/Cargo.toml"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/updater/Cargo.toml"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/plugins/openai-bundled/plugins/computer-use/.mcp.json"
    assert_file_exists "$pkg_root/opt/codex-desktop/.codex-linux/codex-packaged-runtime.sh"
    assert_file_exists "$pkg_root/opt/codex-desktop/resources/node-runtime/bin/node"
}

test_deb_builder_rebuilds_deleted_updater_source() {
    info "Checking package builder recovers from deleted updater binary source"
    local workspace="$TMP_DIR/deb-deleted-updater-source"
    local bin_dir="$workspace/bin"
    local app_dir="$workspace/app"
    local dist_dir="$workspace/dist"
    local pkg_root="$workspace/deb-root"
    local cargo_target_dir="$workspace/cargo-target"

    mkdir -p "$workspace" "$dist_dir"
    make_stub_bin_dir "$bin_dir"
    make_fake_app "$app_dir"

    cat > "$bin_dir/dpkg" <<'SCRIPT'
#!/usr/bin/env bash
if [ "$1" = "--print-architecture" ]; then
    echo amd64
    exit 0
fi
exit 0
SCRIPT
    cat > "$bin_dir/dpkg-deb" <<'SCRIPT'
#!/usr/bin/env bash
output="${@: -1}"
mkdir -p "$(dirname "$output")"
touch "$output"
SCRIPT
    cat > "$bin_dir/cargo" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
target_dir="${CARGO_TARGET_DIR:-target}"
mkdir -p "$target_dir/release"
cat > "$target_dir/release/codex-update-manager" <<'BIN'
#!/usr/bin/env bash
echo rebuilt updater
BIN
chmod +x "$target_dir/release/codex-update-manager"
SCRIPT
    chmod +x "$bin_dir/dpkg" "$bin_dir/dpkg-deb" "$bin_dir/cargo"

    PATH="$bin_dir:$PATH" \
    APP_DIR_OVERRIDE="$app_dir" \
    PKG_ROOT_OVERRIDE="$pkg_root" \
    DIST_DIR_OVERRIDE="$dist_dir" \
    CARGO_TARGET_DIR="$cargo_target_dir" \
    UPDATER_BINARY_SOURCE="$workspace/codex-update-manager (deleted)" \
    PACKAGE_VERSION="2026.03.24.120000+rebuilt" \
    bash "$REPO_DIR/scripts/build-deb.sh"

    assert_file_exists "$dist_dir/codex-desktop_2026.03.24.120000+rebuilt_amd64.deb"
    assert_file_exists "$pkg_root/usr/bin/codex-update-manager"
    assert_contains "$pkg_root/usr/bin/codex-update-manager" "rebuilt updater"
}

test_update_builder_preserves_enabled_linux_features_config() {
    info "Checking update-builder preserves sanitized enabled Linux feature config"
    local workspace="$TMP_DIR/update-builder-linux-features"
    local root="$workspace/root"
    local app_dir="$workspace/app"
    local feature_config="$workspace/features.json"
    local staged_config="$root/opt/codex-desktop/update-builder/linux-features/features.json"

    mkdir -p "$workspace"
    make_fake_app "$app_dir"
    cat > "$feature_config" <<'JSON'
{
  "enabled": [
    "example-feature"
  ],
  "settings": {
    "example-feature": {
      "tweaks": {
        "enabled": true
      }
    },
    "disabled-feature": {
      "should": "not be packaged"
    },
    "local-tool": {
      "mode": "local"
    }
  },
  "localComment": "should not be packaged"
}
JSON

    (
        export APP_DIR="$app_dir"
        export PACKAGE_NAME="codex-desktop"
        export UPDATER_SERVICE_SOURCE="$REPO_DIR/packaging/linux/codex-update-manager.service"
        export CODEX_LINUX_FEATURES_CONFIG="$feature_config"

        # shellcheck disable=SC1091
        source "$REPO_DIR/scripts/lib/package-common.sh"
        stage_update_builder_bundle "$root"
    )

    assert_file_exists "$staged_config"
    assert_contains "$staged_config" "example-feature"
    assert_not_contains "$staged_config" "localComment"
    assert_not_contains "$staged_config" "disabled-feature"
    assert_contains "$update_builder_manifest" "record-replay-linux/Cargo.toml"
    assert_contains "$update_builder_manifest" "assets/codex-linux.png"
    assert_not_contains "$update_builder_manifest" "^node-runtime/"

    node - "$staged_config" <<'NODE' || fail "Expected staged Linux features config to be sanitized"
const fs = require("node:fs");
const configPath = process.argv[2];
const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
if (JSON.stringify(config) !== JSON.stringify({ enabled: ["example-feature"] })) {
  process.exit(1);
}
NODE
}

test_deb_builder_respects_package_identity() {
    info "Running side-by-side Debian packaging smoke test"
    local workspace="$TMP_DIR/deb-identity"
    local bin_dir="$workspace/bin"
    local app_dir="$workspace/app"
    local dist_dir="$workspace/dist"
    local pkg_root="$workspace/deb-root"
    local updater_bin="$workspace/codex-update-manager"

    mkdir -p "$workspace" "$dist_dir"
    make_stub_bin_dir "$bin_dir"
    make_fake_app "$app_dir"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$updater_bin"
    chmod +x "$updater_bin"

    cat > "$bin_dir/dpkg" <<'SCRIPT'
#!/usr/bin/env bash
if [ "$1" = "--print-architecture" ]; then
    echo amd64
    exit 0
fi
exit 0
SCRIPT
    cat > "$bin_dir/dpkg-deb" <<'SCRIPT'
#!/usr/bin/env bash
output="${@: -1}"
mkdir -p "$(dirname "$output")"
touch "$output"
SCRIPT
    cat > "$bin_dir/cargo" <<'SCRIPT'
#!/usr/bin/env bash
echo "cargo should not be called when UPDATER_BINARY_SOURCE exists" >&2
exit 99
SCRIPT
    chmod +x "$bin_dir/dpkg" "$bin_dir/dpkg-deb" "$bin_dir/cargo"

    PATH="$bin_dir:$PATH" \
    APP_DIR_OVERRIDE="$app_dir" \
    PKG_ROOT_OVERRIDE="$pkg_root" \
    DIST_DIR_OVERRIDE="$dist_dir" \
    UPDATER_BINARY_SOURCE="$updater_bin" \
    PACKAGE_NAME="codex-cua-lab" \
    PACKAGE_DISPLAY_NAME="Codex CUA Lab" \
    PACKAGE_VERSION="2026.03.24.120000+deadbeef" \
    bash "$REPO_DIR/scripts/build-deb.sh"

    assert_file_exists "$dist_dir/codex-cua-lab_2026.03.24.120000+deadbeef_amd64.deb"
    assert_file_exists "$pkg_root/usr/bin/codex-cua-lab"
    assert_file_exists "$pkg_root/opt/codex-cua-lab/start.sh"
    assert_contains "$pkg_root/DEBIAN/control" "Package: codex-cua-lab"
    assert_contains "$pkg_root/usr/share/applications/codex-cua-lab.desktop" "Name=Codex CUA Lab"
    assert_contains "$pkg_root/usr/share/applications/codex-cua-lab.desktop" "CHROME_DESKTOP=codex-cua-lab.desktop"
    assert_contains "$pkg_root/usr/share/applications/codex-cua-lab.desktop" "/usr/bin/codex-cua-lab %u"
    assert_contains "$pkg_root/usr/share/applications/codex-cua-lab.desktop" "MimeType=x-scheme-handler/codex;x-scheme-handler/codex-browser-sidebar;"
    assert_contains "$pkg_root/usr/share/applications/codex-cua-lab.desktop" "StartupWMClass=Codex"
    assert_contains "$pkg_root/usr/share/applications/codex-cua-lab.desktop" "X-GNOME-WMClass=Codex"
    assert_contains "$pkg_root/opt/codex-cua-lab/.codex-linux/codex-packaged-runtime.sh" 'CHROME_DESKTOP="codex-cua-lab.desktop"'
}

test_deb_builder_without_updater() {
    info "Running no-updater Debian packaging smoke test"
    local workspace="$TMP_DIR/deb-no-updater"
    local bin_dir="$workspace/bin"
    local app_dir="$workspace/app"
    local dist_dir="$workspace/dist"
    local pkg_root="$workspace/deb-root"

    mkdir -p "$workspace" "$dist_dir"
    make_stub_bin_dir "$bin_dir"
    make_fake_app "$app_dir"

    cat > "$bin_dir/dpkg" <<'SCRIPT'
#!/usr/bin/env bash
if [ "$1" = "--print-architecture" ]; then
    echo amd64
    exit 0
fi
exit 0
SCRIPT
    cat > "$bin_dir/dpkg-deb" <<'SCRIPT'
#!/usr/bin/env bash
output="${@: -1}"
mkdir -p "$(dirname "$output")"
touch "$output"
SCRIPT
    cat > "$bin_dir/cargo" <<'SCRIPT'
#!/usr/bin/env bash
echo "cargo should not be called when PACKAGE_WITH_UPDATER=0" >&2
exit 99
SCRIPT
    chmod +x "$bin_dir/dpkg" "$bin_dir/dpkg-deb" "$bin_dir/cargo"

    PATH="$bin_dir:$PATH" \
    APP_DIR_OVERRIDE="$app_dir" \
    PKG_ROOT_OVERRIDE="$pkg_root" \
    DIST_DIR_OVERRIDE="$dist_dir" \
    PACKAGE_WITH_UPDATER=0 \
    PACKAGE_VERSION="2026.03.24.120000+manual" \
    bash "$REPO_DIR/scripts/build-deb.sh"

    assert_file_exists "$dist_dir/codex-desktop_2026.03.24.120000+manual_amd64.deb"
    assert_file_exists "$pkg_root/usr/bin/codex-desktop"
    assert_file_exists "$pkg_root/DEBIAN/postinst"
    assert_file_exists "$pkg_root/DEBIAN/prerm"
    assert_file_exists "$pkg_root/opt/codex-desktop/.codex-linux/codex-packaged-runtime.sh"
    assert_file_exists "$pkg_root/opt/codex-desktop/.codex-linux/codex-no-updater-transition-cleanup.sh"
    assert_file_not_exists "$pkg_root/usr/bin/codex-update-manager"
    assert_file_not_exists "$pkg_root/usr/lib/systemd/user/codex-update-manager.service"
    assert_file_not_exists "$pkg_root/usr/share/polkit-1/actions/com.github.ilysenko.codex-desktop-linux.update.policy"
    assert_file_not_exists "$pkg_root/opt/codex-desktop/update-builder"
    assert_file_not_exists "$pkg_root/DEBIAN/postrm"
    assert_not_contains "$pkg_root/DEBIAN/control" "pkexec"
    assert_not_contains "$pkg_root/DEBIAN/control" "polkit"
    assert_not_contains "$pkg_root/DEBIAN/control" "Local auto-updates"
    assert_contains "$pkg_root/DEBIAN/control" "without codex-update-manager"
    assert_not_contains "$pkg_root/usr/share/applications/codex-desktop.desktop" "Actions=CheckForUpdates"
    assert_not_contains "$pkg_root/usr/share/applications/codex-desktop.desktop" "Desktop Action CheckForUpdates"
    assert_not_contains "$pkg_root/usr/share/applications/codex-desktop.desktop" "codex-update-manager"
    assert_not_contains "$pkg_root/opt/codex-desktop/.codex-linux/codex-packaged-runtime.sh" "systemctl"
    assert_not_contains "$pkg_root/opt/codex-desktop/.codex-linux/codex-packaged-runtime.sh" "codex-update-manager"
    assert_contains "$pkg_root/opt/codex-desktop/.codex-linux/codex-packaged-runtime.sh" 'CHROME_DESKTOP="codex-desktop.desktop"'
    assert_contains "$pkg_root/opt/codex-desktop/.codex-linux/codex-no-updater-transition-cleanup.sh" "codex_no_updater_cleanup_update_manager_service"
    assert_contains "$pkg_root/opt/codex-desktop/.codex-linux/codex-no-updater-transition-cleanup.sh" "stop \"\$SERVICE_NAME\""
    assert_contains "$pkg_root/opt/codex-desktop/.codex-linux/codex-no-updater-transition-cleanup.sh" "disable \"\$SERVICE_NAME\""
    assert_contains "$pkg_root/opt/codex-desktop/.codex-linux/codex-no-updater-transition-cleanup.sh" "daemon-reload"
    assert_contains "$pkg_root/opt/codex-desktop/.codex-linux/codex-no-updater-transition-cleanup.sh" "codex_no_updater_cleanup_user_enablement_links"
    assert_contains "$pkg_root/opt/codex-desktop/.codex-linux/codex-no-updater-transition-cleanup.sh" "default.target.wants"
    assert_contains "$pkg_root/DEBIAN/postinst" "codex_no_updater_cleanup_update_manager_service"
    assert_contains "$pkg_root/DEBIAN/prerm" "codex_no_updater_cleanup_update_manager_service"
    assert_not_contains "$pkg_root/DEBIAN/postinst" "update-builder"
    assert_not_contains "$pkg_root/DEBIAN/prerm" "update-builder"
}

test_no_updater_cleanup_helper_removes_inactive_user_enablement() {
    info "Checking no-updater inactive user service cleanup"
    local workspace="$TMP_DIR/no-updater-cleanup"
    local bin_dir="$workspace/bin"
    local helper="$workspace/codex-no-updater-transition-cleanup.sh"
    local fake_home="$workspace/home/codexuser"
    local service_link="$fake_home/.config/systemd/user/default.target.wants/codex-update-manager.service"

    mkdir -p "$bin_dir" "$(dirname "$service_link")"
    ln -s /usr/lib/systemd/user/codex-update-manager.service "$service_link"

    render_no_updater_transition_cleanup_helper "$helper"

    cat > "$bin_dir/getent" <<'SCRIPT'
#!/usr/bin/env bash
if [ "${1:-}" = "passwd" ]; then
    printf 'codexuser:x:1000:1000::%s:/bin/sh\n' "$FAKE_HOME"
fi
SCRIPT
    cat > "$bin_dir/runuser" <<'SCRIPT'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
    shift 2
fi
if [ "${1:-}" = "--" ]; then
    shift
fi
exec "$@"
SCRIPT
    cat > "$bin_dir/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
    chmod +x "$bin_dir/getent" "$bin_dir/runuser" "$bin_dir/systemctl"

    PATH="$bin_dir:$PATH" FAKE_HOME="$fake_home" sh -c \
        '. "$1"; codex_no_updater_cleanup_update_manager_service' \
        _ "$helper"

    assert_file_not_exists "$service_link"
}

test_update_manager_service_helper_respects_disabled_service() {
    info "Checking updater service helper respects disabled user service state"
    local helper_log="$TMP_DIR/updater-service-helper.log"
    local helper_state=""

    # shellcheck source=packaging/linux/codex-update-manager-user-service.sh
    . "$REPO_DIR/packaging/linux/codex-update-manager-user-service.sh"

    codex_run_systemctl_user() {
        local user_name="$1"
        local runtime_dir="$2"
        local bus="$3"
        shift 3
        printf '%s|%s|%s|%s\n' "$helper_state" "$user_name" "$runtime_dir" "$*" >> "$helper_log"

        case "$*" in
            "daemon-reload")
                return 0
                ;;
            "is-active $SERVICE_NAME")
                [ "$helper_state" = "active" ]
                return
                ;;
            "is-enabled $SERVICE_NAME")
                [ "$helper_state" = "enabled" ] || [ "$helper_state" = "active" ]
                return
                ;;
            "start $SERVICE_NAME")
                return 0
                ;;
            "enable --now $SERVICE_NAME")
                return 0
                ;;
        esac

        return 1
    }

    helper_state="disabled"
    : > "$helper_log"
    codex_start_one_enabled_user_service codexuser /run/user/1000 /run/user/1000/bus
    assert_not_contains "$helper_log" "start $SERVICE_NAME"
    assert_not_contains "$helper_log" "enable --now $SERVICE_NAME"

    helper_state="enabled"
    : > "$helper_log"
    codex_start_one_enabled_user_service codexuser /run/user/1000 /run/user/1000/bus
    assert_contains "$helper_log" "start $SERVICE_NAME"
    assert_not_contains "$helper_log" "enable --now $SERVICE_NAME"

    helper_state="disabled"
    : > "$helper_log"
    codex_ensure_one_user_service_running codexuser /run/user/1000 /run/user/1000/bus
    assert_contains "$helper_log" "enable --now $SERVICE_NAME"
}

test_rpm_builder_smoke() {
    info "Running RPM packaging smoke test"
    local workspace="$TMP_DIR/rpm"
    local bin_dir="$workspace/bin"
    local app_dir="$workspace/app"
    local dist_dir="$workspace/dist"
    local updater_bin="$workspace/codex-update-manager"
    local capture_dir="$workspace/capture"

    mkdir -p "$workspace" "$dist_dir" "$capture_dir"
    make_stub_bin_dir "$bin_dir"
    make_fake_app "$app_dir"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$updater_bin"
    chmod +x "$updater_bin"

    cat > "$bin_dir/rpmbuild" <<'SCRIPT'
#!/usr/bin/env bash
rpmdir=""
spec_file="${@: -1}"
while [ $# -gt 0 ]; do
    if [ "$1" = "--define" ]; then
        case "$2" in
            _rpmdir\ *) rpmdir="${2#_rpmdir }" ;;
        esac
        shift 2
        continue
    fi
    shift
done
[ -n "$rpmdir" ] || exit 1
if [ -n "${CAPTURE_DIR:-}" ]; then
    cp "$spec_file" "$CAPTURE_DIR/codex-desktop.spec"
    staging_dir="$(sed -n 's|cp -a "\(.*\)/\." "%{buildroot}/"|\1|p' "$spec_file" | head -n 1)"
    if [ -n "$staging_dir" ] && [ -d "$staging_dir" ]; then
        cp -a "$staging_dir" "$CAPTURE_DIR/staging"
    fi
fi
mkdir -p "$rpmdir/x86_64"
touch "$rpmdir/x86_64/codex-desktop-2026.03.24.120000-deadbeef.x86_64.rpm"
SCRIPT
    cat > "$bin_dir/cargo" <<'SCRIPT'
#!/usr/bin/env bash
echo "cargo should not be called when UPDATER_BINARY_SOURCE exists" >&2
exit 99
SCRIPT
    chmod +x "$bin_dir/rpmbuild" "$bin_dir/cargo"

    PATH="$bin_dir:$PATH" \
    APP_DIR_OVERRIDE="$app_dir" \
    DIST_DIR_OVERRIDE="$dist_dir" \
    UPDATER_BINARY_SOURCE="$updater_bin" \
    PACKAGE_VERSION="2026.03.24.120000+deadbeef" \
    bash "$REPO_DIR/scripts/build-rpm.sh"

    assert_file_exists "$dist_dir/codex-desktop-2026.03.24.120000-deadbeef.x86_64.rpm"

    rm -rf "$dist_dir" "$capture_dir"
    mkdir -p "$dist_dir" "$capture_dir"

    PATH="$bin_dir:$PATH" \
    CAPTURE_DIR="$capture_dir" \
    APP_DIR_OVERRIDE="$app_dir" \
    DIST_DIR_OVERRIDE="$dist_dir" \
    PACKAGE_WITH_UPDATER=0 \
    PACKAGE_VERSION="2026.03.24.120000+manual" \
    bash "$REPO_DIR/scripts/build-rpm.sh"

    assert_file_exists "$dist_dir/codex-desktop-2026.03.24.120000-manual.x86_64.rpm"
    assert_file_exists "$capture_dir/codex-desktop.spec"
    assert_file_exists "$capture_dir/staging/opt/codex-desktop/.codex-linux/codex-no-updater-transition-cleanup.sh"
    assert_file_not_exists "$capture_dir/staging/usr/bin/codex-update-manager"
    assert_file_not_exists "$capture_dir/staging/usr/lib/systemd/user/codex-update-manager.service"
    assert_file_not_exists "$capture_dir/staging/usr/share/polkit-1/actions/com.github.ilysenko.codex-desktop-linux.update.policy"
    assert_file_not_exists "$capture_dir/staging/opt/codex-desktop/update-builder"
    assert_contains "$capture_dir/codex-desktop.spec" "%if 0"
    assert_contains "$capture_dir/codex-desktop.spec" "codex_no_updater_cleanup_update_manager_service"
    assert_contains "$capture_dir/staging/opt/codex-desktop/.codex-linux/codex-no-updater-transition-cleanup.sh" "codex_no_updater_cleanup_user_enablement_links"
}

test_pacman_builder_without_updater_transition_hook() {
    info "Running no-updater pacman packaging hook smoke test"
    if [ "$(id -u)" -eq 0 ]; then
        info "Skipping pacman no-updater hook smoke test as root"
        return
    fi

    local workspace="$TMP_DIR/pacman-no-updater"
    local bin_dir="$workspace/bin"
    local app_dir="$workspace/app"
    local dist_dir="$workspace/dist"
    local capture_dir="$workspace/capture"
    local ampersand_tmpdir="$workspace/ampersand&tmp"

    mkdir -p "$workspace" "$dist_dir" "$capture_dir" "$ampersand_tmpdir"
    make_stub_bin_dir "$bin_dir"
    make_fake_app "$app_dir"

    cat > "$bin_dir/makepkg" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
cp PKGBUILD "$CAPTURE_DIR/PKGBUILD"
cp codex-desktop.install "$CAPTURE_DIR/codex-desktop.install"
pkgname="$(sed -n 's/^pkgname=//p' PKGBUILD)"
pkgver="$(sed -n 's/^pkgver=//p' PKGBUILD)"
pkgrel="$(sed -n 's/^pkgrel=//p' PKGBUILD)"
arch="$(sed -n "s/^arch=('\([^']*\)').*/\1/p" PKGBUILD)"
mkdir -p "$PKGDEST"
touch "$PKGDEST/${pkgname}-${pkgver}-${pkgrel}-${arch}.pkg.tar.zst"
SCRIPT
    cat > "$bin_dir/cargo" <<'SCRIPT'
#!/usr/bin/env bash
echo "cargo should not be called when PACKAGE_WITH_UPDATER=0" >&2
exit 99
SCRIPT
    chmod +x "$bin_dir/makepkg" "$bin_dir/cargo"

    local package_path
    package_path="$(
        TMPDIR="$ampersand_tmpdir" \
        PATH="$bin_dir:$PATH" \
        CAPTURE_DIR="$capture_dir" \
        APP_DIR_OVERRIDE="$app_dir" \
        DIST_DIR_OVERRIDE="$dist_dir" \
        PACKAGE_WITH_UPDATER=0 \
        PACKAGE_VERSION="2026.03.24.120000+manual" \
        bash "$REPO_DIR/scripts/build-pacman.sh"
    )"

    assert_file_exists "$dist_dir/codex-desktop-2026.03.24.120000+manual-1-x86_64.pkg.tar.zst"
    [ "$package_path" = "$dist_dir/codex-desktop-2026.03.24.120000+manual-1-x86_64.pkg.tar.zst" ] || fail "Expected build-pacman.sh to print built package path, got: $package_path"
    assert_file_exists "$dist_dir/codex-desktop-latest.pkg.tar.zst"
    [ "$(readlink "$dist_dir/codex-desktop-latest.pkg.tar.zst")" = "codex-desktop-2026.03.24.120000+manual-1-x86_64.pkg.tar.zst" ] || fail "Expected latest pacman symlink to point at built package"
    assert_file_exists "$capture_dir/PKGBUILD"
    assert_file_exists "$capture_dir/codex-desktop.install"
    assert_contains "$capture_dir/PKGBUILD" "pkgver=2026.03.24.120000+manual"
    assert_contains "$capture_dir/PKGBUILD" "pkgrel=1"
    assert_contains "$capture_dir/PKGBUILD" "ampersand&tmp"
    assert_not_contains "$capture_dir/PKGBUILD" "__STAGING_DIR__"
    assert_contains "$capture_dir/PKGBUILD" "install=codex-desktop.install"
    assert_not_contains "$capture_dir/PKGBUILD" "'polkit'"
    assert_contains "$capture_dir/codex-desktop.install" "codex_no_updater_cleanup_update_manager_service"
    assert_contains "$capture_dir/codex-desktop.install" "post_upgrade"
    assert_contains "$capture_dir/codex-desktop.install" "pre_remove"
    assert_contains "$capture_dir/codex-desktop.install" "codex-no-updater-transition-cleanup.sh"
    assert_not_contains "$capture_dir/codex-desktop.install" "update-builder"
}

test_appimage_builder_smoke() {
    info "Running AppImage packaging smoke test"
    local workspace="$TMP_DIR/appimage"
    local bin_dir="$workspace/bin"
    local app_dir="$workspace/app"
    local dist_dir="$workspace/dist"
    local appdir="$workspace/codex-desktop.AppDir"
    local capture_dir="$workspace/capture"
    local arch

    case "$(uname -m)" in
        x86_64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        armv7l|armhf) arch="armhf" ;;
        *) fail "Unsupported AppImage smoke-test architecture: $(uname -m)" ;;
    esac

    mkdir -p "$workspace" "$dist_dir" "$capture_dir"
    make_stub_bin_dir "$bin_dir"
    make_fake_app "$app_dir"

    cat > "$bin_dir/appimagetool" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

saw_no_appstream=0
previous=""
last=""
for arg in "$@"; do
    [ "$arg" = "--no-appstream" ] && saw_no_appstream=1
    previous="$last"
    last="$arg"
done

[ "$saw_no_appstream" -eq 1 ] || exit 2
[ -n "$previous" ] || exit 3
[ -d "$previous" ] || exit 4
[ -n "${ARCH:-}" ] || exit 5
[ -n "${VERSION:-}" ] || exit 6

mkdir -p "$(dirname "$last")" "$CAPTURE_DIR"
cp -a "$previous" "$CAPTURE_DIR/AppDir"
printf '%s\n' "$ARCH" > "$CAPTURE_DIR/arch"
printf '%s\n' "$VERSION" > "$CAPTURE_DIR/version"
touch "$last"
SCRIPT
    chmod +x "$bin_dir/appimagetool"

    PATH="$bin_dir:$PATH" \
    CAPTURE_DIR="$capture_dir" \
    APP_DIR_OVERRIDE="$app_dir" \
    DIST_DIR_OVERRIDE="$dist_dir" \
    APPIMAGE_APPDIR_OVERRIDE="$appdir" \
    PACKAGE_VERSION="2026.03.24.120000+appimage" \
    bash "$REPO_DIR/scripts/build-appimage.sh"

    assert_file_exists "$dist_dir/codex-desktop-2026.03.24.120000+appimage-$arch.AppImage"
    assert_file_exists "$capture_dir/AppDir/AppRun"
    [ -x "$capture_dir/AppDir/AppRun" ] || fail "Expected AppRun to be executable"
    assert_file_exists "$capture_dir/AppDir/codex-desktop.desktop"
    assert_file_exists "$capture_dir/AppDir/codex-desktop.png"
    assert_file_exists "$capture_dir/AppDir/.DirIcon"
    assert_file_exists "$capture_dir/AppDir/usr/share/applications/codex-desktop.desktop"
    assert_file_exists "$capture_dir/AppDir/usr/share/icons/hicolor/256x256/apps/codex-desktop.png"
    assert_file_exists "$capture_dir/AppDir/opt/codex-desktop/start.sh"
    assert_file_exists "$capture_dir/AppDir/opt/codex-desktop/.codex-linux/codex-desktop.png"
    assert_file_exists "$capture_dir/AppDir/opt/codex-desktop/.codex-linux/codex-packaged-runtime.sh"
    assert_file_exists "$capture_dir/AppDir/opt/codex-desktop/resources/node-runtime/bin/node"
    assert_file_not_exists "$capture_dir/AppDir/usr/bin/codex-update-manager"
    assert_file_not_exists "$capture_dir/AppDir/usr/lib/systemd/user/codex-update-manager.service"
    assert_file_not_exists "$capture_dir/AppDir/usr/share/polkit-1/actions/com.github.ilysenko.codex-desktop-linux.update.policy"
    assert_file_not_exists "$capture_dir/AppDir/opt/codex-desktop/update-builder"
    assert_contains "$capture_dir/AppDir/codex-desktop.desktop" "Exec=AppRun %u"
    assert_contains "$capture_dir/AppDir/codex-desktop.desktop" "Icon=codex-desktop"
    assert_contains "$capture_dir/AppDir/codex-desktop.desktop" "X-AppImage-Version=2026.03.24.120000+appimage"
    assert_not_contains "$capture_dir/AppDir/codex-desktop.desktop" "codex-update-manager"
    assert_contains "$capture_dir/AppDir/opt/codex-desktop/.codex-linux/codex-packaged-runtime.sh" 'CHROME_DESKTOP="codex-desktop.desktop"'
    assert_not_contains "$capture_dir/AppDir/opt/codex-desktop/.codex-linux/codex-packaged-runtime.sh" "/usr/share/applications"
    [ "$(cat "$capture_dir/arch")" = "$arch" ] || fail "Expected appimagetool ARCH=$arch"
    [ "$(cat "$capture_dir/version")" = "2026.03.24.120000+appimage" ] || fail "Expected appimagetool VERSION override"
}

test_missing_input_failure() {
    info "Checking missing-input failure path"
    local workspace="$TMP_DIR/missing"
    local bin_dir="$workspace/bin"
    local rpm_app_dir="$workspace/rpm-app"
    local rpm_log="$workspace/rpm-missing-runtime.log"

    mkdir -p "$workspace"
    make_stub_bin_dir "$bin_dir"
    make_fake_app "$rpm_app_dir"
    cat > "$bin_dir/dpkg" <<'SCRIPT'
#!/usr/bin/env bash
echo amd64
SCRIPT
    cat > "$bin_dir/dpkg-deb" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
    chmod +x "$bin_dir/dpkg" "$bin_dir/dpkg-deb"

    if PATH="$bin_dir:$PATH" APP_DIR_OVERRIDE="$workspace/does-not-exist" PKG_ROOT_OVERRIDE="$workspace/deb-root" bash "$REPO_DIR/scripts/build-deb.sh" >/dev/null 2>&1; then
        fail "build-deb.sh should fail when APP_DIR is missing"
    fi

    if APP_DIR_OVERRIDE="$rpm_app_dir" PACKAGED_RUNTIME_SOURCE="$workspace/does-not-exist.sh" bash "$REPO_DIR/scripts/build-rpm.sh" >"$rpm_log" 2>&1; then
        fail "build-rpm.sh should fail when PACKAGED_RUNTIME_SOURCE is missing"
    fi
    assert_contains "$rpm_log" "Missing packaged launcher runtime helper"
}

test_make_install_reports_missing_native_packages() {
    info "Checking make install missing-package diagnostics"
    local workspace="$TMP_DIR/make-install-missing"
    local output_log
    local format
    local expected

    mkdir -p "$workspace/dist"

    for format in pacman rpm deb; do
        output_log="$workspace/$format.log"
        case "$format" in
            pacman) expected="No pacman package found. Run 'make pacman' first." ;;
            rpm) expected="No RPM package found. Run 'make rpm' first." ;;
            deb) expected="No Debian package found. Run 'make deb' first." ;;
        esac

        if make -f "$REPO_DIR/Makefile" -C "$workspace" install \
            NATIVE_PKG_FORMAT_CMD="printf $format" >"$output_log" 2>&1
        then
            fail "make install should fail when no $format package exists"
        fi

        assert_contains "$output_log" "$expected"
    done
}

test_make_run_app_reports_missing_launcher() {
    info "Checking make run-app missing-launcher diagnostics"
    local workspace="$TMP_DIR/make-run-app-missing"
    local output_log="$workspace/run-app.log"

    mkdir -p "$workspace"

    if make -f "$REPO_DIR/Makefile" -C "$workspace" run-app >"$output_log" 2>&1; then
        fail "make run-app should fail when codex-app/start.sh is missing"
    fi

    assert_contains "$output_log" "Missing launcher: $workspace/codex-app/start.sh. Run make build-app first."
    assert_not_contains "$output_log" "No such file or directory"
}

test_make_build_app_uses_installer_download_flow_by_default() {
    info "Checking make build-app default DMG behavior"
    local workspace="$TMP_DIR/make-build-app"
    local install_log="$workspace/install-args.log"
    local first_line
    local second_line

    mkdir -p "$workspace"

    cat > "$workspace/install.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$#" > "$TEST_INSTALL_LOG"
if [ "$#" -gt 0 ]; then
    printf '%s\n' "$1" >> "$TEST_INSTALL_LOG"
fi
SCRIPT
    chmod +x "$workspace/install.sh"

    TEST_INSTALL_LOG="$install_log" make -f "$REPO_DIR/Makefile" -C "$workspace" build-app >/dev/null

    assert_file_exists "$install_log"
    first_line="$(sed -n '1p' "$install_log")"
    second_line="$(sed -n '2p' "$install_log")"
    [ "$first_line" = "1" ] || fail "Expected make build-app to call install.sh with a single default argument slot, got: $(cat "$install_log")"
    [ -z "$second_line" ] || fail "Expected make build-app default DMG argument to be empty so install.sh falls back to reuse/download, got: $(cat "$install_log")"
}

test_make_build_app_fresh_uses_installer_fresh_flow() {
    info "Checking make build-app-fresh DMG behavior"
    local workspace="$TMP_DIR/make-build-app-fresh"
    local install_log="$workspace/install-args.log"
    local first_line
    local second_line
    local third_line

    mkdir -p "$workspace"

    cat > "$workspace/install.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$#" > "$TEST_INSTALL_LOG"
for arg in "$@"; do
    printf '%s\n' "$arg" >> "$TEST_INSTALL_LOG"
done
SCRIPT
    chmod +x "$workspace/install.sh"

    TEST_INSTALL_LOG="$install_log" make -f "$REPO_DIR/Makefile" -C "$workspace" build-app-fresh >/dev/null

    assert_file_exists "$install_log"
    first_line="$(sed -n '1p' "$install_log")"
    second_line="$(sed -n '2p' "$install_log")"
    third_line="$(sed -n '3p' "$install_log")"
    [ "$first_line" = "2" ] || fail "Expected make build-app-fresh to pass --fresh plus the default argument slot, got: $(cat "$install_log")"
    [ "$second_line" = "--fresh" ] || fail "Expected make build-app-fresh to pass --fresh first, got: $(cat "$install_log")"
    [ -z "$third_line" ] || fail "Expected make build-app-fresh default DMG argument to be empty, got: $(cat "$install_log")"
}

test_make_build_dev_app_writes_host_portable_launcher_symlink() {
    info "Checking make build-dev-app writes a host-portable launcher symlink"
    local workspace="$TMP_DIR/make-build-dev-app"
    local install_log="$workspace/install-env.log"
    local launcher="$workspace/bin/codex-cua-lab"
    local target

    mkdir -p "$workspace"

    cat > "$workspace/install.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$CODEX_APP_ID" > "$TEST_INSTALL_LOG"
printf '%s\n' "$CODEX_APP_DISPLAY_NAME" >> "$TEST_INSTALL_LOG"
printf '%s\n' "$CODEX_INSTALL_DIR" >> "$TEST_INSTALL_LOG"
mkdir -p "$CODEX_INSTALL_DIR"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$CODEX_INSTALL_DIR/start.sh"
chmod +x "$CODEX_INSTALL_DIR/start.sh"
SCRIPT
    chmod +x "$workspace/install.sh"

    TEST_INSTALL_LOG="$install_log" make -f "$REPO_DIR/Makefile" -C "$workspace" build-dev-app >/dev/null

    assert_file_exists "$launcher"
    target="$(readlink "$launcher")"
    [ "$target" = "../codex-cua-lab-app/start.sh" ] \
        || fail "Expected dev app launcher to use a relative symlink, got: $target"
    [ -x "$launcher" ] || fail "Expected dev app launcher symlink to resolve on the host"
    assert_contains "$install_log" "codex-cua-lab"
    assert_contains "$install_log" "Codex CUA Lab"
    assert_contains "$install_log" "$workspace/codex-cua-lab-app"
}

test_installer_refreshes_stale_cached_dmg_metadata() {
    info "Checking installer DMG cache freshness metadata branches"
    local workspace="$TMP_DIR/dmg-cache-refresh"
    local bin_dir="$workspace/bin"
    local url="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
    local url_sha256

    url_sha256="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"

    mkdir -p "$bin_dir"

    cat >"$bin_dir/curl" <<'SCRIPT'
#!/usr/bin/env bash
set -eu

is_head=0
for arg in "$@"; do
    if [ "$arg" = "-fsSLI" ]; then
        is_head=1
    fi
done

if [ "$is_head" -eq 1 ]; then
    printf '%s\n' "HEAD" >> "$TEST_CURL_LOG"
    if [ "${TEST_HEAD_FAIL:-0}" = "1" ]; then
        exit 22
    fi
    printf 'HTTP/2 200\r\n'
    [ -z "${TEST_ETAG:-}" ] || printf 'ETag: %s\r\n' "$TEST_ETAG"
    [ -z "${TEST_LAST_MODIFIED:-}" ] || printf 'Last-Modified: %s\r\n' "$TEST_LAST_MODIFIED"
    [ -z "${TEST_CONTENT_LENGTH:-}" ] || printf 'Content-Length: %s\r\n' "$TEST_CONTENT_LENGTH"
    printf '\r\n'
    exit 0
fi

printf '%s\n' "GET" >> "$TEST_CURL_LOG"
if [ "${TEST_GET_FAIL:-0}" = "1" ]; then
    exit 23
fi

out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        out="$1"
    fi
    shift || true
done

[ -n "$out" ] || exit 2
printf '%s' "${TEST_DOWNLOAD_CONTENT:-new}" >"$out"
SCRIPT
    chmod +x "$bin_dir/curl"

    run_dmg_cache_case() {
        local source_dir="$1"
        local output_log="$2"
        shift 2

        mkdir -p "$source_dir"
        : >"$source_dir/curl.log"
        env "$@" \
            PATH="$bin_dir:$PATH" \
            TEST_SOURCE_DIR="$source_dir" \
            TEST_CURL_LOG="$source_dir/curl.log" \
            REPO_DIR="$REPO_DIR" \
            bash <<'SCRIPT' >"$output_log" 2>&1
set -Eeuo pipefail

SCRIPT_DIR="$TEST_SOURCE_DIR"
WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/lib/install-helpers.sh"
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/lib/dmg.sh"

dmg_path="$(get_dmg)"
[ "$dmg_path" = "$TEST_SOURCE_DIR/Codex.dmg" ]
SCRIPT
    }

    local no_metadata="$workspace/no-metadata"
    mkdir -p "$no_metadata"
    printf '%s' "old" >"$no_metadata/Codex.dmg"
    run_dmg_cache_case "$no_metadata" "$no_metadata/output.log" \
        TEST_ETAG=fresh-etag \
        TEST_LAST_MODIFIED="Thu, 04 Jun 2026 00:00:00 GMT" \
        TEST_CONTENT_LENGTH=3 \
        TEST_DOWNLOAD_CONTENT=new
    [ "$(cat "$no_metadata/Codex.dmg")" = "new" ] || fail "Expected missing-metadata cache to refresh"
    assert_contains "$no_metadata/Codex.dmg.metadata" "etag=fresh-etag"
    assert_contains "$no_metadata/Codex.dmg.metadata" "url_sha256=$url_sha256"
    assert_contains "$no_metadata/output.log" "Cached DMG has no upstream metadata"
    assert_contains "$no_metadata/output.log" "Refreshing stale cached DMG"

    local matching="$workspace/matching"
    mkdir -p "$matching"
    printf '%s' "old" >"$matching/Codex.dmg"
    cat >"$matching/Codex.dmg.metadata" <<EOF
url_sha256=$url_sha256
etag=same-etag
last_modified=Thu, 04 Jun 2026 00:00:00 GMT
content_length=3
EOF
    run_dmg_cache_case "$matching" "$matching/output.log" \
        TEST_ETAG=same-etag \
        TEST_LAST_MODIFIED="Thu, 04 Jun 2026 00:00:00 GMT" \
        TEST_CONTENT_LENGTH=3 \
        TEST_DOWNLOAD_CONTENT=downloaded
    [ "$(cat "$matching/Codex.dmg")" = "old" ] || fail "Expected matching metadata to reuse cache"
    assert_not_contains "$matching/curl.log" "GET"
    assert_contains "$matching/output.log" "Using cached DMG"

    local differing="$workspace/differing"
    mkdir -p "$differing"
    printf '%s' "old" >"$differing/Codex.dmg"
    cat >"$differing/Codex.dmg.metadata" <<EOF
url_sha256=$url_sha256
etag=old-etag
last_modified=Thu, 04 Jun 2026 00:00:00 GMT
content_length=3
EOF
    run_dmg_cache_case "$differing" "$differing/output.log" \
        TEST_ETAG=fresh-etag \
        TEST_LAST_MODIFIED="Thu, 04 Jun 2026 00:00:00 GMT" \
        TEST_CONTENT_LENGTH=3 \
        TEST_DOWNLOAD_CONTENT=new
    [ "$(cat "$differing/Codex.dmg")" = "new" ] || fail "Expected differing metadata to refresh cache"
    assert_contains "$differing/curl.log" "GET"

    local differing_pinned="$workspace/differing-pinned"
    mkdir -p "$differing_pinned"
    printf '%s' "old" >"$differing_pinned/Codex.dmg"
    cat >"$differing_pinned/Codex.dmg.metadata" <<EOF
url_sha256=$url_sha256
etag=old-etag
last_modified=Thu, 04 Jun 2026 00:00:00 GMT
content_length=3
EOF
    run_dmg_cache_case "$differing_pinned" "$differing_pinned/output.log" \
        CODEX_DMG_REFRESH_MODE=pinned \
        TEST_ETAG=fresh-etag \
        TEST_LAST_MODIFIED="Thu, 04 Jun 2026 00:00:00 GMT" \
        TEST_CONTENT_LENGTH=3 \
        TEST_DOWNLOAD_CONTENT=new
    [ "$(cat "$differing_pinned/Codex.dmg")" = "old" ] || fail "Expected pinned stale cache to keep old DMG"
    assert_not_contains "$differing_pinned/curl.log" "HEAD"
    assert_not_contains "$differing_pinned/curl.log" "GET"
    assert_contains "$differing_pinned/output.log" "CODEX_DMG_REFRESH_MODE=pinned"

    local no_metadata_pinned="$workspace/no-metadata-pinned"
    mkdir -p "$no_metadata_pinned"
    printf '%s' "old" >"$no_metadata_pinned/Codex.dmg"
    run_dmg_cache_case "$no_metadata_pinned" "$no_metadata_pinned/output.log" \
        CODEX_DMG_REFRESH_MODE=pinned \
        TEST_ETAG=fresh-etag \
        TEST_LAST_MODIFIED="Thu, 04 Jun 2026 00:00:00 GMT" \
        TEST_CONTENT_LENGTH=3 \
        TEST_DOWNLOAD_CONTENT=new
    [ "$(cat "$no_metadata_pinned/Codex.dmg")" = "old" ] || fail "Expected pinned missing metadata cache to keep old DMG"
    assert_not_contains "$no_metadata_pinned/curl.log" "HEAD"
    assert_not_contains "$no_metadata_pinned/curl.log" "GET"

    local missing_pinned="$workspace/missing-pinned"
    mkdir -p "$missing_pinned"
    if run_dmg_cache_case "$missing_pinned" "$missing_pinned/output.log" \
        CODEX_DMG_REFRESH_MODE=pinned
    then
        fail "Expected pinned mode without cached DMG to fail"
    fi
    assert_not_contains "$missing_pinned/curl.log" "HEAD"
    assert_not_contains "$missing_pinned/curl.log" "GET"
    assert_contains "$missing_pinned/output.log" "requires an existing cached DMG"

    local failed_get="$workspace/failed-get"
    mkdir -p "$failed_get"
    printf '%s' "old" >"$failed_get/Codex.dmg"
    cat >"$failed_get/Codex.dmg.metadata" <<EOF
url_sha256=$url_sha256
etag=old-etag
last_modified=Thu, 04 Jun 2026 00:00:00 GMT
content_length=3
EOF
    if run_dmg_cache_case "$failed_get" "$failed_get/output.log" \
        TEST_ETAG=fresh-etag \
        TEST_LAST_MODIFIED="Thu, 04 Jun 2026 00:00:00 GMT" \
        TEST_CONTENT_LENGTH=3 \
        TEST_GET_FAIL=1
    then
        fail "Expected failed replacement download to fail the refresh"
    fi
    [ "$(cat "$failed_get/Codex.dmg")" = "old" ] || fail "Expected failed refresh to preserve old DMG"
    assert_contains "$failed_get/Codex.dmg.metadata" "etag=old-etag"
    assert_file_not_exists "$failed_get/Codex.dmg.part"

    local head_failure="$workspace/head-failure"
    mkdir -p "$head_failure"
    printf '%s' "old" >"$head_failure/Codex.dmg"
    cat >"$head_failure/Codex.dmg.metadata" <<EOF
url_sha256=$url_sha256
etag=old-etag
last_modified=Thu, 04 Jun 2026 00:00:00 GMT
content_length=3
EOF
    run_dmg_cache_case "$head_failure" "$head_failure/output.log" TEST_HEAD_FAIL=1
    [ "$(cat "$head_failure/Codex.dmg")" = "old" ] || fail "Expected HEAD failure to preserve cache"
    assert_not_contains "$head_failure/curl.log" "GET"
    assert_contains "$head_failure/output.log" "Could not check upstream DMG metadata"

    local head_failure_mismatched_url="$workspace/head-failure-mismatched-url"
    mkdir -p "$head_failure_mismatched_url"
    printf '%s' "old" >"$head_failure_mismatched_url/Codex.dmg"
    cat >"$head_failure_mismatched_url/Codex.dmg.metadata" <<EOF
url_sha256=$url_sha256
etag=old-etag
last_modified=Thu, 04 Jun 2026 00:00:00 GMT
content_length=3
EOF
    if run_dmg_cache_case "$head_failure_mismatched_url" "$head_failure_mismatched_url/output.log" \
        CODEX_UPSTREAM_DMG_URL="https://example.com/Codex.dmg" \
        TEST_HEAD_FAIL=1 \
        TEST_GET_FAIL=1
    then
        fail "Expected HEAD failure with mismatched cached URL metadata to attempt refresh and fail"
    fi
    [ "$(cat "$head_failure_mismatched_url/Codex.dmg")" = "old" ] || fail "Expected failed mismatched-URL refresh to preserve old DMG"
    assert_contains "$head_failure_mismatched_url/Codex.dmg.metadata" "etag=old-etag"
    assert_contains "$head_failure_mismatched_url/curl.log" "GET"
    assert_contains "$head_failure_mismatched_url/output.log" "cached DMG URL metadata does not match current URL"

    local secret_url="$workspace/secret-url"
    mkdir -p "$secret_url"
    run_dmg_cache_case "$secret_url" "$secret_url/output.log" \
        CODEX_UPSTREAM_DMG_URL="https://user:secret@example.com/Codex.dmg?token=topsecret#fragsecret" \
        TEST_ETAG=opaque-etag \
        TEST_CONTENT_LENGTH=3 \
        TEST_DOWNLOAD_CONTENT=new
    [ "$(cat "$secret_url/Codex.dmg")" = "new" ] || fail "Expected HTTPS override URL to download"
    assert_contains "$secret_url/output.log" "URL: https://redacted@example.com/Codex.dmg?REDACTED"
    assert_not_contains "$secret_url/output.log" "topsecret"
    assert_not_contains "$secret_url/output.log" "fragsecret"
    assert_not_contains "$secret_url/Codex.dmg.metadata" "topsecret"
    assert_not_contains "$secret_url/Codex.dmg.metadata" "fragsecret"

    local invalid_url="$workspace/invalid-url"
    mkdir -p "$invalid_url"
    if run_dmg_cache_case "$invalid_url" "$invalid_url/output.log" \
        CODEX_UPSTREAM_DMG_URL="file:///tmp/Codex.dmg"
    then
        fail "Expected non-HTTPS upstream DMG URL to fail"
    fi
    assert_contains "$invalid_url/output.log" "Upstream DMG URL must be an HTTPS URL"
}

test_extract_dmg_repairs_safe_7z_link_warnings() {
    info "Checking DMG extraction repairs safe 7z package symlink warnings"
    local workspace="$TMP_DIR/dmg-dangerous-link-paths"
    local bin_dir="$workspace/bin"
    local work_dir="$workspace/work"
    local output_log="$workspace/output.log"
    local app_dir="$work_dir/dmg-extract/Codex Installer/Codex.app"
    local node_modules="$app_dir/Contents/Resources/cua_node/lib/node_modules"
    local actual

    mkdir -p "$bin_dir" "$work_dir"
    printf '%s' "fake dmg payload" >"$workspace/Codex.dmg"

    cat >"$bin_dir/7z" <<'SCRIPT'
#!/usr/bin/env bash
set -eu

out=""
for arg in "$@"; do
    case "$arg" in
        -o*)
            out="${arg#-o}"
            ;;
    esac
done
[ -n "$out" ] || exit 2

app="$out/Codex Installer/Codex.app"
node_modules="$app/Contents/Resources/cua_node/lib/node_modules"
mkdir -p \
    "$node_modules/.bin" \
    "$node_modules/@oai/sky/bin/linux" \
    "$node_modules/opencollective-postinstall" \
    "$node_modules/pixelmatch/bin" \
    "$node_modules/playwright" \
    "$node_modules/playwright-core" \
    "$node_modules/semver/bin" \
    "$node_modules/sharp/node_modules/.bin" \
    "$node_modules/tesseract.js/node_modules/.bin"

printf '%s\n' "target" >"$node_modules/opencollective-postinstall/index.js"
printf '%s\n' "target" >"$node_modules/pixelmatch/bin/pixelmatch"
printf '%s\n' "target" >"$node_modules/playwright/cli.js"
printf '%s\n' "target" >"$node_modules/playwright-core/cli.js"
printf '%s\n' "target" >"$node_modules/semver/bin/semver.js"
printf '%s\n' "target" >"$node_modules/@oai/sky/bin/linux/sky_linux_arm64"
printf '%s\n' "target" >"$node_modules/@oai/sky/bin/linux/sky_linux_x64"

: >"$node_modules/.bin/opencollective-postinstall"
: >"$node_modules/.bin/pixelmatch"
: >"$node_modules/.bin/playwright"
: >"$node_modules/.bin/playwright-core"
: >"$node_modules/.bin/semver"
: >"$node_modules/.bin/sky_linux_arm64"
: >"$node_modules/.bin/sky_linux_x64"
: >"$node_modules/tesseract.js/node_modules/.bin/opencollective-postinstall"
: >"$node_modules/sharp/node_modules/.bin/semver"

cat <<'LOG'
ERROR: Dangerous link path was ignored : Codex Installer/Codex.app/Contents/Resources/cua_node/lib/node_modules/.bin/opencollective-postinstall : ../opencollective-postinstall/index.js
ERROR: Dangerous link path was ignored : Codex Installer/Codex.app/Contents/Resources/cua_node/lib/node_modules/.bin/pixelmatch : ../pixelmatch/bin/pixelmatch
ERROR: Dangerous link path was ignored : Codex Installer/Codex.app/Contents/Resources/cua_node/lib/node_modules/.bin/playwright : ../playwright/cli.js
ERROR: Dangerous link path was ignored : Codex Installer/Codex.app/Contents/Resources/cua_node/lib/node_modules/.bin/playwright-core : ../playwright-core/cli.js
ERROR: Dangerous link path was ignored : Codex Installer/Codex.app/Contents/Resources/cua_node/lib/node_modules/.bin/semver : ../semver/bin/semver.js
ERROR: Dangerous link path was ignored : Codex Installer/Codex.app/Contents/Resources/cua_node/lib/node_modules/.bin/sky_linux_arm64 : ../@oai/sky/bin/linux/sky_linux_arm64
ERROR: Dangerous link path was ignored : Codex Installer/Codex.app/Contents/Resources/cua_node/lib/node_modules/.bin/sky_linux_x64 : ../@oai/sky/bin/linux/sky_linux_x64
ERROR: Dangerous link path was ignored : Codex Installer/Codex.app/Contents/Resources/cua_node/lib/node_modules/tesseract.js/node_modules/.bin/opencollective-postinstall : ../../../opencollective-postinstall/index.js
ERROR: Dangerous link path was ignored : Codex Installer/Codex.app/Contents/Resources/cua_node/lib/node_modules/sharp/node_modules/.bin/semver : ../../../semver/bin/semver.js

Sub items Errors: 9

Archives with Errors: 1

Sub items Errors: 9
LOG
exit 2
SCRIPT
    chmod +x "$bin_dir/7z"

    REPO_DIR="$REPO_DIR" \
    WORK_DIR="$work_dir" \
    SEVEN_ZIP_CMD="$bin_dir/7z" \
    TEST_DMG_PATH="$workspace/Codex.dmg" \
        bash <<'SCRIPT' >"$output_log" 2>&1
set -Eeuo pipefail

info() { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# shellcheck disable=SC1091
source "$REPO_DIR/scripts/lib/dmg.sh"

app_dir="$(extract_dmg "$TEST_DMG_PATH")"
[ "$(basename "$app_dir")" = "Codex.app" ]
SCRIPT

    assert_contains "$output_log" "7z reported 9 safe package symlink warnings; repaired and continuing"
    assert_not_contains "$output_log" "7z exited with code"
    assert_not_contains "$output_log" "Sub items Errors"

    [ -L "$node_modules/.bin/opencollective-postinstall" ] || fail "Expected repaired opencollective-postinstall symlink"
    [ "$(readlink "$node_modules/.bin/opencollective-postinstall")" = "../opencollective-postinstall/index.js" ] \
        || fail "Unexpected opencollective-postinstall symlink target"
    [ -L "$node_modules/.bin/pixelmatch" ] || fail "Expected repaired pixelmatch symlink"
    [ "$(readlink "$node_modules/.bin/pixelmatch")" = "../pixelmatch/bin/pixelmatch" ] \
        || fail "Unexpected pixelmatch symlink target"
    [ -L "$node_modules/.bin/playwright" ] || fail "Expected repaired playwright symlink"
    [ "$(readlink "$node_modules/.bin/playwright")" = "../playwright/cli.js" ] \
        || fail "Unexpected playwright symlink target"
    [ -L "$node_modules/.bin/playwright-core" ] || fail "Expected repaired playwright-core symlink"
    [ "$(readlink "$node_modules/.bin/playwright-core")" = "../playwright-core/cli.js" ] \
        || fail "Unexpected playwright-core symlink target"
    [ -L "$node_modules/.bin/semver" ] || fail "Expected repaired semver symlink"
    [ "$(readlink "$node_modules/.bin/semver")" = "../semver/bin/semver.js" ] \
        || fail "Unexpected semver symlink target"
    [ -L "$node_modules/.bin/sky_linux_arm64" ] || fail "Expected repaired sky_linux_arm64 symlink"
    [ "$(readlink "$node_modules/.bin/sky_linux_arm64")" = "../@oai/sky/bin/linux/sky_linux_arm64" ] \
        || fail "Unexpected sky_linux_arm64 symlink target"
    [ -L "$node_modules/.bin/sky_linux_x64" ] || fail "Expected repaired sky_linux_x64 symlink"
    [ "$(readlink "$node_modules/.bin/sky_linux_x64")" = "../@oai/sky/bin/linux/sky_linux_x64" ] \
        || fail "Unexpected sky_linux_x64 symlink target"
    [ -L "$node_modules/tesseract.js/node_modules/.bin/opencollective-postinstall" ] \
        || fail "Expected repaired nested opencollective-postinstall symlink"
    [ "$(readlink "$node_modules/tesseract.js/node_modules/.bin/opencollective-postinstall")" = "../../../opencollective-postinstall/index.js" ] \
        || fail "Unexpected nested opencollective-postinstall symlink target"
    [ -L "$node_modules/sharp/node_modules/.bin/semver" ] || fail "Expected repaired nested semver symlink"
    [ "$(readlink "$node_modules/sharp/node_modules/.bin/semver")" = "../../../semver/bin/semver.js" ] \
        || fail "Unexpected nested semver symlink target"

    actual="$(find "$node_modules" -path '*/.bin/*' -type l | wc -l | tr -d ' ')"
    [ "$actual" = "9" ] || fail "Expected 9 repaired symlinks, found $actual"
}

test_fresh_install_removes_cached_dmg_metadata() {
    info "Checking --fresh removes cached DMG metadata"
    local workspace="$TMP_DIR/fresh-dmg-metadata"
    local source_dir="$workspace/source"

    mkdir -p "$source_dir"
    printf '%s' "cached" >"$source_dir/Codex.dmg"
    printf '%s' "metadata" >"$source_dir/Codex.dmg.metadata"

    TEST_SOURCE_DIR="$source_dir" REPO_DIR="$REPO_DIR" bash <<'SCRIPT'
set -Eeuo pipefail

SCRIPT_DIR="$TEST_SOURCE_DIR"
WORK_DIR="$(mktemp -d)"
INSTALL_DIR="$TEST_SOURCE_DIR/codex-app"
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/lib/install-helpers.sh"

FRESH_INSTALL=1
REUSE_CACHED_DMG=0
prepare_install
SCRIPT

    assert_file_not_exists "$source_dir/Codex.dmg"
    assert_file_not_exists "$source_dir/Codex.dmg.metadata"
}

test_fresh_pinned_dmg_preserves_cached_dmg_metadata() {
    info "Checking --fresh preserves cached DMG metadata in pinned refresh mode"
    local workspace="$TMP_DIR/fresh-pinned-dmg-metadata"
    local source_dir="$workspace/source"

    mkdir -p "$source_dir"
    printf '%s' "cached" >"$source_dir/Codex.dmg"
    printf '%s' "metadata" >"$source_dir/Codex.dmg.metadata"

    TEST_SOURCE_DIR="$source_dir" REPO_DIR="$REPO_DIR" bash <<'SCRIPT'
set -Eeuo pipefail

SCRIPT_DIR="$TEST_SOURCE_DIR"
WORK_DIR="$(mktemp -d)"
INSTALL_DIR="$TEST_SOURCE_DIR/codex-app"
CODEX_DMG_REFRESH_MODE=pinned
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/lib/install-helpers.sh"

FRESH_INSTALL=1
REUSE_CACHED_DMG=0
prepare_install
SCRIPT

    assert_file_exists "$source_dir/Codex.dmg"
    assert_file_exists "$source_dir/Codex.dmg.metadata"
}

test_fresh_reuse_dmg_uses_cache_when_metadata_matches() {
    info "Checking --fresh --reuse-dmg reuses cached DMG when metadata matches"
    local workspace="$TMP_DIR/fresh-reuse-dmg-metadata"
    local bin_dir="$workspace/bin"
    local source_dir="$workspace/source"
    local output_log="$workspace/output.log"
    local url="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
    local url_sha256

    url_sha256="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"

    mkdir -p "$bin_dir" "$source_dir"
    printf '%s' "cached" >"$source_dir/Codex.dmg"
    cat >"$source_dir/Codex.dmg.metadata" <<EOF
url_sha256=$url_sha256
etag=same-etag
last_modified=Thu, 04 Jun 2026 00:00:00 GMT
content_length=6
EOF

    cat >"$bin_dir/curl" <<'SCRIPT'
#!/usr/bin/env bash
set -eu

is_head=0
for arg in "$@"; do
    if [ "$arg" = "-fsSLI" ]; then
        is_head=1
    fi
done

if [ "$is_head" -eq 1 ]; then
    printf '%s\n' "HEAD" >> "$TEST_CURL_LOG"
    printf 'HTTP/2 200\r\n'
    printf 'ETag: same-etag\r\n'
    printf 'Last-Modified: Thu, 04 Jun 2026 00:00:00 GMT\r\n'
    printf 'Content-Length: 6\r\n'
    printf '\r\n'
    exit 0
fi

printf '%s\n' "GET" >> "$TEST_CURL_LOG"
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        out="$1"
    fi
    shift || true
done

[ -n "$out" ] || exit 2
printf '%s' "downloaded" >"$out"
SCRIPT
    chmod +x "$bin_dir/curl"
    : >"$source_dir/curl.log"

    PATH="$bin_dir:$PATH" \
    TEST_CURL_LOG="$source_dir/curl.log" \
    TEST_SOURCE_DIR="$source_dir" \
    REPO_DIR="$REPO_DIR" \
        bash <<'SCRIPT' >"$output_log" 2>&1
set -Eeuo pipefail

SCRIPT_DIR="$TEST_SOURCE_DIR"
WORK_DIR="$(mktemp -d)"
INSTALL_DIR="$TEST_SOURCE_DIR/codex-app"
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/lib/install-helpers.sh"
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/lib/dmg.sh"

FRESH_INSTALL=1
REUSE_CACHED_DMG=1
prepare_install

dmg_path="$(get_dmg)"
[ "$dmg_path" = "$TEST_SOURCE_DIR/Codex.dmg" ]
SCRIPT

    assert_file_exists "$source_dir/Codex.dmg"
    assert_file_exists "$source_dir/Codex.dmg.metadata"
    [ "$(cat "$source_dir/Codex.dmg")" = "cached" ] || fail "Expected matching metadata to keep cached DMG"
    assert_contains "$source_dir/curl.log" "HEAD"
    assert_not_contains "$source_dir/curl.log" "GET"
    assert_contains "$output_log" "Using cached DMG"
}

test_rebuild_candidate_uses_validated_default_dmg() {
    info "Checking rebuild-candidate default DMG validation flow"
    local workspace="$TMP_DIR/rebuild-candidate-dmg"
    local repo="$workspace/repo"
    local explicit_dmg="$workspace/explicit.dmg"
    local explicit_realpath
    local first_line
    local second_line

    mkdir -p "$repo/scripts"
    cp "$REPO_DIR/scripts/rebuild-candidate.sh" "$repo/scripts/rebuild-candidate.sh"
    printf '%s' "cached" >"$repo/Codex.dmg"
    printf '%s' "explicit" >"$explicit_dmg"
    explicit_realpath="$(realpath "$explicit_dmg")"

    cat >"$repo/install.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -eu
{
    printf 'CALL:'
    for arg in "$@"; do
        printf '<%s>' "$arg"
    done
    printf '\n'
} >> "$TEST_REBUILD_LOG"
SCRIPT
    chmod +x "$repo/install.sh"

    TEST_REBUILD_LOG="$workspace/default.log" \
    CODEX_NEXT_APP_DIR="$workspace/next" \
    REBUILD_REPORT_DIR="$workspace/report" \
        bash "$repo/scripts/rebuild-candidate.sh" >"$workspace/default.out" 2>&1
    first_line="$(sed -n '1p' "$workspace/default.log")"
    second_line="$(sed -n '2p' "$workspace/default.log")"
    [[ "$first_line" != *"Codex.dmg"* ]] || fail "Default inspect should let installer validate the cache: $first_line"
    [[ "$second_line" == *"<$repo/Codex.dmg>"* ]] || fail "Default build should pin the validated cache: $second_line"
    assert_contains "$workspace/default.out" "Using validated DMG for build"

    TEST_REBUILD_LOG="$workspace/explicit.log" \
    CODEX_NEXT_APP_DIR="$workspace/next-explicit" \
    REBUILD_REPORT_DIR="$workspace/report-explicit" \
        bash "$repo/scripts/rebuild-candidate.sh" "$explicit_dmg" >"$workspace/explicit.out" 2>&1
    first_line="$(sed -n '1p' "$workspace/explicit.log")"
    second_line="$(sed -n '2p' "$workspace/explicit.log")"
    [[ "$first_line" == *"<$explicit_realpath>"* ]] || fail "Explicit inspect should receive explicit DMG: $first_line"
    [[ "$second_line" == *"<$explicit_realpath>"* ]] || fail "Explicit build should receive explicit DMG: $second_line"
}

test_native_shortcut_targets_compose_existing_flows() {
    info "Checking native install/update shortcut targets"
    local install_log="$TMP_DIR/make-install-native.log"
    local bootstrap_log="$TMP_DIR/make-bootstrap-native.log"
    local update_log="$TMP_DIR/make-update-native.log"

    make -n -C "$REPO_DIR" install-native >"$install_log"
    assert_contains "$install_log" './install.sh --fresh --reuse-dmg'
    assert_contains "$install_log" 'Building native package'
    assert_contains "$install_log" 'Installing latest native package'

    make -n -C "$REPO_DIR" bootstrap-native >"$bootstrap_log"
    assert_contains "$bootstrap_log" 'bash scripts/install-deps.sh'
    assert_contains "$bootstrap_log" 'PATH="$HOME/.cargo/bin:$PATH"'
    assert_contains "$bootstrap_log" 'install-native'

    make -n -C "$REPO_DIR" update-native >"$update_log"
    assert_contains "$update_log" 'git pull --ff-only'
    assert_contains "$update_log" 'install-native'
}

make_update_nix_hash_fixture() {
    local fixture="$1"
    local hash_a="sha256-VVQNu/E7Wuyxfsy93Gorknr0t7H7wy9kxMOiBZYOo/o="

    mkdir -p "$fixture/scripts/ci" "$fixture/nix/native-modules" "$fixture/bin"
    cp "$REPO_DIR/scripts/ci/update-nix-hashes.sh" "$fixture/scripts/ci/update-nix-hashes.sh"
    chmod +x "$fixture/scripts/ci/update-nix-hashes.sh"

    cat > "$fixture/flake.nix" <<EOF
{
  codexVersion = "26.623.81905";
  electronVersion = "42.1.0";

  codexDmg = pkgs.fetchurl {
    url = "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg";
    hash = "$hash_a";
  };

  x86_64-linux = {
    hash = "$hash_a";
  };

  aarch64-linux = {
    hash = "$hash_a";
  };

  electronHeaders = pkgs.fetchurl {
    hash = "$hash_a";
  };
}
EOF
    printf '%s\n' '{"dependencies":{"electron":"42.1.0","better-sqlite3":"12.9.0","node-pty":"1.1.0"}}' \
        > "$fixture/nix/native-modules/package.json"
    printf '%s\n' '{"name":"native-modules","lockfileVersion":3,"packages":{}}' \
        > "$fixture/nix/native-modules/package-lock.json"

    cat > "$fixture/scripts/ci/validate-nix-pins.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "validate stub invoked"
if [ "${VALIDATE_PIN_CHANGE:-0}" = "1" ]; then
    python3 - "$REPO_DIR/flake.nix" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(r'(codexVersion\s*=\s*")[^"]+(";)', r'\g<1>99.0.0\2', text, count=1)
path.write_text(text)
PY
fi
EOF
    chmod +x "$fixture/scripts/ci/validate-nix-pins.sh"

    cat > "$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            shift
            out="${1:-}"
            ;;
    esac
    shift || true
done
if [ -n "$out" ]; then
    printf 'fake dmg\n' > "$out"
    exit 0
fi
version="26.623.81905"
if [ "${VALIDATE_PIN_CHANGE:-0}" = "1" ]; then
    version="99.0.0"
fi
printf '<rss><channel><item><sparkle:shortVersionString>%s</sparkle:shortVersionString></item></channel></rss>\n' "$version"
EOF
    chmod +x "$fixture/bin/curl"

    cat > "$fixture/bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    hash)
        printf '%s\n' "${NIX_HASH:-sha256-VVQNu/E7Wuyxfsy93Gorknr0t7H7wy9kxMOiBZYOo/o=}"
        ;;
    store)
        printf '{"hash":"%s"}\n' "${NIX_HASH:-sha256-VVQNu/E7Wuyxfsy93Gorknr0t7H7wy9kxMOiBZYOo/o=}"
        ;;
    build)
        printf 'nix %s\n' "$*" >> "$CALL_LOG"
        printf 'fake nix build ok\n'
        ;;
    *)
        echo "unexpected nix call: $*" >&2
        exit 2
        ;;
esac
EOF
    chmod +x "$fixture/bin/nix"

    cat > "$fixture/bin/nix-store" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nix-store %s\n' "$*" >> "$CALL_LOG"
EOF
    chmod +x "$fixture/bin/nix-store"

    cat > "$fixture/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'npm %s\n' "$*" >> "$CALL_LOG"
EOF
    chmod +x "$fixture/bin/npm"

    git -C "$fixture" init -q
    git -C "$fixture" config user.name "Test"
    git -C "$fixture" config user.email "test@example.invalid"
    git -C "$fixture" add flake.nix nix/native-modules/package.json nix/native-modules/package-lock.json
    git -C "$fixture" commit -q -m "fixture"
}

run_update_nix_hash_fixture() {
    local label="$1"
    local validate_pin_change="$2"
    local nix_hash="$3"
    local fixture="$TMP_DIR/$label"

    make_update_nix_hash_fixture "$fixture"
    : > "$fixture/calls.log"
    PATH="$fixture/bin:$PATH" \
        REPO_DIR="$fixture" \
        FLAKE_FILE="$fixture/flake.nix" \
        UPSTREAM_DMG_PATH="$fixture/Codex.dmg" \
        VERIFY_LOG="$fixture/verify.log" \
        CALL_LOG="$fixture/calls.log" \
        VALIDATE_PIN_CHANGE="$validate_pin_change" \
        NIX_HASH="$nix_hash" \
        bash "$fixture/scripts/ci/update-nix-hashes.sh" > "$fixture/output.log" 2>&1
}

test_update_nix_hashes_skips_unchanged_package_verification() {
    info "Checking Nix hash refresh skips package verification when pins are unchanged"
    local fixture="$TMP_DIR/nix-hash-refresh-unchanged"
    local hash_a="sha256-VVQNu/E7Wuyxfsy93Gorknr0t7H7wy9kxMOiBZYOo/o="

    run_update_nix_hash_fixture "$(basename "$fixture")" 0 "$hash_a"

    assert_contains "$fixture/output.log" "Nix pins unchanged; skipping package-output verification."
    assert_not_contains "$fixture/calls.log" "nix-store"
    assert_not_contains "$fixture/calls.log" "nix build"
}

test_update_nix_hashes_verifies_changed_pins() {
    info "Checking Nix hash refresh still verifies changed pins"
    local fixture="$TMP_DIR/nix-hash-refresh-version-change"
    local hash_a="sha256-VVQNu/E7Wuyxfsy93Gorknr0t7H7wy9kxMOiBZYOo/o="

    run_update_nix_hash_fixture "$(basename "$fixture")" 1 "$hash_a"

    assert_contains "$fixture/output.log" "Nix builds succeeded after refreshing the upstream pins and Codex.dmg hash."
    assert_contains "$fixture/calls.log" "nix-store --add-fixed"
    assert_contains "$fixture/calls.log" "nix build"
}

test_update_nix_hashes_verifies_changed_dmg_hash() {
    info "Checking Nix hash refresh still verifies changed DMG hashes"
    local fixture="$TMP_DIR/nix-hash-refresh-dmg-hash-change"
    local hash_b="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    run_update_nix_hash_fixture "$(basename "$fixture")" 0 "$hash_b"

    assert_contains "$fixture/output.log" "Nix builds succeeded after refreshing the upstream pins and Codex.dmg hash."
    assert_contains "$fixture/calls.log" "nix-store --add-fixed"
    assert_contains "$fixture/calls.log" "nix build"
}

test_installer_detects_electron_version_from_plist() {
    info "Checking Electron version detection from app metadata"
    local workspace="$TMP_DIR/electron-version"
    local app_dir="$workspace/Codex.app"
    local plist_dir="$app_dir/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources"
    local output_log="$workspace/output.log"

    mkdir -p "$plist_dir"
    cat > "$plist_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleVersion</key>
    <string>42.5.7</string>
</dict>
</plist>
PLIST

    CODEX_INSTALLER_SOURCE_ONLY=1 bash -c \
        'source "$1"; detect_electron_version "$2"; printf "%s\n" "$ELECTRON_VERSION"' \
        _ "$REPO_DIR/install.sh" "$app_dir" >"$output_log" 2>&1

    assert_contains "$output_log" "Detected Electron version from DMG: 42.5.7"
    [ "$(tail -n 1 "$output_log")" = "42.5.7" ] || fail "Expected detected Electron version 42.5.7, got: $(cat "$output_log")"
}

test_installer_keeps_electron_fallback_for_bad_metadata() {
    info "Checking Electron version fallback for malformed metadata"
    local workspace="$TMP_DIR/electron-version-fallback"
    local app_dir="$workspace/Codex.app"
    local plist_dir="$app_dir/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources"
    local output_log="$workspace/output.log"

    mkdir -p "$plist_dir"
    cat > "$plist_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleVersion</key>
    <string>not-a-version</string>
</dict>
</plist>
PLIST

    CODEX_INSTALLER_SOURCE_ONLY=1 bash -c \
        'source "$1"; detect_electron_version "$2"; printf "%s\n" "$ELECTRON_VERSION"' \
        _ "$REPO_DIR/install.sh" "$app_dir" >"$output_log" 2>&1

    assert_contains "$output_log" "Ignoring invalid Electron version from DMG: not-a-version"
    assert_contains "$output_log" "Could not auto-detect Electron version; using fallback 41.3.0"
    [ "$(tail -n 1 "$output_log")" = "41.3.0" ] || fail "Expected fallback Electron version 41.3.0, got: $(cat "$output_log")"
}

test_port_validation_rejects_oversized_numeric_values() {
    info "Checking oversized numeric webview port validation"
    local workspace="$TMP_DIR/port-validation"
    local install_stdout="$workspace/install.stdout"
    local install_stderr="$workspace/install.stderr"
    local launcher_stdout="$workspace/launcher.stdout"
    local launcher_stderr="$workspace/launcher.stderr"
    local canonical_stdout="$workspace/canonical.stdout"
    local canonical_stderr="$workspace/canonical.stderr"
    local launcher_probe_script="$workspace/launcher-port-probe.sh"
    local start_script="$workspace/start.sh"
    local huge_port="999999999999999999999999"
    local rc

    mkdir -p "$workspace"

    set +e
    CODEX_INSTALLER_SOURCE_ONLY=1 CODEX_WEBVIEW_PORT="$huge_port" bash -c \
        'source "$1"; validate_app_identity' \
        _ "$REPO_DIR/install.sh" >"$install_stdout" 2>"$install_stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected installer validation to reject oversized CODEX_WEBVIEW_PORT"
    assert_contains "$install_stderr" "CODEX_WEBVIEW_PORT must be between 1 and 65535"
    assert_not_contains "$install_stderr" "integer expected"

    CODEX_INSTALLER_SOURCE_ONLY=1 CODEX_WEBVIEW_PORT=00080 bash -c \
        'source "$1"; validate_app_identity; printf "%s\n" "$CODEX_WEBVIEW_PORT"' \
        _ "$REPO_DIR/install.sh" >"$canonical_stdout" 2>"$canonical_stderr"
    [ "$(cat "$canonical_stdout")" = "80" ] || fail "Expected installer validation to canonicalize leading-zero CODEX_WEBVIEW_PORT"
    [ ! -s "$canonical_stderr" ] || fail "Expected installer leading-zero canonicalization to be quiet, got: $(cat "$canonical_stderr")"

    cat > "$start_script" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
CODEX_LINUX_APP_ID=codex-desktop
CODEX_LINUX_APP_DISPLAY_NAME=Codex
CODEX_LINUX_WEBVIEW_PORT=${CODEX_WEBVIEW_PORT:-5175}
SCRIPT
    cat "$REPO_DIR/launcher/start.sh.template" >> "$start_script"
    chmod +x "$start_script"

    set +e
    CODEX_WEBVIEW_PORT="$huge_port" "$start_script" --help >"$launcher_stdout" 2>"$launcher_stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected launcher validation to reject oversized CODEX_WEBVIEW_PORT"
    assert_contains "$launcher_stderr" "CODEX_WEBVIEW_PORT must be between 1 and 65535"
    assert_not_contains "$launcher_stderr" "integer expected"

    XDG_CONFIG_HOME="$workspace/help-config" bash "$start_script" --help >"$launcher_stdout" 2>"$launcher_stderr"
    assert_contains "$launcher_stdout" "electron-flags.conf"
    assert_file_not_exists "$workspace/help-config/codex-desktop/electron-flags.conf"

    cat > "$launcher_probe_script" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
CODEX_LINUX_WEBVIEW_PORT=${CODEX_WEBVIEW_PORT:-5175}
SCRIPT
    awk '
        /^normalize_tcp_port\(\) \{/ { emit = 1 }
        /^launcher_port_is_open\(\) \{/ { exit }
        emit { print }
    ' "$REPO_DIR/launcher/start.sh.template" >> "$launcher_probe_script"
    cat >> "$launcher_probe_script" <<'SCRIPT'
printf '%s\n' "$CODEX_LINUX_WEBVIEW_PORT"
SCRIPT
    chmod +x "$launcher_probe_script"
    CODEX_WEBVIEW_PORT=00080 "$launcher_probe_script" >"$launcher_stdout" 2>"$launcher_stderr"
    [ "$(tail -n 1 "$launcher_stdout")" = "80" ] || fail "Expected launcher validation to canonicalize leading-zero CODEX_WEBVIEW_PORT"
    [ ! -s "$launcher_stderr" ] || fail "Expected launcher leading-zero canonicalization to be quiet, got: $(cat "$launcher_stderr")"
}

test_managed_node_runtime_source_install() {
    info "Checking managed Node.js runtime source install"
    local workspace="$TMP_DIR/managed-node-runtime"
    local source_dir="$workspace/source"
    local install_dir="$workspace/install"

    mkdir -p "$source_dir/bin" "$install_dir/resources"
    for binary in node npm npx; do
        cat > "$source_dir/bin/$binary" <<'SCRIPT'
#!/usr/bin/env bash
case "$(basename "$0")" in
    node) echo v22.22.2 ;;
    *) echo 10.9.7 ;;
esac
SCRIPT
        chmod +x "$source_dir/bin/$binary"
    done

    (
        SCRIPT_DIR="$REPO_DIR"
        WORK_DIR="$workspace/work"
        ARCH="x86_64"
        CODEX_MANAGED_NODE_SOURCE="$source_dir"
        mkdir -p "$WORK_DIR"
        info() { echo "[INFO] $*" >&2; }
        warn() { echo "[WARN] $*" >&2; }
        error() { echo "[ERROR] $*" >&2; exit 1; }
        # shellcheck disable=SC1091
        source "$REPO_DIR/scripts/lib/node-runtime.sh"
        ensure_managed_node_runtime "$install_dir/resources/node-runtime"
        command -v node
        node -v
    ) > "$workspace/output.log" 2>&1

    assert_file_exists "$install_dir/resources/node-runtime/bin/node"
    assert_contains "$workspace/output.log" "$install_dir/resources/node-runtime/bin/node"
    assert_contains "$workspace/output.log" "v22.22.2"
}

test_better_sqlite3_electron_42_source_patch() {
    info "Checking better-sqlite3 Electron 42 source patch"
    local workspace="$TMP_DIR/better-sqlite3-electron-42"
    local module_dir="$workspace/node_modules/better-sqlite3"
    local output_log="$workspace/output.log"

    mkdir -p "$module_dir/src/util"
    cat > "$module_dir/src/better_sqlite3.cpp" <<'CPP'
void init(v8::Isolate* isolate, Addon* addon) {
	v8::Local<v8::External> data = v8::External::New(isolate, addon);
}
CPP
    cat > "$module_dir/src/util/macros.cpp" <<'CPP'
#define EasyIsolate v8::Isolate* isolate = v8::Isolate::GetCurrent()
#define OnlyIsolate info.GetIsolate()
#define OnlyContext isolate->GetCurrentContext()
#define OnlyAddon static_cast<Addon*>(info.Data().As<v8::External>()->Value())
CPP
    cat > "$module_dir/src/util/helpers.cpp" <<'CPP'
void SetPrototypeGetter() {
	recv->InstanceTemplate()->SetNativeDataProperty(
		InternalizedFromLatin1(isolate, name),
		func,
		0,
		data
	);
}
CPP

    (
        ELECTRON_VERSION="42.0.1"
        info() { echo "[INFO] $*" >&2; }
        warn() { echo "[WARN] $*" >&2; }
        error() { echo "[ERROR] $*" >&2; exit 1; }
        # shellcheck disable=SC1091
        source "$REPO_DIR/scripts/lib/native-modules.sh"
        patch_better_sqlite3_for_v8_external_pointer_api "$module_dir"
        patch_better_sqlite3_for_v8_external_pointer_api "$module_dir"
    ) > "$output_log" 2>&1

    assert_contains "$module_dir/src/better_sqlite3.cpp" "BETTER_SQLITE3_EXTERNAL_NEW(isolate, addon)"
    assert_contains "$module_dir/src/util/macros.cpp" "BETTER_SQLITE3_EXTERNAL_POINTER_TAG"
    assert_contains "$module_dir/src/util/macros.cpp" "BETTER_SQLITE3_EXTERNAL_VALUE(info.Data().As<v8::External>())"
    assert_contains "$module_dir/src/util/helpers.cpp" "nullptr"
    assert_contains "$output_log" "Patched better-sqlite3 source for V8 external pointer API"
    assert_contains "$output_log" "already applied"
}

test_native_module_rebuild_uses_local_electron_rebuild_toolchain() {
    info "Checking native module rebuild uses local Electron rebuild toolchain"
    local workspace="$TMP_DIR/native-module-rebuild-toolchain"
    local app_dir="$workspace/app-extracted"
    local fake_bin="$workspace/bin"
    local toolchain_log="$workspace/toolchain.log"
    local output_log="$workspace/output.log"

    mkdir -p "$app_dir/node_modules/better-sqlite3" "$app_dir/node_modules/node-pty" "$fake_bin"
    printf '%s\n' '{"version":"12.9.0"}' > "$app_dir/node_modules/better-sqlite3/package.json"
    printf '%s\n' '{"version":"1.1.0"}' > "$app_dir/node_modules/node-pty/package.json"

    cat > "$fake_bin/npm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

printf 'npm %s\n' "$*" >> "$NATIVE_TOOLCHAIN_LOG"
args=" $* "

case "$args" in
    *" @electron/rebuild@4.0.4 "*)
        mkdir -p node_modules/@electron/rebuild/lib
        cat > node_modules/@electron/rebuild/lib/cli.js <<'REBUILD'
#!/usr/bin/env node
const fs = require("fs");
fs.appendFileSync(process.env.NATIVE_TOOLCHAIN_LOG, `electron-rebuild ${process.argv.slice(2).join(" ")}\n`);
fs.mkdirSync("node_modules/better-sqlite3/build/Release", { recursive: true });
fs.mkdirSync("node_modules/node-pty/build/Release", { recursive: true });
fs.closeSync(fs.openSync("node_modules/better-sqlite3/build/Release/better_sqlite3.node", "w"));
fs.closeSync(fs.openSync("node_modules/node-pty/build/Release/pty.node", "w"));
REBUILD
        ;;
esac

case "$args" in
    *" better-sqlite3@12.9.0 "*)
        mkdir -p node_modules/better-sqlite3/src/util
        printf '%s\n' '{"version":"12.9.0"}' > node_modules/better-sqlite3/package.json
        cat > node_modules/better-sqlite3/src/better_sqlite3.cpp <<'CPP'
void init(v8::Isolate* isolate, Addon* addon) {
	v8::Local<v8::External> data = v8::External::New(isolate, addon);
}
CPP
        cat > node_modules/better-sqlite3/src/util/macros.cpp <<'CPP'
#define EasyIsolate v8::Isolate* isolate = v8::Isolate::GetCurrent()
#define OnlyIsolate info.GetIsolate()
#define OnlyContext isolate->GetCurrentContext()
#define OnlyAddon static_cast<Addon*>(info.Data().As<v8::External>()->Value())
CPP
        cat > node_modules/better-sqlite3/src/util/helpers.cpp <<'CPP'
void SetPrototypeGetter() {
	recv->InstanceTemplate()->SetNativeDataProperty(
		InternalizedFromLatin1(isolate, name),
		func,
		0,
		data
	);
}
CPP
        ;;
esac

case "$args" in
    *" node-pty@1.1.0 "*)
        mkdir -p node_modules/node-pty
        printf '%s\n' '{"version":"1.1.0"}' > node_modules/node-pty/package.json
        ;;
esac
SCRIPT
    chmod +x "$fake_bin/npm"

    cat > "$fake_bin/c++" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
    chmod +x "$fake_bin/c++"

    cat > "$fake_bin/npx" <<'SCRIPT'
#!/usr/bin/env bash
echo "npx should not be used for electron-rebuild" >&2
exit 99
SCRIPT
    chmod +x "$fake_bin/npx"

    (
        PATH="$fake_bin:$PATH"
        export PATH
        NATIVE_TOOLCHAIN_LOG="$toolchain_log"
        export NATIVE_TOOLCHAIN_LOG
        WORK_DIR="$workspace/work"
        ELECTRON_VERSION="42.0.1"
        ELECTRON_HEADERS_URL="https://example.invalid/electron"
        mkdir -p "$WORK_DIR"
        info() { echo "[INFO] $*" >&2; }
        warn() { echo "[WARN] $*" >&2; }
        error() { echo "[ERROR] $*" >&2; exit 1; }
        # shellcheck disable=SC1091
        source "$REPO_DIR/scripts/lib/native-modules.sh"
        build_native_modules "$app_dir"
    ) > "$output_log" 2>&1

    assert_contains "$toolchain_log" "@electron/rebuild@4.0.4"
    assert_contains "$toolchain_log" "node-abi@^4.31.0"
    assert_contains "$toolchain_log" "electron-rebuild -v 42.0.1 --force --dist-url https://example.invalid/electron"
    assert_contains "$output_log" "Native modules built successfully"
    assert_file_exists "$app_dir/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
    assert_file_exists "$app_dir/node_modules/node-pty/build/Release/pty.node"
}

test_native_module_rebuild_accepts_prebuilt_source() {
    info "Checking native module rebuild accepts prebuilt source"
    local workspace="$TMP_DIR/native-module-prebuilt-source"
    local app_dir="$workspace/app-extracted"
    local source_dir="$workspace/prebuilt"
    local output_log="$workspace/output.log"

    mkdir -p \
        "$app_dir/node_modules/better-sqlite3" \
        "$app_dir/node_modules/node-pty" \
        "$source_dir/better-sqlite3/build/Release" \
        "$source_dir/node-pty/build/Release"
    printf '%s\n' '{"version":"12.9.0"}' > "$app_dir/node_modules/better-sqlite3/package.json"
    printf '%s\n' '{"version":"1.1.0"}' > "$app_dir/node_modules/node-pty/package.json"
    printf '%s\n' stale > "$app_dir/node_modules/better-sqlite3/old.txt"

    printf '%s\n' '{"version":"12.9.0"}' > "$source_dir/better-sqlite3/package.json"
    printf '%s\n' '{"version":"1.1.0"}' > "$source_dir/node-pty/package.json"
    : > "$source_dir/better-sqlite3/build/Release/better_sqlite3.node"
    : > "$source_dir/better-sqlite3/build/Release/junk.o"
    : > "$source_dir/node-pty/build/Release/pty.node"
    : > "$source_dir/node-pty/build/Release/junk.o"

    (
        WORK_DIR="$workspace/work"
        ELECTRON_VERSION="42.0.1"
        CODEX_NATIVE_MODULES_SOURCE="$source_dir"
        mkdir -p "$WORK_DIR"
        info() { echo "[INFO] $*" >&2; }
        warn() { echo "[WARN] $*" >&2; }
        error() { echo "[ERROR] $*" >&2; exit 1; }
        # shellcheck disable=SC1091
        source "$REPO_DIR/scripts/lib/native-modules.sh"
        build_native_modules "$app_dir"
    ) > "$output_log" 2>&1

    assert_contains "$output_log" "Using prebuilt native modules from $source_dir"
    assert_file_exists "$app_dir/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
    assert_file_exists "$app_dir/node_modules/node-pty/build/Release/pty.node"
    [ ! -f "$app_dir/node_modules/better-sqlite3/old.txt" ] || fail "Expected stale better-sqlite3 module to be replaced"
    [ ! -f "$app_dir/node_modules/better-sqlite3/build/Release/junk.o" ] || fail "Expected better-sqlite3 build junk to be pruned"
    [ ! -f "$app_dir/node_modules/node-pty/build/Release/junk.o" ] || fail "Expected node-pty build junk to be pruned"
}

test_bundled_plugin_builders_accept_prebuilt_binaries() {
    info "Checking bundled plugin builders accept prebuilt binaries"
    local workspace="$TMP_DIR/bundled-plugin-prebuilt-binaries"
    local backend="$workspace/codex-computer-use-linux"
    local cosmic="$workspace/codex-computer-use-cosmic"
    local host="$workspace/codex-chrome-extension-host"
    local output_log="$workspace/output.log"

    mkdir -p "$workspace"
    printf '#!/usr/bin/env bash\n' > "$backend"
    printf '#!/usr/bin/env bash\n' > "$cosmic"
    printf '#!/usr/bin/env bash\n' > "$host"
    chmod +x "$backend" "$cosmic" "$host"

    (
        SCRIPT_DIR="$REPO_DIR"
        CODEX_LINUX_COMPUTER_USE_BACKEND_SOURCE="$backend"
        CODEX_LINUX_COMPUTER_USE_COSMIC_SOURCE="$cosmic"
        CODEX_CHROME_EXTENSION_HOST_SOURCE="$host"
        info() { echo "[INFO] $*" >&2; }
        warn() { echo "[WARN] $*" >&2; }
        error() { echo "[ERROR] $*" >&2; exit 1; }
        # shellcheck disable=SC1091
        source "$REPO_DIR/scripts/lib/bundled-plugins.sh"
        build_linux_computer_use_backend
        build_chrome_extension_host
    ) > "$output_log" 2>&1

    assert_contains "$output_log" "Using prebuilt Linux Computer Use backend"
    assert_contains "$output_log" "Using prebuilt Chrome extension host"
    assert_contains "$output_log" "$backend"
    assert_contains "$output_log" "$cosmic"
    assert_contains "$output_log" "$host"
}

test_launcher_template_sanity() {
    info "Checking launcher template markers"
    assert_contains "$REPO_DIR/install.sh" 'DEFAULT_CODEX_WEBVIEW_PORT=5175'
    assert_contains "$REPO_DIR/install.sh" "inspect_rebuild_candidate"
    assert_contains "$REPO_DIR/scripts/lib/install-helpers.sh" "--inspect"
    assert_contains "$REPO_DIR/scripts/lib/install-helpers.sh" "--report-dir"
    assert_contains "$REPO_DIR/scripts/lib/asar-patch.sh" "CODEX_PATCH_REPORT_JSON"
    assert_contains "$REPO_DIR/scripts/lib/rebuild-report.sh" "write_rebuild_report_json"
    assert_contains "$REPO_DIR/install.sh" "MIN_BETTER_SQLITE3_VERSION_FOR_ELECTRON_41=\"12.9.0\""
    assert_contains "$REPO_DIR/scripts/lib/native-modules.sh" "better_sqlite3_build_version"
    assert_contains "$REPO_DIR/scripts/lib/native-modules.sh" "patch_better_sqlite3_for_v8_external_pointer_api"
    assert_contains "$REPO_DIR/scripts/lib/native-modules.sh" "@electron/rebuild@4.0.4"
    assert_contains "$REPO_DIR/scripts/lib/native-modules.sh" "node-abi@^4.31.0"
    assert_contains "$REPO_DIR/scripts/lib/native-modules.sh" 'node_modules/@electron/rebuild/lib/cli.js'
    assert_not_contains "$REPO_DIR/scripts/lib/native-modules.sh" "npx --yes @electron/rebuild"
    assert_contains "$REPO_DIR/scripts/lib/native-modules.sh" "prune_native_module_build_artifacts"
    assert_contains "$REPO_DIR/scripts/lib/native-modules.sh" 'find "$build_dir" -type f ! -name'
    assert_contains "$REPO_DIR/scripts/lib/native-modules.sh" 'find "$module_dir" -type f -name'
    assert_contains "$REPO_DIR/scripts/lib/native-modules.sh" "CODEX_ELECTRON_CACHE_DIR"
    assert_contains "$REPO_DIR/scripts/lib/native-modules.sh" "--continue-at -"
    assert_file_exists "$REPO_DIR/launcher/webview-server.py"
    assert_contains "$REPO_DIR/launcher/webview-server.py" "Cache-Control"
    assert_contains "$REPO_DIR/launcher/webview-server.py" "If-Modified-Since"
    assert_contains "$REPO_DIR/install.sh" "webview-server.py"
    assert_contains "$REPO_DIR/launcher/start.sh.template" 'python3 "$SCRIPT_DIR/.codex-linux/webview-server.py" "$CODEX_LINUX_WEBVIEW_PORT" --bind 127.0.0.1'
    assert_contains "$REPO_DIR/launcher/start.sh.template" "WEBVIEW_PID_FILE"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "owned_webview_server_pid"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "discover_webview_server_pid"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "Adopted existing webview server"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "reconcile_runtime_state"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "detect_warm_start"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "send_warm_start_launch_action"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "CODEX_DESKTOP_LAUNCH_ACTION_SOCKET"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "APP_SETTINGS_FILE"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "linux_setting_enabled"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "register_url_scheme_handlers"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "xdg-mime default"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "x-scheme-handler/"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "codex-browser-sidebar"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "codex-linux-warm-start-enabled"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "--new-instance"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "CODEX_MULTI_LAUNCH"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "CODEX_MULTI_LAUNCH_PORT_RANGE"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "choose_multi_launch_port"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "configure_multi_launch_instance"
    assert_contains "$REPO_DIR/launcher/start.sh.template" 'launcher-$CODEX_LINUX_INSTANCE_ID.log'
    assert_contains "$REPO_DIR/launcher/start.sh.template" "ADOPTED_WEBVIEW_PID"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "Reusing webview server pid="
    python3 - "$REPO_DIR/launcher/start.sh.template" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
detect_body = source.split("detect_warm_start() {", 1)[1].split("send_warm_start_launch_action() {", 1)[0]
launch_body = source.split("launch_electron() {", 1)[1].split("load_packaged_runtime_helper", 1)[0]
runtime_body = source.split("trap cleanup_launcher EXIT", 1)[1].split("launch_electron", 1)[0]
stop_body = source.split("stop_owned_webview_server() {", 1)[1].split("owned_webview_server_pid() {", 1)[0]
stale_body = source.split("pid_is_stale_webview_server() {", 1)[1].split("stop_owned_webview_server() {", 1)[0]
multi_body = source.split("configure_multi_launch_instance() {", 1)[1].split('WEBVIEW_ORIGIN="http://127.0.0.1:$CODEX_LINUX_WEBVIEW_PORT"', 1)[0]
adopt_body = source.split("adopt_existing_webview_server() {", 1)[1].split("start_webview_server() {", 1)[0]
ensure_body = source.split("start_webview_server() {", 1)[1].split("wait_for_webview_server", 1)[0]
reconcile_body = source.split("reconcile_runtime_state() {", 1)[1].split("set_electron_defaults() {", 1)[0]
if 'LAUNCHER_ARGS=()' not in source:
    raise SystemExit("launcher must keep a sanitized argv for launcher-only flags")
if 'configure_multi_launch_instance "$@"' not in source:
    raise SystemExit("launcher must configure multi-launch before deriving WEBVIEW_ORIGIN")
if 'unset CODEX_LINUX_MULTI_LAUNCH' not in source.split('parse_launcher_args() {', 1)[0]:
    raise SystemExit("launcher must clear inherited internal multi-launch markers before parsing args")
if '$((CODEX_LINUX_WEBVIEW_PORT + 4))' not in source:
    raise SystemExit("multi-launch default range must cap the default at five ports")
if 'CODEX_LINUX_INSTANCE_ID="port-$CODEX_LINUX_WEBVIEW_PORT"' not in multi_body:
    raise SystemExit("multi-launch must derive a stable instance id from the allocated port")
if 'CODEX_LINUX_MULTI_LAUNCH=1' not in multi_body:
    raise SystemExit("multi-launch must export an app-visible multi-launch marker")
if 'export CODEX_ELECTRON_USER_DATA_DIR CODEX_LINUX_INSTANCE_ID CODEX_LINUX_MULTI_LAUNCH CODEX_LINUX_WEBVIEW_PORT' not in multi_body:
    raise SystemExit("multi-launch must export instance identity for Electron")
if 'APP_STATE_DIR="$base_state_dir/instances/$CODEX_LINUX_INSTANCE_ID"' not in multi_body:
    raise SystemExit("multi-launch must isolate app pid/webview state per allocated port")
if 'LAUNCH_ACTION_RUNTIME_DIR="$XDG_RUNTIME_DIR/$CODEX_LINUX_APP_ID/instances/$CODEX_LINUX_INSTANCE_ID"' not in multi_body:
    raise SystemExit("multi-launch must isolate warm-start sockets per allocated port")
if 'CODEX_ELECTRON_USER_DATA_DIR="$APP_STATE_DIR/electron-user-data"' not in multi_body:
    raise SystemExit("multi-launch must force a per-instance Electron user-data dir")
if 'send_warm_start_launch_action "${LAUNCHER_ARGS[@]}"' not in source:
    raise SystemExit("warm-start handoff must not receive launcher-only multi-launch flags")
if "client.shutdown(socket.SHUT_WR)" not in send_body or "response = client.recv(32)" not in send_body:
    raise SystemExit("warm-start IPC client must read the Electron socket acknowledgement")
if 'launch_electron "${LAUNCHER_ARGS[@]}"' not in source:
    raise SystemExit("Electron launch must receive sanitized launcher args")
if 'RUNNING_APP_PID="$(find_running_app_pid)"' not in detect_body:
    raise SystemExit("detect_warm_start must record a pid-file running app even when warm start is disabled")
if '[ -S "$LAUNCH_ACTION_SOCKET" ] && RUNNING_APP_PID="$(discover_running_app_pid)"' not in detect_body:
    raise SystemExit("detect_warm_start must only use the expensive running-app scan when the launch socket exists")
if not re.search(r'if ! linux_setting_enabled "codex-linux-warm-start-enabled" 1; then.*?return 0', detect_body, re.S):
    raise SystemExit("detect_warm_start must not fail when warm start is disabled")
if "preserving liveness marker for second-instance handoff" not in detect_body:
    raise SystemExit("detect_warm_start must preserve the live app liveness marker")
if 'pid_matches_executable "$RUNNING_APP_PID" "$SCRIPT_DIR/electron"' not in launch_body:
    raise SystemExit("launch_electron must not overwrite APP_PID_FILE for second-instance handoff")
if 'echo "$ELECTRON_PID" > "$APP_PID_FILE"' not in launch_body:
    raise SystemExit("launch_electron must still write APP_PID_FILE for normal cold launches")
if "using_second_instance_handoff" not in source or "needs_cold_start" not in source:
    raise SystemExit("launcher must have an explicit second-instance handoff mode")
if "second_instance_handoff_ready" not in runtime_body:
    raise SystemExit("second-instance handoff must skip cold-start setup")
if "clear_bundled_marketplace_tmp_cache\nmonitor_bundled_marketplace_tmp_permissions\nreconcile_runtime_state" in runtime_body:
    raise SystemExit("warm-start path must not clear bundled marketplace temp cache")
if not re.search(r'if needs_cold_start; then\s+clear_bundled_marketplace_tmp_cache\s+# The runtime marketplace is populated asynchronously.*?monitor_bundled_marketplace_tmp_permissions\s+sync_browser_use_bundled_plugin_cache', runtime_body, re.S):
    raise SystemExit("bundled marketplace cleanup must run only on cold start immediately before plugin sync")
if 'if needs_cold_start && [ -z "${CODEX_CLI_PATH:-}" ]; then' not in runtime_body:
    raise SystemExit("second-instance handoff must skip CLI lookup")
if 'if needs_cold_start && [ -z "$CODEX_CLI_PATH" ]; then' not in runtime_body:
    raise SystemExit("second-instance handoff must skip missing-CLI failure")
if '"$HOME/.bun/bin/codex"' not in source:
    raise SystemExit("CLI lookup must include bun global install path")
if "codex_cli_version_probe()" not in source or "codex_cli_version()" not in source:
    raise SystemExit("CLI lookup must log a bounded best-effort resolved CLI version probe")
if "version unknown; set CODEX_CLI_PATH=/path/to/codex" not in source:
    raise SystemExit("CLI lookup diagnostics must explain explicit CODEX_CLI_PATH pinning")
if 'local self_pid="${BASHPID:-$$}"' not in source or 'pid_parent_matches "$probe_pid" "$self_pid"' not in source:
    raise SystemExit("CLI version probe watchdog must guard kills against PID reuse")
if source.count('{ exec 9>&-; } 2>/dev/null || true') < 3:
    raise SystemExit("CLI version probe children and Electron child must close launcher lock fd 9")
for unexpected in ("find_codex_cli_entry", "codex_cli_version_compare", "codex_cli_version_gt", "sort -V"):
    if unexpected in source:
        raise SystemExit(f"launcher must not rank discovered CLI candidates with {unexpected}")
if "if needs_cold_start;" not in runtime_body:
    raise SystemExit("second-instance handoff must skip CLI preflight")
if "running_app_is_active" not in stop_body or "Preserving webview server" not in stop_body:
    raise SystemExit("stop_owned_webview_server must not stop the live app webview server")
if "stale_webview_server_pid" not in source or "stop_stale_webview_server" not in source:
    raise SystemExit("launcher must detect stale deleted webview servers left behind by previous installs")
if 'current_webview_dir="$(canonical_path "$WEBVIEW_DIR")"' not in stale_body:
    raise SystemExit("stale webview detection must compare against the current bundle path")
if '[ "$cwd" != "$current_webview_dir" ]' not in stale_body:
    raise SystemExit("stale webview detection must catch servers moved into backup bundle directories")
if 'ADOPTED_WEBVIEW_PID="$pid"' not in adopt_body:
    raise SystemExit("adopt_existing_webview_server must not mark a running app server as started by this launcher")
if 'STARTED_WEBVIEW_PID="$pid"' not in adopt_body:
    raise SystemExit("adopt_existing_webview_server must still own orphaned servers when no live app is running")
if "running_app_is_active" not in adopt_body:
    raise SystemExit("adopt_existing_webview_server must detect live-app reuse before cleanup")
if "if adopt_existing_webview_server; then" not in ensure_body:
    raise SystemExit("start_webview_server must split adoption from origin verification")
if "stop_stale_webview_server" not in ensure_body:
    raise SystemExit("start_webview_server must clear stale deleted webview servers before treating the port as foreign")
if ensure_body.find("stop_stale_webview_server") > ensure_body.find("is already serving Codex content"):
    raise SystemExit("start_webview_server must try stale-server cleanup before foreign reachable-port failure")
if "Keeping the live app untouched" not in ensure_body:
    raise SystemExit("ensure_webview_server must not stop a live app server when validation fails")
if 'if live_app_pid="$(find_running_app_pid)" || { [ -S "$LAUNCH_ACTION_SOCKET" ] && live_app_pid="$(discover_running_app_pid)"; }; then' not in reconcile_body:
    raise SystemExit("reconcile_runtime_state must preserve runtime markers when a live app still exists")
if 'rm -f "$LAUNCH_ACTION_SOCKET"' not in reconcile_body:
    raise SystemExit("reconcile_runtime_state must clear a stale launch-action socket when no live app exists")
if 'clear_stale_pid_file' not in reconcile_body:
    raise SystemExit("reconcile_runtime_state must still clear stale app.pid markers")
if 'if [ -z "$webview_pid" ] || { ! pid_is_webview_server "$webview_pid" && ! pid_is_stale_webview_server "$webview_pid"; }; then' not in reconcile_body:
    raise SystemExit("reconcile_runtime_state must clear stale launcher webview ownership markers without touching valid orphaned servers")
PY
    local launcher_probe
    local output
    launcher_probe="$TMP_DIR/launcher-rendering-probe.sh"
    python3 - "$REPO_DIR/launcher/start.sh.template" "$launcher_probe" <<'PY'
import sys

source_path, output_path = sys.argv[1:3]
source = open(source_path, encoding="utf-8").read()
start = source.index("is_wsl_environment() {")
end = source.index("configure_side_by_side_app_env() {")
probe = "#!/usr/bin/env bash\n" + source[start:end] + r'''
set -Eeuo pipefail

CODEX_LINUX_APP_ID="${CODEX_LINUX_APP_ID:-codex-desktop}"
SCRIPT_DIR="${SCRIPT_DIR:-/tmp/codex-launcher-probe-app}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
APP_STATE_DIR="${APP_STATE_DIR:-/tmp/codex-launcher-probe-state}"

print_state() {
    printf 'mode=%s wslg=%s ozone_platform=%s ozone_hint=%s gpu=%s gpu_arg=%s comp=%s gl_added=%s renderer_accessibility=%s hook_value=%s hook_saw_arg=%s launch=' \
        "$ELECTRON_RENDERING_MODE" \
        "$ELECTRON_WSLG_DETECTED" \
        "${ELECTRON_OZONE_PLATFORM:-}" \
        "${ELECTRON_OZONE_HINT:-}" \
        "$ELECTRON_GPU_ENABLED" \
        "$ELECTRON_GPU_DISABLE_SWITCH_IN_ARGS" \
        "$ELECTRON_GPU_COMPOSITING_DISABLED" \
        "$ELECTRON_GL_SWITCH_ADDED" \
        "$ELECTRON_RENDERER_ACCESSIBILITY_FORCED" \
        "${CODEX_TEST_LAUNCHER_HOOK_VALUE:-}" \
        "${CODEX_TEST_LAUNCHER_HOOK_SAW_ARG:-}"
    for arg in "${ELECTRON_LAUNCH_ARGS[@]}"; do
        printf '<%s>' "$arg"
    done
    printf ' electron='
    for arg in "${ELECTRON_ARGS[@]}"; do
        printf '<%s>' "$arg"
    done
    printf '\n'
}

case "${1:-}" in
    probe)
        shift
        set_electron_defaults "$@"
        build_electron_launch_args
        print_state
        ;;
    *)
        echo "Usage: $0 probe [launcher args...]" >&2
        exit 2
        ;;
esac
'''
open(output_path, "w", encoding="utf-8").write(probe)
PY
    chmod +x "$launcher_probe"

    local at_stub_dir="$TMP_DIR/assistive-tech-stubs"
    mkdir -p "$at_stub_dir/none" "$at_stub_dir/orca" "$at_stub_dir/screenreader" \
        "$at_stub_dir/toolkit" "$at_stub_dir/atspibus" "$at_stub_dir/slowbus"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$at_stub_dir/none/pgrep"
    printf '%s\n' '#!/usr/bin/env bash' "printf 'false\\n'" > "$at_stub_dir/none/gsettings"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$at_stub_dir/orca/pgrep"
    printf '%s\n' '#!/usr/bin/env bash' "printf 'false\\n'" > "$at_stub_dir/orca/gsettings"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$at_stub_dir/screenreader/pgrep"
    printf '%s\n' '#!/usr/bin/env bash' "printf 'true\\n'" > "$at_stub_dir/screenreader/gsettings"
    # Computer Use gsettings fallback: toolkit-accessibility on, screen reader off.
    cat > "$at_stub_dir/toolkit/gsettings" <<'EOF'
#!/usr/bin/env bash
case "${3:-}" in
    toolkit-accessibility) printf 'true\n' ;;
    *) printf 'false\n' ;;
esac
EOF
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$at_stub_dir/toolkit/pgrep"
    # Computer Use primary path: org.a11y.Status IsEnabled=true via busctl.
    printf '%s\n' '#!/usr/bin/env bash' "printf 'false\\n'" > "$at_stub_dir/atspibus/gsettings"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$at_stub_dir/atspibus/pgrep"
    printf '%s\n' '#!/usr/bin/env bash' "printf 'b true\\n'" > "$at_stub_dir/atspibus/busctl"
    # Hung session bus: gsettings blocks far past the launch-path budget.
    cat > "$at_stub_dir/slowbus/gsettings" <<'EOF'
#!/usr/bin/env bash
: "${CODEX_TEST_SLOWBUS_PID_FILE:=}"
if [ -n "$CODEX_TEST_SLOWBUS_PID_FILE" ]; then
    printf '%s\n' "$$" > "$CODEX_TEST_SLOWBUS_PID_FILE"
fi
sleep 5
printf 'true\n'
EOF
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$at_stub_dir/slowbus/pgrep"
    local at_stub_variant
    for at_stub_variant in none orca screenreader toolkit slowbus; do
        printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$at_stub_dir/$at_stub_variant/busctl"
    done
    chmod +x "$at_stub_dir"/*/pgrep "$at_stub_dir"/*/gsettings "$at_stub_dir"/*/busctl

    output="$(env -i PATH="$at_stub_dir/none:$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default "$launcher_probe" probe --x11 -- --use-gl=angle)"
    [[ "$output" == *"electron=<--use-gl=angle>"* ]] || fail "launcher must pass Electron args after -- without the separator: $output"
    [[ "$output" != *"electron=<--><--use-gl=angle>"* ]] || fail "launcher must not pass the -- separator to Electron: $output"
    [[ "$output" == *"<--ozone-platform=x11>"* ]] || fail "launcher --x11 must still set the Electron ozone platform: $output"
    [[ "$output" == *"renderer_accessibility=1"* && "$output" == *"<--force-renderer-accessibility>"* ]] || fail "default Linux profile must still force renderer accessibility: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default "$launcher_probe" probe -- --ozone-platform=x11)"
    [[ "$output" == *"electron=<--ozone-platform=x11>"* ]] || fail "pass-through ozone platform must reach Electron: $output"
    [[ "$output" != *"<--ozone-platform-hint=auto>"* ]] || fail "launcher must not add ozone hint when pass-through supplies an ozone platform: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=wslg "$launcher_probe" probe)"
    [[ "$output" == *"mode=wslg"* && "$output" == *"comp=0"* && "$output" == *"gl_added=1"* ]] || fail "forced WSLg profile must disable GPU compositing default and add ANGLE: $output"
    [[ "$output" == *"<--ozone-platform=x11>"* && "$output" == *"electron=<--use-gl=angle>"* ]] || fail "forced WSLg profile must use X11 and ANGLE by default: $output"
    [[ "$output" != *"<--disable-gpu-compositing>"* ]] || fail "forced WSLg profile must not add disable-gpu-compositing by default: $output"
    [[ "$output" == *"renderer_accessibility=0"* && "$output" != *"<--force-renderer-accessibility>"* ]] || fail "forced WSLg profile must skip renderer accessibility by default: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=wslg CODEX_FORCE_RENDERER_ACCESSIBILITY=1 "$launcher_probe" probe)"
    [[ "$output" == *"renderer_accessibility=1"* && "$output" == *"<--force-renderer-accessibility>"* ]] || fail "CODEX_FORCE_RENDERER_ACCESSIBILITY=1 must force renderer accessibility under WSLg: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_FORCE_RENDERER_ACCESSIBILITY=0 "$launcher_probe" probe)"
    [[ "$output" == *"renderer_accessibility=0"* && "$output" != *"<--force-renderer-accessibility>"* ]] || fail "CODEX_FORCE_RENDERER_ACCESSIBILITY=0 must disable renderer accessibility under default Linux: $output"

    output="$(env -i PATH="$at_stub_dir/orca:$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default "$launcher_probe" probe)"
    [[ "$output" == *"renderer_accessibility=1"* && "$output" == *"<--force-renderer-accessibility>"* ]] || fail "a running screen reader must force renderer accessibility under default Linux: $output"

    output="$(env -i PATH="$at_stub_dir/screenreader:$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default "$launcher_probe" probe)"
    [[ "$output" == *"renderer_accessibility=1"* && "$output" == *"<--force-renderer-accessibility>"* ]] || fail "the GNOME screen-reader setting must force renderer accessibility under default Linux: $output"

    output="$(env -i PATH="$at_stub_dir/none:$PATH" HOME="$HOME" GNOME_ACCESSIBILITY=1 CODEX_LINUX_RENDERING_MODE=default "$launcher_probe" probe)"
    [[ "$output" == *"renderer_accessibility=1"* && "$output" == *"<--force-renderer-accessibility>"* ]] || fail "GNOME_ACCESSIBILITY=1 must force renderer accessibility under default Linux: $output"

    output="$(env -i PATH="$at_stub_dir/none:$PATH" HOME="$HOME" QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 CODEX_LINUX_RENDERING_MODE=default "$launcher_probe" probe)"
    [[ "$output" == *"renderer_accessibility=1"* && "$output" == *"<--force-renderer-accessibility>"* ]] || fail "QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 must force renderer accessibility under default Linux: $output"

    output="$(env -i PATH="$at_stub_dir/none:$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_FORCE_RENDERER_ACCESSIBILITY=1 "$launcher_probe" probe)"
    [[ "$output" == *"renderer_accessibility=1"* && "$output" == *"<--force-renderer-accessibility>"* ]] || fail "CODEX_FORCE_RENDERER_ACCESSIBILITY=1 must force renderer accessibility without detected assistive technology: $output"

    output="$(env -i PATH="$at_stub_dir/toolkit:$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default "$launcher_probe" probe)"
    [[ "$output" == *"renderer_accessibility=1"* && "$output" == *"<--force-renderer-accessibility>"* ]] || fail "toolkit-accessibility=true (Computer Use gsettings fallback) must force renderer accessibility: $output"

    output="$(env -i PATH="$at_stub_dir/atspibus:$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default "$launcher_probe" probe)"
    [[ "$output" == *"renderer_accessibility=1"* && "$output" == *"<--force-renderer-accessibility>"* ]] || fail "org.a11y.Status IsEnabled (Computer Use setup) must force renderer accessibility: $output"

    local at_probe_start_ns at_probe_end_ns at_probe_elapsed_ms slowbus_pid slowbus_pid_file
    slowbus_pid_file="$TMP_DIR/slowbus-gsettings.pid"
    rm -f "$slowbus_pid_file"
    at_probe_start_ns="$(date +%s%N)"
    output="$(env -i PATH="$at_stub_dir/slowbus:$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_TEST_SLOWBUS_PID_FILE="$slowbus_pid_file" "$launcher_probe" probe)"
    at_probe_end_ns="$(date +%s%N)"
    at_probe_elapsed_ms=$(( (10#$at_probe_end_ns - 10#$at_probe_start_ns) / 1000000 ))
    [[ "$output" == *"renderer_accessibility=0"* && "$output" != *"<--force-renderer-accessibility>"* ]] || fail "a hung session bus must not force renderer accessibility: $output"
    [ "$at_probe_elapsed_ms" -lt 3000 ] || fail "session-bus assistive-tech probe must be watchdog-capped, took ${at_probe_elapsed_ms}ms: $output"
    [ -s "$slowbus_pid_file" ] || fail "hung session-bus probe did not start the gsettings helper"
    slowbus_pid="$(< "$slowbus_pid_file")"
    if kill -0 "$slowbus_pid" 2>/dev/null; then
        kill -KILL "$slowbus_pid" 2>/dev/null || true
        fail "session-bus assistive-tech watchdog leaked hung gsettings pid $slowbus_pid"
    fi

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=wslg "$launcher_probe" probe --wayland --use-gl=desktop)"
    [[ "$output" == *"<--ozone-platform=wayland>"* && "$output" == *"electron=<--use-gl=desktop>"* ]] || fail "explicit rendering args must override WSLg defaults: $output"
    [[ "$output" == *"gl_added=0"* && "$output" != *"<--use-gl=angle>"* ]] || fail "WSLg profile must not add ANGLE when a GL switch was supplied: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=wslg "$launcher_probe" probe -- --disable-gpu)"
    [[ "$output" == *"gpu=1"* && "$output" == *"gpu_arg=1"* && "$output" == *"gl_added=0"* ]] || fail "pass-through --disable-gpu must suppress WSLg ANGLE without becoming a launcher GPU toggle: $output"
    [[ "$output" == *"electron=<--disable-gpu>"* && "$output" != *"<--disable-features=Vulkan>"* ]] || fail "pass-through --disable-gpu must not add launcher-only Vulkan flags: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=wslg CODEX_ELECTRON_DISABLE_GPU_COMPOSITING=1 "$launcher_probe" probe)"
    [[ "$output" == *"comp=1"* && "$output" == *"<--disable-gpu-compositing>"* ]] || fail "CODEX_ELECTRON_DISABLE_GPU_COMPOSITING=1 must force the compositor flag: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_ELECTRON_DISABLE_GPU_COMPOSITING=0 "$launcher_probe" probe)"
    [[ "$output" == *"comp=0"* && "$output" != *"<--disable-gpu-compositing>"* ]] || fail "CODEX_ELECTRON_DISABLE_GPU_COMPOSITING=0 must suppress the compositor flag: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" WSL_INTEROP=/tmp/codex-wsl WAYLAND_DISPLAY=wayland-0 "$launcher_probe" probe)"
    [[ "$output" == *"mode=wslg"* && "$output" == *"wslg=1"* ]] || fail "auto rendering mode must detect WSLg from WSL and GUI markers: $output"

    local dev_shm_stub_dir="$TMP_DIR/dev-shm-stubs"
    mkdir -p "$dev_shm_stub_dir/large" "$dev_shm_stub_dir/small" "$dev_shm_stub_dir/broken"
    cat > "$dev_shm_stub_dir/large/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'tmpfs 16000000 0 16000000 0%% /dev/shm\n'
EOF
    cat > "$dev_shm_stub_dir/small/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'tmpfs 65536 0 65536 0%% /dev/shm\n'
EOF
    cat > "$dev_shm_stub_dir/broken/df" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$dev_shm_stub_dir/large/df" "$dev_shm_stub_dir/small/df" "$dev_shm_stub_dir/broken/df"

    output="$(env -i PATH="$dev_shm_stub_dir/large:$PATH" HOME="$HOME" "$launcher_probe" probe)"
    [[ "$output" != *"<--disable-dev-shm-usage>"* ]] || fail "adequate /dev/shm must not disable Chromium /dev/shm usage: $output"

    output="$(env -i PATH="$dev_shm_stub_dir/small:$PATH" HOME="$HOME" "$launcher_probe" probe)"
    [[ "$output" == *"<--disable-dev-shm-usage>"* ]] || fail "small /dev/shm must keep --disable-dev-shm-usage: $output"

    output="$(env -i PATH="$dev_shm_stub_dir/broken:$PATH" HOME="$HOME" "$launcher_probe" probe)"
    [[ "$output" == *"<--disable-dev-shm-usage>"* ]] || fail "unreadable /dev/shm capacity must keep --disable-dev-shm-usage: $output"

    output="$(env -i PATH="$dev_shm_stub_dir/large:$PATH" HOME="$HOME" CODEX_ELECTRON_DISABLE_DEV_SHM_USAGE=1 "$launcher_probe" probe)"
    [[ "$output" == *"<--disable-dev-shm-usage>"* ]] || fail "CODEX_ELECTRON_DISABLE_DEV_SHM_USAGE=1 must force --disable-dev-shm-usage: $output"

    output="$(env -i PATH="$dev_shm_stub_dir/small:$PATH" HOME="$HOME" CODEX_ELECTRON_DISABLE_DEV_SHM_USAGE=0 "$launcher_probe" probe)"
    [[ "$output" != *"<--disable-dev-shm-usage>"* ]] || fail "CODEX_ELECTRON_DISABLE_DEV_SHM_USAGE=0 must suppress --disable-dev-shm-usage: $output"

    output="$(env -i PATH="$dev_shm_stub_dir/small:$PATH" HOME="$HOME" CODEX_ELECTRON_DISABLE_DEV_SHM_USAGE=bogus "$launcher_probe" probe 2>/dev/null)"
    [[ "$output" == *"<--disable-dev-shm-usage>"* ]] || fail "invalid CODEX_ELECTRON_DISABLE_DEV_SHM_USAGE must fall back to /dev/shm detection: $output"
    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_OZONE_PLATFORM=x11 "$launcher_probe" probe)"
    [[ "$output" == *"<--ozone-platform=x11>"* && "$output" != *"<--ozone-platform-hint=auto>"* ]] || fail "CODEX_OZONE_PLATFORM=x11 must select the X11 Ozone backend: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_OZONE_PLATFORM=wayland "$launcher_probe" probe)"
    [[ "$output" == *"<--ozone-platform=wayland>"* && "$output" == *"WaylandWindowDecorations"* ]] || fail "CODEX_OZONE_PLATFORM=wayland must select native Wayland with decorations: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_OZONE_PLATFORM=auto SOMMELIER_VERSION=1 "$launcher_probe" probe)"
    [[ "$output" == *"<--ozone-platform-hint=auto>"* && "$output" != *"<--ozone-platform=x11>"* ]] || fail "CODEX_OZONE_PLATFORM=auto must override the Sommelier X11 fallback: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_OZONE_PLATFORM=wayland "$launcher_probe" probe --x11)"
    [[ "$output" == *"<--ozone-platform=x11>"* && "$output" != *"<--ozone-platform=wayland>"* ]] || fail "explicit --x11 must win over CODEX_OZONE_PLATFORM: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_OZONE_PLATFORM=bogus "$launcher_probe" probe 2>/dev/null)"
    [[ "$output" == *"<--ozone-platform-hint=auto>"* ]] || fail "invalid CODEX_OZONE_PLATFORM must fall back to the default ozone hint: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_FORCE_DEVICE_SCALE_FACTOR=1 "$launcher_probe" probe)"
    [[ "$output" == *"<--force-device-scale-factor=1>"* ]] || fail "CODEX_FORCE_DEVICE_SCALE_FACTOR=1 must pass the scale flag to Electron: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_FORCE_DEVICE_SCALE_FACTOR=1.25 "$launcher_probe" probe)"
    [[ "$output" == *"<--force-device-scale-factor=1.25>"* ]] || fail "fractional CODEX_FORCE_DEVICE_SCALE_FACTOR must pass through: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_FORCE_DEVICE_SCALE_FACTOR=abc "$launcher_probe" probe 2>/dev/null)"
    [[ "$output" != *"--force-device-scale-factor"* ]] || fail "invalid CODEX_FORCE_DEVICE_SCALE_FACTOR must be ignored: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_FORCE_DEVICE_SCALE_FACTOR=0 "$launcher_probe" probe 2>/dev/null)"
    [[ "$output" != *"--force-device-scale-factor"* ]] || fail "zero CODEX_FORCE_DEVICE_SCALE_FACTOR must be ignored: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default CODEX_FORCE_DEVICE_SCALE_FACTOR=1 "$launcher_probe" probe -- --force-device-scale-factor=2)"
    [[ "$output" == *"electron=<--force-device-scale-factor=2>"* && "$output" != *"<--force-device-scale-factor=1>"* ]] || fail "explicit --force-device-scale-factor must win over the env override: $output"

    # Feature launcher hooks run after set_electron_defaults() has already chosen
    # the Ozone platform, so a hook-supplied explicit --ozone-platform must drop
    # the launcher-computed value instead of leaving both in the final argv. This
    # must hold no matter how the launcher picked the platform: CODEX_OZONE_PLATFORM,
    # the CODEX_LINUX_RENDERING_MODE profile (wayland-gpu / wslg), or the Sommelier
    # fallback.
    local hook_force_x11_dir="$TMP_DIR/hook-force-x11"
    mkdir -p "$hook_force_x11_dir"
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' 'electron-arg --ozone-platform=x11'" > "$hook_force_x11_dir/force-x11"
    chmod +x "$hook_force_x11_dir/force-x11"
    local hook_force_wayland_dir="$TMP_DIR/hook-force-wayland"
    mkdir -p "$hook_force_wayland_dir"
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' 'electron-arg --ozone-platform=wayland'" > "$hook_force_wayland_dir/force-wayland"
    chmod +x "$hook_force_wayland_dir/force-wayland"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default FEATURE_LAUNCHER_HOOK_DIR="$hook_force_x11_dir" CODEX_OZONE_PLATFORM=wayland "$launcher_probe" probe)"
    [[ "$output" == *"electron=<--ozone-platform=x11>"* ]] || fail "launcher hook --ozone-platform must reach Electron over CODEX_OZONE_PLATFORM: $output"
    [[ "$output" != *"<--ozone-platform=wayland>"* ]] || fail "env-derived --ozone-platform must be dropped when a launcher hook overrides it: $output"
    [[ "$output" != *"WaylandWindowDecorations"* ]] || fail "cleared env Wayland platform must not still add Wayland decorations: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=wayland-gpu FEATURE_LAUNCHER_HOOK_DIR="$hook_force_x11_dir" "$launcher_probe" probe)"
    [[ "$output" == *"electron=<--ozone-platform=x11>"* ]] || fail "launcher hook --ozone-platform must reach Electron under wayland-gpu: $output"
    [[ "$output" != *"<--ozone-platform=wayland>"* ]] || fail "wayland-gpu launcher platform must be dropped when a hook overrides it: $output"
    [[ "$output" != *"WaylandWindowDecorations"* ]] || fail "dropped wayland-gpu platform must not still add Wayland decorations: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=wslg FEATURE_LAUNCHER_HOOK_DIR="$hook_force_wayland_dir" "$launcher_probe" probe)"
    [[ "$output" == *"<--ozone-platform=wayland>"* ]] || fail "launcher hook --ozone-platform must reach Electron under wslg: $output"
    [[ "$output" != *"<--ozone-platform=x11>"* ]] || fail "wslg launcher platform must be dropped when a hook overrides it: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default SOMMELIER_VERSION=1 FEATURE_LAUNCHER_HOOK_DIR="$hook_force_wayland_dir" "$launcher_probe" probe)"
    [[ "$output" == *"<--ozone-platform=wayland>"* ]] || fail "launcher hook --ozone-platform must reach Electron over the Sommelier fallback: $output"
    [[ "$output" != *"<--ozone-platform=x11>"* ]] || fail "Sommelier X11 fallback must be dropped when a hook overrides it: $output"

    local hook_scale_dir="$TMP_DIR/hook-scale-override"
    mkdir -p "$hook_scale_dir"
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' 'electron-arg --force-device-scale-factor=2'" > "$hook_scale_dir/force-scale2"
    chmod +x "$hook_scale_dir/force-scale2"
    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default FEATURE_LAUNCHER_HOOK_DIR="$hook_scale_dir" CODEX_FORCE_DEVICE_SCALE_FACTOR=1 "$launcher_probe" probe)"
    [[ "$output" == *"electron=<--force-device-scale-factor=2>"* ]] || fail "launcher hook --force-device-scale-factor must reach Electron over CODEX_FORCE_DEVICE_SCALE_FACTOR: $output"
    [[ "$output" != *"<--force-device-scale-factor=1>"* ]] || fail "env-derived --force-device-scale-factor must be dropped when a launcher hook overrides it: $output"

    # A hook-emitted arg must also replace a conflicting arg already collected in
    # ELECTRON_ARGS (pass-through CLI, persistent flags file, or feature
    # electron-args) instead of appending a duplicate switch to the final argv.
    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default FEATURE_LAUNCHER_HOOK_DIR="$hook_force_wayland_dir" "$launcher_probe" probe -- --ozone-platform=x11)"
    [[ "$output" == *"electron=<--ozone-platform=wayland>"* ]] || fail "launcher hook --ozone-platform must replace a pass-through ozone arg: $output"
    [[ "$output" != *"<--ozone-platform=x11>"* ]] || fail "pass-through --ozone-platform must be dropped when a launcher hook supersedes it: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default FEATURE_LAUNCHER_HOOK_DIR="$hook_force_wayland_dir" "$launcher_probe" probe -- --ozone-platform-hint=auto)"
    [[ "$output" == *"electron=<--ozone-platform=wayland>"* ]] || fail "launcher hook --ozone-platform must replace a pass-through ozone hint: $output"
    [[ "$output" != *"<--ozone-platform-hint=auto>"* ]] || fail "pass-through --ozone-platform-hint must be dropped when a hook supplies an explicit platform: $output"

    output="$(env -i PATH="$PATH" HOME="$HOME" CODEX_LINUX_RENDERING_MODE=default FEATURE_LAUNCHER_HOOK_DIR="$hook_scale_dir" "$launcher_probe" probe -- --force-device-scale-factor=1)"
    [[ "$output" == *"electron=<--force-device-scale-factor=2>"* ]] || fail "launcher hook scale arg must replace a pass-through scale arg: $output"
    [[ "$output" != *"<--force-device-scale-factor=1>"* ]] || fail "pass-through --force-device-scale-factor must be dropped when a launcher hook supersedes it: $output"

    local hook_scale_flags_dir="$TMP_DIR/hook-scale-user-flags"
    local hook_scale_flags_file="$hook_scale_flags_dir/electron-flags.conf"
    mkdir -p "$hook_scale_flags_dir"
    printf '%s\n' '--force-device-scale-factor=1' > "$hook_scale_flags_file"
    output="$(env -i PATH="$PATH" HOME="$HOME" APP_CONFIG_DIR="$hook_scale_flags_dir" USER_ELECTRON_FLAGS_FILE="$hook_scale_flags_file" CODEX_LINUX_RENDERING_MODE=default FEATURE_LAUNCHER_HOOK_DIR="$hook_scale_dir" "$launcher_probe" probe)"
    [[ "$output" == *"electron=<--force-device-scale-factor=2>"* ]] || fail "launcher hook scale arg must replace a persistent-flags scale arg: $output"
    [[ "$output" != *"<--force-device-scale-factor=1>"* ]] || fail "persistent-flags --force-device-scale-factor must be dropped when a launcher hook supersedes it: $output"

    local hook_scale_feature_args_dir="$TMP_DIR/hook-scale-feature-args"
    mkdir -p "$hook_scale_feature_args_dir"
    printf '%s\n' '--force-device-scale-factor=1' > "$hook_scale_feature_args_dir/feature"
    output="$(env -i PATH="$PATH" HOME="$HOME" FEATURE_ELECTRON_ARGS_DIR="$hook_scale_feature_args_dir" CODEX_LINUX_RENDERING_MODE=default FEATURE_LAUNCHER_HOOK_DIR="$hook_scale_dir" "$launcher_probe" probe)"
    [[ "$output" == *"electron=<--force-device-scale-factor=2>"* ]] || fail "launcher hook scale arg must replace a feature electron-args scale arg: $output"
    [[ "$output" != *"<--force-device-scale-factor=1>"* ]] || fail "feature electron-args --force-device-scale-factor must be dropped when a launcher hook supersedes it: $output"

    assert_contains "$REPO_DIR/launcher/start.sh.template" "warm_start_ipc_sent"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "launcher_phase"
    assert_contains "$REPO_DIR/launcher/start.sh.template" 'date +%s%N'
    assert_contains "$REPO_DIR/launcher/start.sh.template" '10#$nanos / 1000000'
    assert_contains "$REPO_DIR/launcher/start.sh.template" "CODEX_SYNC_CLI_PREFLIGHT"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "wait_for_webview_server"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "verify_webview_origin"
    # Probe-shape invariants: shell-native bash /dev/tcp + curl, with the
    # bounded-execution defenses preserved (0.2 s watchdog + 2 s curl cap).
    assert_contains "$REPO_DIR/launcher/start.sh.template" '/dev/tcp/127.0.0.1/"$CODEX_LINUX_WEBVIEW_PORT"'
    assert_contains "$REPO_DIR/launcher/start.sh.template" "kill -9 \"\$probe_pid\""
    assert_contains "$REPO_DIR/launcher/start.sh.template" 'curl --disable --noproxy 127.0.0.1,localhost --silent --show-error --fail --max-time 2'
    assert_contains "$REPO_DIR/launcher/start.sh.template" "for attempt in \$(seq 1 250)"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "sleep 0.02"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "Webview origin verified."
    assert_contains "$REPO_DIR/launcher/start.sh.template" "hydrate_graphical_session_env"
    assert_not_contains "$REPO_DIR/install.sh" "pkill -f \"http.server 5175\""
    assert_contains "$REPO_DIR/launcher/start.sh.template" "CODEX_WEBVIEW_PORT"
    assert_contains "$REPO_DIR/launcher/start.sh.template" 'ELECTRON_RENDERER_URL="${ELECTRON_RENDERER_URL:-$WEBVIEW_ORIGIN/}"'
    assert_contains "$REPO_DIR/launcher/start.sh.template" '--app-id="$CODEX_LINUX_APP_ID"'
    assert_contains "$REPO_DIR/scripts/lib/process-detection.sh" "CODEX_APP_ID"
    assert_contains "$REPO_DIR/launcher/start.sh.template" 'ELECTRON_OZONE_HINT="auto"'
    assert_contains "$REPO_DIR/launcher/start.sh.template" '--ozone-platform-hint="$ELECTRON_OZONE_HINT"'
    assert_contains "$REPO_DIR/launcher/start.sh.template" "--disable-gpu-sandbox"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "CODEX_ELECTRON_DISABLE_DEV_SHM_USAGE=auto|0|1"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "dev_shm_usage_disabled="
    assert_contains "$REPO_DIR/launcher/start.sh.template" "--force-renderer-accessibility"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "CODEX_FORCE_RENDERER_ACCESSIBILITY=auto|0|1"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "assistive_technology_detected"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "session_bus_probe_command"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "CODEX_OZONE_PLATFORM=x11|wayland|auto"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "CODEX_FORCE_DEVICE_SCALE_FACTOR=N"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "print_scaling_diagnostics"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "--diagnose-scaling"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "PACKAGED_RUNTIME_HELPER"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "--allow-install-missing"
    assert_contains "$REPO_DIR/scripts/lib/process-detection.sh" "CODEX_INSTALL_ALLOW_RUNNING"
    assert_contains "$REPO_DIR/scripts/lib/process-detection.sh" "assert_install_target_not_running"
    assert_contains "$REPO_DIR/scripts/lib/process-detection.sh" "find_running_install_target_pid"
    assert_contains "$REPO_DIR/scripts/lib/process-detection.sh" "Codex Desktop is currently running from"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "prompt_install_missing_cli"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "prompt-install-cli"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "CODEX_UPDATE_MANAGER_PATH"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "resolve_update_manager_path"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "run_update_manager"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "sync_browser_use_bundled_plugin_cache"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "sync_chrome_bundled_plugin_cache"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "make_tree_owner_writable"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "clear_bundled_marketplace_tmp_cache"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "monitor_bundled_marketplace_tmp_permissions"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "extension-id.json"
    assert_contains "$REPO_DIR/launcher/start.sh.template" ".config/BraveSoftware/Brave-Browser/NativeMessagingHosts"
    assert_contains "$REPO_DIR/launcher/start.sh.template" ".config/chromium/NativeMessagingHosts"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "scripts/check-extension-installed.js"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "scripts/chrome-is-running.js"
    assert_contains "$REPO_DIR/launcher/start.sh.template" ".tmp/bundled-marketplaces/openai-bundled"
    assert_contains "$REPO_DIR/launcher/start.sh.template" ".agents/plugins/marketplace.json"
    assert_contains "$REPO_DIR/scripts/lib/bundled-plugins.sh" "stage_chrome_plugin_from_upstream"
    assert_contains "$REPO_DIR/scripts/lib/patch-chrome-plugin.js" "Linux native host manifest location"
    assert_contains "$REPO_DIR/computer-use-linux/src/bin/codex-chrome-extension-host.rs" "CODEX_BROWSER_USE_SOCKET_DIR"
    assert_contains "$REPO_DIR/flake.nix" "Browser Use bundled marketplace metadata"
    assert_contains "$REPO_DIR/flake.nix" ".tmp/bundled-marketplaces/openai-bundled"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "Install it now? \\[Y/n\\]"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "is_interactive_terminal"
    assert_contains "$REPO_DIR/updater/src/app.rs" "kdialog"
    assert_contains "$REPO_DIR/updater/src/app.rs" "zenity"
    assert_contains "$REPO_DIR/packaging/linux/codex-packaged-runtime.sh" "CHROME_DESKTOP"
    assert_contains "$REPO_DIR/packaging/linux/codex-packaged-runtime.sh" "is-enabled codex-update-manager.service"
    assert_contains "$REPO_DIR/packaging/linux/codex-packaged-runtime.sh" "codex-update-manager-launch-check"
    assert_contains "$REPO_DIR/packaging/linux/codex-packaged-runtime.sh" "codex-update-manager check-now --if-stale"
    assert_not_contains "$REPO_DIR/packaging/linux/codex-packaged-runtime.sh" "enable --now codex-update-manager.service"
    assert_not_contains "$REPO_DIR/packaging/linux/codex-packaged-runtime.sh" "restart codex-update-manager.service"
    assert_contains "$REPO_DIR/packaging/linux/codex-update-manager-user-service.sh" "codex_start_enabled_user_service"
    assert_contains "$REPO_DIR/packaging/linux/codex-update-manager.postinst" "codex_start_enabled_user_service"
    assert_contains "$REPO_DIR/packaging/linux/codex-desktop.install" "codex_start_enabled_user_service"
    assert_contains "$REPO_DIR/packaging/linux/codex-desktop.spec" "codex_start_enabled_user_service"
    assert_contains "$REPO_DIR/scripts/install-deps.sh" 'NODEJS_MAJOR="${NODEJS_MAJOR:-22}"'
    assert_contains "$REPO_DIR/scripts/install-deps.sh" "apt_nodejs_candidate_major"
    assert_contains "$REPO_DIR/scripts/install-deps.sh" "Installing distro Node.js/npm candidate"
    assert_contains "$REPO_DIR/scripts/install-deps.sh" "/etc/apt/keyrings/nodesource.gpg"
    assert_contains "$REPO_DIR/scripts/install-deps.sh" "signed-by="
    assert_contains "$REPO_DIR/scripts/install-deps.sh" "https://deb.nodesource.com/node_"
    assert_not_contains "$REPO_DIR/packaging/linux/control" "Depends:.*nodejs"
    assert_not_contains "$REPO_DIR/packaging/linux/control" "Depends:.*npm"
    assert_not_contains "$REPO_DIR/packaging/linux/codex-desktop.spec" "Requires:.*nodejs"
    assert_not_contains "$REPO_DIR/packaging/linux/codex-desktop.spec" "Requires:.*npm"
    assert_not_contains "$REPO_DIR/packaging/linux/PKGBUILD.template" "'nodejs>=20'"
    assert_contains "$REPO_DIR/packaging/linux/PKGBUILD.template" "optional override for the bundled managed Node.js runtime"
    assert_contains "$REPO_DIR/scripts/lib/node-runtime.sh" "MANAGED_NODE_VERSION"
    assert_contains "$REPO_DIR/scripts/lib/package-common.sh" "node-runtime"
    assert_contains "$REPO_DIR/tests/fixtures/create-packaged-app-fixture.sh" "resources/node-runtime/bin"
    assert_contains "$REPO_DIR/.github/workflows/ci.yml" "tests/fixtures/create-packaged-app-fixture.sh codex-app"
    assert_contains "$REPO_DIR/.github/workflows/ci.yml" "for file in scripts/patches/"
    assert_contains "$REPO_DIR/scripts/ci/container-entrypoint.sh" "for file in scripts/patches/"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "MANAGED_NODE_BIN_DIR"
    assert_contains "$REPO_DIR/launcher/start.sh.template" "CODEX_LINUX_USER_PATH"
    assert_contains "$REPO_DIR/updater/src/builder.rs" "managed_node_bin_dirs"
    assert_contains "$REPO_DIR/scripts/build-rpm.sh" "stage_common_package_files"
    assert_contains "$REPO_DIR/scripts/build-rpm.sh" "PACKAGED_RUNTIME_SOURCE"
    assert_contains "$REPO_DIR/packaging/linux/codex-desktop.desktop" "BAMF_DESKTOP_FILE_HINT"
    assert_contains "$REPO_DIR/packaging/linux/codex-desktop.desktop" "/usr/bin/codex-desktop %u"
    assert_contains "$REPO_DIR/packaging/linux/codex-desktop.desktop" "MimeType=x-scheme-handler/codex;x-scheme-handler/codex-browser-sidebar;"
    assert_contains "$REPO_DIR/packaging/linux/codex-desktop.desktop" "StartupWMClass=Codex"
    assert_contains "$REPO_DIR/packaging/linux/codex-desktop.desktop" "X-GNOME-WMClass=Codex"
    assert_contains "$REPO_DIR/packaging/linux/codex-desktop.desktop" "Actions=CheckForUpdates;InstallReadyUpdate;"
    assert_contains "$REPO_DIR/packaging/linux/codex-desktop.desktop" "codex-update-manager check-now"
    assert_contains "$REPO_DIR/packaging/linux/codex-desktop.desktop" "codex-update-manager install-ready"
    assert_contains "$REPO_DIR/contrib/user-local-install/files/.local/share/applications/codex-desktop.desktop" "@HOME@/.local/bin/codex-desktop %U"
    assert_contains "$REPO_DIR/contrib/user-local-install/files/.local/share/applications/codex-desktop.desktop" "MimeType=x-scheme-handler/codex;x-scheme-handler/codex-browser-sidebar;"
    assert_contains "$REPO_DIR/contrib/user-local-install/files/.local/bin/codex-desktop" "CODEX_USER_LOCAL_OZONE_PLATFORM"
    assert_contains "$REPO_DIR/contrib/user-local-install/files/.local/bin/codex-desktop" 'exec "${APP_DIR}/start.sh" --x11 "$@"'
    assert_contains "$REPO_DIR/contrib/user-local-install/files/.local/bin/codex-desktop" 'exec "${APP_DIR}/start.sh" --wayland "$@"'
    assert_contains "$REPO_DIR/contrib/user-local-install/install-user-local.sh" "--force-x11"
    assert_contains "$REPO_DIR/contrib/user-local-install/install-user-local.sh" "user-local.env"
    assert_contains "$REPO_DIR/contrib/user-local-install/README.md" "--force-x11"
}

test_launcher_cli_resolution_policy() {
    info "Checking launcher CLI resolution policy"
    local launcher_probe="$TMP_DIR/launcher-cli-policy-probe.sh"
    python3 - "$REPO_DIR/launcher/start.sh.template" "$launcher_probe" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
functions = []
for name in ("find_codex_cli", "pid_parent_matches", "codex_cli_version_probe", "codex_cli_version", "log_codex_cli_path"):
    match = re.search(r"^" + re.escape(name) + r"\(\) \{[\s\S]*?^\}\n", source, re.M)
    if match is None:
        raise SystemExit(f"missing {name}")
    functions.append(match.group(0))

pathlib.Path(sys.argv[2]).write_text(
    "#!/usr/bin/env bash\n"
    "set -Eeuo pipefail\n\n"
    + "\n".join(functions)
    + r'''
case "${1:?}" in
    find)
        find_codex_cli
        ;;
    version)
        codex_cli_version "$2"
        ;;
    log)
        CODEX_CLI_PATH="${2:-}"
        export CODEX_CLI_PATH
        log_codex_cli_path
        ;;
    *)
        exit 64
        ;;
esac
''',
    encoding="utf-8",
)
PY
    chmod +x "$launcher_probe"

    local workspace="$TMP_DIR/launcher-cli-policy"
    local fake_home="$workspace/home"
    local path_cli_bin="$workspace/path-cli-bin"
    local selected_cli
    mkdir -p "$path_cli_bin" "$fake_home/.npm-global/bin"

    printf '#!/usr/bin/env bash\nprintf "codex-cli 0.120.0\\n"\n' > "$path_cli_bin/codex"
    printf '#!/usr/bin/env bash\nprintf "codex-cli 9.999.0\\n"\n' > "$fake_home/.npm-global/bin/codex"
    chmod +x "$path_cli_bin/codex" "$fake_home/.npm-global/bin/codex"

    selected_cli="$(env -i PATH="$path_cli_bin:/usr/bin:/bin" HOME="$fake_home" "$launcher_probe" find)"
    [ "$selected_cli" = "$path_cli_bin/codex" ] || fail "CLI lookup must keep the first PATH hit, got $selected_cli"

    local override_cli="$workspace/override-codex"
    local log_output
    printf '#!/usr/bin/env bash\nprintf "codex-cli 0.42.0\\n"\n' > "$override_cli"
    chmod +x "$override_cli"
    log_output="$(env -i PATH="$path_cli_bin:/usr/bin:/bin" HOME="$fake_home" "$launcher_probe" log "$override_cli")"
    [[ "$log_output" == "Using CODEX_CLI_PATH=$override_cli (version 0.42.0)" ]] || fail "CODEX_CLI_PATH must remain an explicit override with version logging: $log_output"

    local dash_version_cli="$workspace/dash-version-codex"
    local fallback_version_cli="$workspace/fallback-version-codex"
    local version_output
    printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] || exit 2\nprintf "codex-cli 0.150.0\\n"\n' > "$dash_version_cli"
    printf '#!/usr/bin/env bash\nif [ "${1:-}" = "--version" ]; then exit 2; fi\n[ "${1:-}" = "version" ] || exit 2\nprintf "codex-cli v0.151.0\\n"\n' > "$fallback_version_cli"
    chmod +x "$dash_version_cli" "$fallback_version_cli"

    version_output="$(env -i PATH="/usr/bin:/bin" HOME="$fake_home" "$launcher_probe" version "$dash_version_cli")"
    [ "$version_output" = "0.150.0" ] || fail "CLI version probe must read --version output, got $version_output"
    version_output="$(env -i PATH="/usr/bin:/bin" HOME="$fake_home" "$launcher_probe" version "$fallback_version_cli")"
    [ "$version_output" = "0.151.0" ] || fail "CLI version probe must fall back to version output, got $version_output"

    # The version probe result is read through command substitution on the
    # launch path. The watchdog subshell (and its sleep child) must not
    # inherit that pipe, or a fast CLI still blocks the caller for the full
    # watchdog second waiting for pipe EOF.
    local fast_probe_start_ns fast_probe_end_ns fast_probe_elapsed_ms
    fast_probe_start_ns="$(date +%s%N)"
    version_output="$(env -i PATH="/usr/bin:/bin" HOME="$fake_home" "$launcher_probe" version "$dash_version_cli")"
    fast_probe_end_ns="$(date +%s%N)"
    fast_probe_elapsed_ms=$(( (10#$fast_probe_end_ns - 10#$fast_probe_start_ns) / 1000000 ))
    [ "$version_output" = "0.150.0" ] || fail "fast CLI version probe must still parse --version output, got $version_output"
    [ "$fast_probe_elapsed_ms" -lt 700 ] || fail "CLI version probe must not hold the command-substitution pipe until the watchdog sleep expires, took ${fast_probe_elapsed_ms}ms"

    local unknown_cli="$workspace/unknown-version-codex"
    printf '#!/usr/bin/env bash\nprintf "codex-cli dev build\\n"\n' > "$unknown_cli"
    chmod +x "$unknown_cli"
    log_output="$(env -i PATH="/usr/bin:/bin" HOME="$fake_home" "$launcher_probe" log "$unknown_cli")"
    [[ "$log_output" == "Using CODEX_CLI_PATH=$unknown_cli (version unknown; set CODEX_CLI_PATH=/path/to/codex to pin a known CLI)" ]] || fail "CLI diagnostics must explain unknown versions and explicit pinning: $log_output"

    local fd_probe_cli="$workspace/fd-probe-codex"
    local fd_state="$workspace/fd9.state"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'if { true >&9; } 2>/dev/null; then printf "open\\n" > %q; else printf "closed\\n" > %q; fi\n' "$fd_state" "$fd_state"
        printf 'printf "codex-cli 0.200.0\\n"\n'
    } > "$fd_probe_cli"
    chmod +x "$fd_probe_cli"
    version_output="$(
        exec 9>"$workspace/launcher.lock"
        env -i PATH="/usr/bin:/bin" HOME="$fake_home" "$launcher_probe" version "$fd_probe_cli"
    )"
    [ "$version_output" = "0.200.0" ] || fail "fd-guarded CLI probe must still read versions, got $version_output"
    [ "$(cat "$fd_state")" = "closed" ] || fail "CLI version probe child must not inherit launcher lock fd 9"

    local hanging_cli="$workspace/hanging-codex"
    local hanging_pid_file="$workspace/hanging.pid"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$$" > %q\n' "$hanging_pid_file"
        printf 'printf "codex-cli 9.999.0\\n"\n'
        printf 'exec sleep 30\n'
    } > "$hanging_cli"
    chmod +x "$hanging_cli"

    version_output="$(env -i PATH="/usr/bin:/bin" HOME="$fake_home" TMPDIR="$workspace" "$launcher_probe" version "$hanging_cli" || true)"
    [ -z "$version_output" ] || fail "hanging CLI probe must ignore partial version output, got $version_output"
    assert_file_exists "$hanging_pid_file"
    local hanging_pid
    hanging_pid="$(cat "$hanging_pid_file")"
    if kill -0 "$hanging_pid" 2>/dev/null; then
        sleep 0.1
    fi
    if kill -0 "$hanging_pid" 2>/dev/null; then
        kill -9 "$hanging_pid" 2>/dev/null || true
        fail "hanging CLI probe left process $hanging_pid alive"
    fi

    local hanging_log_cli="$workspace/hanging-log-codex"
    local hanging_log_pid_file="$workspace/hanging-log.pid"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$$" > %q\n' "$hanging_log_pid_file"
        printf 'printf "codex-cli 9.999.0\\n"\n'
        printf 'exec sleep 2\n'
    } > "$hanging_log_cli"
    chmod +x "$hanging_log_cli"

    log_output="$(env -i PATH="/usr/bin:/bin" HOME="$fake_home" TMPDIR="$workspace" "$launcher_probe" log "$hanging_log_cli")"
    [[ "$log_output" == "Using CODEX_CLI_PATH=$hanging_log_cli (version unknown; set CODEX_CLI_PATH=/path/to/codex to pin a known CLI)" ]] || fail "log path must time out hung CLI version probes under command substitution: $log_output"
    assert_file_exists "$hanging_log_pid_file"
    local hanging_log_pid
    hanging_log_pid="$(cat "$hanging_log_pid_file")"
    if kill -0 "$hanging_log_pid" 2>/dev/null; then
        sleep 0.1
    fi
    if kill -0 "$hanging_log_pid" 2>/dev/null; then
        kill -9 "$hanging_log_pid" 2>/dev/null || true
        fail "hanging CLI log probe left process $hanging_log_pid alive"
    fi
}

test_webview_server_cache_policy() {
    info "Checking webview server cache policy"
    python3 - "$REPO_DIR/launcher/webview-server.py" <<'PY'
import http.client
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time

server_path = pathlib.Path(sys.argv[1])
workspace = pathlib.Path(tempfile.mkdtemp(prefix="codex-webview-cache-policy-"))
proc = None

try:
    (workspace / "assets").mkdir()
    (workspace / "apps").mkdir()
    (workspace / "index.html").write_text("<!doctype html><title>Codex</title>", encoding="utf8")
    (workspace / "assets" / "app-test-abc123.js").write_text("export default 1;\n", encoding="utf8")
    (workspace / "apps" / "icon.png").write_bytes(b"png")
    fixed_mtime = 1_700_000_000
    for path in workspace.rglob("*"):
        if path.is_file():
            os.utime(path, (fixed_mtime, fixed_mtime))

    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]

    proc = subprocess.Popen(
        [sys.executable, str(server_path), str(port), "--bind", "127.0.0.1"],
        cwd=workspace,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )

    deadline = time.time() + 5
    while True:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                break
        except OSError:
            if proc.poll() is not None:
                raise AssertionError(f"webview server exited early with {proc.returncode}")
            if time.time() > deadline:
                raise AssertionError("webview server did not start")
            time.sleep(0.05)

    def request(method, path, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request(method, path, headers=headers or {})
        response = conn.getresponse()
        body = response.read()
        result = (response.status, {k.lower(): v for k, v in response.getheaders()}, body)
        conn.close()
        return result

    index_status, index_headers, _ = request("HEAD", "/index.html")
    assert index_status == 200, index_status
    assert index_headers.get("cache-control") == "no-store, max-age=0", index_headers
    assert index_headers.get("pragma") == "no-cache", index_headers
    assert index_headers.get("expires") == "0", index_headers

    asset_status, asset_headers, _ = request("HEAD", "/assets/app-test-abc123.js")
    assert asset_status == 200, asset_status
    assert asset_headers.get("cache-control") == "no-store, max-age=0", asset_headers
    assert asset_headers.get("pragma") == "no-cache", asset_headers
    assert asset_headers.get("expires") == "0", asset_headers

    cached_status, cached_headers, _ = request(
        "GET",
        "/assets/app-test-abc123.js",
        {"If-Modified-Since": asset_headers["last-modified"]},
    )
    assert cached_status == 200, (cached_status, cached_headers)
    assert cached_headers.get("cache-control") == "no-store, max-age=0", cached_headers

    refreshed_index_status, _, _ = request(
        "GET",
        "/index.html",
        {"If-Modified-Since": index_headers["last-modified"]},
    )
    assert refreshed_index_status == 200, refreshed_index_status

    icon_status, icon_headers, _ = request("HEAD", "/apps/icon.png")
    assert icon_status == 200, icon_status
    assert icon_headers.get("cache-control") == "no-store, max-age=0", icon_headers

    escaped_index_status, escaped_index_headers, _ = request("HEAD", "/assets/../index.html")
    assert escaped_index_status == 200, escaped_index_status
    assert escaped_index_headers.get("cache-control") == "no-store, max-age=0", escaped_index_headers
finally:
    if proc is not None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    shutil.rmtree(workspace, ignore_errors=True)
PY
}

test_process_detection_helper_cmdline_shapes() {
    info "Checking Electron helper process detection cmdline shapes"
    local nul_cmdline="$TMP_DIR/electron-helper-nul.cmdline"
    local space_cmdline="$TMP_DIR/electron-helper-space.cmdline"
    local main_cmdline="$TMP_DIR/electron-main.cmdline"

    printf '/opt/codex-desktop/electron\0--type=gpu-process\0--no-sandbox\0' > "$nul_cmdline"
    printf '/opt/codex-desktop/electron --type=utility --no-sandbox' > "$space_cmdline"
    printf '/opt/codex-desktop/electron --no-sandbox' > "$main_cmdline"

    (
        # shellcheck disable=SC1091
        source "$REPO_DIR/scripts/lib/process-detection.sh"
        cmdline_has_electron_helper_type "$nul_cmdline" || exit 1
        cmdline_has_electron_helper_type "$space_cmdline" || exit 1
        ! cmdline_has_electron_helper_type "$main_cmdline" || exit 1
    ) || fail "Electron helper detection must handle NUL-separated and space-joined cmdline formats"
}

test_side_by_side_launcher_identity() {
    info "Checking side-by-side launcher identity"
    local workspace="$TMP_DIR/side-by-side-launcher"
    local app_dir="$workspace/codex-cua-lab-app"
    local bin_dir="$workspace/bin"
    local help_log="$workspace/help.log"
    local symlink_help_log="$workspace/symlink-help.log"
    local linux_icon_source="$workspace/codex-linux.png"

    mkdir -p "$app_dir" "$bin_dir"
    printf '%s\n' 'linux-icon' > "$linux_icon_source"

    CODEX_INSTALLER_SOURCE_ONLY=1 \
    CODEX_APP_ID="codex-cua-lab" \
    CODEX_APP_DISPLAY_NAME="Codex CUA Lab" \
    CODEX_INSTALL_DIR="$app_dir" \
    CODEX_LINUX_ICON_SOURCE="$linux_icon_source" \
    bash -c 'source "$1"; validate_app_identity; create_start_script' _ "$REPO_DIR/install.sh"

    assert_file_exists "$app_dir/start.sh"
    assert_file_exists "$app_dir/.codex-linux/webview-server.py"
    assert_file_exists "$app_dir/.codex-linux/codex-cua-lab.png"
    cmp -s "$linux_icon_source" "$app_dir/.codex-linux/codex-cua-lab.png" \
        || fail "Expected side-by-side launcher icon to use CODEX_LINUX_ICON_SOURCE"
    assert_contains "$app_dir/start.sh" "CODEX_LINUX_APP_ID=codex-cua-lab"
    assert_contains "$app_dir/start.sh" "CODEX_LINUX_APP_DISPLAY_NAME=Codex\\\\ CUA\\\\ Lab"
    assert_contains "$app_dir/start.sh" 'CODEX_LINUX_WEBVIEW_PORT=${CODEX_WEBVIEW_PORT:-5176}'
    assert_contains "$app_dir/start.sh" 'CODEX_LINUX_SETTINGS_FILE="$APP_SETTINGS_FILE"'
    assert_contains "$app_dir/start.sh" 'export CODEX_LINUX_APP_ID CODEX_LINUX_APP_DISPLAY_NAME CODEX_LINUX_WEBVIEW_PORT CODEX_LINUX_SETTINGS_FILE'
    assert_contains "$app_dir/start.sh" 'WEBVIEW_ORIGIN="http://127.0.0.1:$CODEX_LINUX_WEBVIEW_PORT"'
    assert_contains "$app_dir/start.sh" 'ELECTRON_RENDERER_URL="${ELECTRON_RENDERER_URL:-$WEBVIEW_ORIGIN/}"'
    assert_contains "$app_dir/start.sh" "resolve_script_dir"
    assert_contains "$app_dir/start.sh" "configure_side_by_side_app_env"
    assert_contains "$app_dir/start.sh" 'XDG_CONFIG_HOME="${CODEX_XDG_CONFIG_HOME:-$APP_STATE_DIR/xdg-config}"'
    assert_contains "$app_dir/start.sh" '--class="$CODEX_LINUX_APP_ID"'
    assert_contains "$app_dir/start.sh" '--app-id="$CODEX_LINUX_APP_ID"'
    assert_contains "$app_dir/start.sh" '--user-data-dir="${CODEX_ELECTRON_USER_DATA_DIR:-$APP_STATE_DIR/electron-user-data}"'
    assert_contains "$app_dir/start.sh" "--force-renderer-accessibility"
    assert_contains "$app_dir/start.sh" 'LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/$CODEX_LINUX_APP_ID"'
    XDG_CACHE_HOME="$workspace/cache" XDG_STATE_HOME="$workspace/state" XDG_RUNTIME_DIR="$workspace/runtime" bash "$app_dir/start.sh" --help >"$help_log"
    assert_contains "$help_log" "Launches the Codex CUA Lab app."
    assert_contains "$help_log" "codex-cua-lab/launcher"

    ln -s "$app_dir/start.sh" "$bin_dir/codex-cua-lab"
    XDG_CACHE_HOME="$workspace/cache" XDG_STATE_HOME="$workspace/state" XDG_RUNTIME_DIR="$workspace/runtime" bash "$bin_dir/codex-cua-lab" --help >"$symlink_help_log"
    assert_contains "$symlink_help_log" "Launches the Codex CUA Lab app."
}

test_browser_use_node_repl_fallback_runtime() {
    info "Checking Browser Use node_repl fallback runtime"
    if [ "$(uname -m)" != "x86_64" ]; then
        info "Skipping x86_64-only Browser Use fallback runtime test"
        return 0
    fi

    local workspace="$TMP_DIR/browser-use-node-repl-fallback"
    local app_dir="$workspace/Codex.app"
    local install_dir="$workspace/install"
    local archive_root="$workspace/archive-root"
    local archive="$workspace/runtime.tar.xz"
    local output_log="$workspace/output.log"
    local archive_sha
    local true_bin

    mkdir -p "$workspace" "$install_dir/resources" "$archive_root/codex-primary-runtime/dependencies/bin"
    make_fake_browser_use_upstream_app "$app_dir"

    # Simulate the current upstream DMG shape: node_repl is under cua_node/bin,
    # but the macOS binary is not a Linux ELF.
    mkdir -p "$app_dir/Contents/Resources/cua_node/bin"
    printf '\xfe\xed\xfa\xcf' > "$app_dir/Contents/Resources/cua_node/bin/node_repl"
    chmod +x "$app_dir/Contents/Resources/cua_node/bin/node_repl"

    true_bin="$(type -P true)"
    cp "$true_bin" "$archive_root/codex-primary-runtime/dependencies/bin/node_repl"
    chmod 0755 "$archive_root/codex-primary-runtime/dependencies/bin/node_repl"
    tar -cJf "$archive" -C "$archive_root" codex-primary-runtime
    archive_sha="$(sha256sum "$archive" | awk '{print $1}')"

    (
        SCRIPT_DIR="$REPO_DIR"
        INSTALL_DIR="$install_dir"
        WORK_DIR="$workspace/work"
        ARCH="$(uname -m)"
        ICON_SOURCE="$workspace/missing-icon.png"
        CODEX_APP_ID="codex-desktop"
        XDG_CACHE_HOME="$workspace/xdg-cache"
        CODEX_NODE_REPL_PATH=
        CODEX_LINUX_NODE_REPL_SOURCE=
        CODEX_BROWSER_USE_RUNTIME_CACHE_DIR="$workspace/cache"
        CODEX_BROWSER_USE_NODE_REPL_RUNTIME_URL="file://$archive"
        CODEX_BROWSER_USE_NODE_REPL_RUNTIME_SHA256="$archive_sha"
        mkdir -p "$WORK_DIR"
        warn() { echo "[WARN] $*" >&2; }
        info() { echo "[INFO] $*" >&2; }
        # shellcheck disable=SC1091
        source "$REPO_DIR/scripts/lib/bundled-plugins.sh"
        stage_linux_computer_use_plugin() { return 1; }
        build_chrome_extension_host() {
            local fake_host="$workspace/codex-chrome-extension-host"
            printf '#!/bin/sh\n' > "$fake_host"
            chmod +x "$fake_host"
            printf '%s\n' "$fake_host"
        }
        install_bundled_plugin_resources "$app_dir"
    ) >"$output_log" 2>&1

    assert_file_exists "$install_dir/resources/node_repl"
    assert_file_exists "$install_dir/resources/plugins/openai-bundled/plugins/browser-use/scripts/browser-client.mjs"
    cmp -s "$true_bin" "$install_dir/resources/node_repl" || fail "Expected fallback node_repl to come from the runtime archive"
    assert_contains "$install_dir/resources/plugins/openai-bundled/plugins/browser-use/scripts/browser-client.mjs" "codexLinuxSiteStatusAllowlistFallback"
    assert_contains "$output_log" "Browser Use node_repl runtime is not a Linux executable for x86_64; skipping"
    assert_not_contains "$output_log" "WARN.*Browser Use node_repl runtime is not a Linux executable"
    assert_contains "$output_log" "Downloading Browser Use node_repl fallback runtime"
}

test_browser_use_node_repl_glibc_pidfd_patch_static() {
    info "Checking Browser Use node_repl glibc pidfd patch scope"
    assert_contains "$REPO_DIR/scripts/lib/bundled-plugins.sh" "patch_browser_use_node_repl_glibc_pidfd_symbols"
    assert_contains "$REPO_DIR/scripts/lib/bundled-plugins.sh" "is_browser_use_node_repl_ldd_output_compatible"
    assert_contains "$REPO_DIR/scripts/lib/bundled-plugins.sh" "install_browser_use_node_repl_executable_resource"
    assert_contains "$REPO_DIR/scripts/lib/bundled-plugins.sh" "pidfd_spawnp"
    assert_contains "$REPO_DIR/scripts/lib/bundled-plugins.sh" "pidfd_getpid"
    assert_contains "$REPO_DIR/scripts/lib/bundled-plugins.sh" "GLIBC_2.39"
    assert_contains "$REPO_DIR/scripts/lib/bundled-plugins.sh" "GLIBC_2.34"
    assert_contains "$REPO_DIR/scripts/lib/bundled-plugins.sh" "non-pidfd GLIBC_2.39 references remain"
    assert_contains "$REPO_DIR/scripts/lib/bundled-plugins.sh" 'ldd "$destination"'
}

test_browser_use_node_repl_ldd_output_compatibility() {
    info "Checking Browser Use node_repl ldd output compatibility gate"
    # shellcheck disable=SC1091
    source "$REPO_DIR/scripts/lib/bundled-plugins.sh"

    if is_browser_use_node_repl_ldd_output_compatible "/node_repl: /lib/x86_64-linux-gnu/libc.so.6: version 'GLIBC_2.39' not found (required by /node_repl)"; then
        fail "Expected ldd GLIBC version errors to be rejected"
    fi

    if is_browser_use_node_repl_ldd_output_compatible "libmissing.so => not found"; then
        fail "Expected unresolved ldd libraries to be rejected"
    fi

    is_browser_use_node_repl_ldd_output_compatible "libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6" \
        || fail "Expected ordinary ldd output to be accepted"
}

make_fake_chrome_upstream_app() {
    local app_dir="$1"
    local resources_dir="$app_dir/Contents/Resources"
    local chrome_dir="$resources_dir/plugins/openai-bundled/plugins/chrome"

    mkdir -p \
        "$resources_dir/plugins/openai-bundled/.agents/plugins" \
        "$chrome_dir/.codex-plugin" \
        "$chrome_dir/skills/control-chrome" \
        "$chrome_dir/scripts"

    cat > "$resources_dir/plugins/openai-bundled/.agents/plugins/marketplace.json" <<'JSON'
{"plugins":[{"name":"chrome","source":{"source":"local","path":"./plugins/chrome"},"policy":{"installation":"AVAILABLE"}}]}
JSON
    cat > "$chrome_dir/.codex-plugin/plugin.json" <<'JSON'
{"name":"chrome","version":"0.1.7"}
JSON
    cat > "$chrome_dir/scripts/installManifest.mjs" <<'JS'
var n={extensionId:"hehggadaopoacecdllhhajmbjkdcmajg",extensionHostName:"com.openai.codexextension"};var p=o=>{let t=`${o.extensionHostName}.json`,r={darwin:["Library/Application Support/Google/Chrome/NativeMessagingHosts"],linux:[".config/google-chrome/NativeMessagingHosts"],win32:["AppData/Local/OpenAI/extension"]}[m.platform()];return r.map(s=>l.resolve(m.homedir(),s,t))};
JS
    cat > "$chrome_dir/skills/control-chrome/SKILL.md" <<'MD'
# Chrome

```js
const { setupBrowserRuntime } = await import("<plugin root>/scripts/browser-client.mjs");
await setupBrowserRuntime({ globals: globalThis });
globalThis.browser = await agent.browsers.get("extension");
nodeRepl.write(await browser.documentation());
```

Use the browser bound to `browser` for tasks in this skill.
MD
    cat > "$chrome_dir/scripts/extension-id.json" <<'JSON'
{"extensionId":"hehggadaopoacecdllhhajmbjkdcmajg","extensionHostName":"com.openai.codexextension"}
JSON
    cat > "$chrome_dir/scripts/browser-client.mjs" <<'JS'
import{readdir as ZI}from"node:fs/promises";import L7,{platform as XI}from"node:os";import QI from"node:path";import{readFile as P7}from"fs/promises";import{resolve as D7}from"path";import{resolve as S7}from"path";import{homedir as v7,platform as E7}from"os";var Cd=S7(v7(),E7()==="win32"?"AppData\\Local\\Google\\Chrome\\User Data":"Library/Application Support/Google/Chrome");import{ClassicLevel as C7}from"./node_modules/classic-level.mjs";import{resolve as bg}from"path";import{tmpdir as T7}from"os";import{cp as A7,mkdtemp as I7,rm as HI}from"fs/promises";import{existsSync as k7}from"fs";var VI=async(e,t)=>{let r=bg(Cd,e,"Local Extension Settings",t);if(!k7(r))return null;let n=await I7(bg(R7(),"codex"));await A7(r,n,{recursive:!0}),await HI(bg(n,"LOCK"));let o=new C7(n,{createIfMissing:!1,keyEncoding:"utf8",valueEncoding:"utf8"});try{await o.open();let i=await o.get("extensionInstanceId");if(!i)return null;let s=JSON.parse(i);return typeof s!="string"?null:s}finally{await o.close(),await HI(n,{force:!0,recursive:!0})}},R7=()=>"nodeRepl"in globalThis&&globalThis.nodeRepl?globalThis.nodeRepl.tmpDir:T7();var GI=async e=>{if(e.type!=="extension"||!e.metadata?.extensionInstanceId||!e.metadata.extensionId)return e;let t=await N7(e.metadata.extensionId,e.metadata.extensionInstanceId);return t?{...e,metadata:{...e.metadata,profileName:t.name,profileIsLastUsed:t.isLastUsed.toString(),profileOrdering:t.orderingIndex.toString()}}:e},N7=async(e,t)=>(await O7(e)).find(o=>o.instanceId===t)||null,O7=async e=>{let t=await M7();return await Promise.all(t.map(async r=>({...r,instanceId:await VI(r.id,e).catch(n=>(le(n),null))})))},M7=async()=>{let e=D7(Cd,"Local State"),t=JSON.parse(await P7(e,"utf8"));return t.profile.profiles_order.map((r,n)=>{let o=t.profile.info_cache[r];return o?{id:r,name:o.name,isLastUsed:t.profile.last_used===r,orderingIndex:n,avatarUrl:o.avatar_icon}:null}).filter(r=>!!r)};
var U7=5e3,_g=__(L7.platform()),j7=async(e,{codexSessionId:t})=>{let r=tl(p_),n=e.filter(i=>i.info.type==="iab"),o=q7(n,t,r);return await Promise.all(n.filter(i=>!o.includes(i)).map(async({api:i})=>i.close())),[...e.filter(i=>i.info.type!=="iab"),...o]},q7=(e,t,r)=>t==null?[]:e.filter(n=>n.info.metadata?.codexSessionId===t&&(r==null||n.info.metadata.codexAppBuildFlavor===r)),ek=async()=>{};
function og(e){return e}function ig(e){return e==="extension"||e==="iab"||e==="cdp"}function li(e){return e}function KI(e){return e}class Id{async getBrowsers(){return[]}async get(e){return e}}function tI({browserId:e,clientInfo:t,requestedBrowserId:r}){return ig(r)?og(t.type)===r:e===r}function ld(){return null}async function mwe({globals:e}){let r=new Id,n=new Map(),l={browser_id:"extension"};if(ig(l.browser_id)){let _=li(l.browser_id);KI(_)}let p=await r.get(l.browser_id),f=n.get(p.api);return f}
function lu(e){let t=globalThis.nodeRepl?.env[e];return typeof t=="string"?t:void 0}
function Me(){let e=globalThis.nodeRepl;return e?.config==null?void 0:e}
import{platform as yT}from"node:os";function eh(){return"privileged native pipe bridge is not available; browser-client is not trusted"}function th(){let e=globalThis.nodeRepl?.nativePipe;return e==null||typeof e.createConnection!="function"?null:e}var ml=class e{constructor(t){this.socket=t}static async create(t){let r=th();if(r!=null){let n=await r.createConnection(t);return new e(n)}throw new Error(eh())}};
async fetchBlocked(e){let r=await bS(e.endpoint,{method:"GET"});if(!r.ok)throw new Error(ae(`Browser Use cannot determine if ${e.displayUrl} is allowed. Please try again later or use another source.`));let n=await r.json();return TF(n)}
JS
    cat > "$chrome_dir/scripts/check-native-host-manifest.js" <<'JS'
#!/usr/bin/env node
function getNativeHostManifestLocation() {
  if (process.platform === "win32") {
    const registryKey = `${WINDOWS_NATIVE_HOST_REGISTRY_KEY_PREFIX}\\${expectedHostName}`;
    const registryManifestPath = readWindowsRegistryDefaultValue(registryKey);

    return {
      manifestPath: registryManifestPath || getDefaultWindowsManifestPath(),
      registryKey,
      registryManifestPath,
      registryKeyExists: registryManifestPath != null,
    };
  }

  throw new Error(
    `Unsupported platform for native host manifest check: ${process.platform}. This script supports macOS and Windows.`,
  );
}
JS
    cat > "$chrome_dir/scripts/installed-browsers.js" <<'JS'
#!/usr/bin/env node
const KNOWN_BROWSERS = [
  {
    name: "Google Chrome",
    bundleIds: ["com.google.Chrome"],
    appNames: ["Google Chrome.app"],
    commands: ["google-chrome", "chrome"],
    windowsExecutable: "chrome.exe",
  },
];
JS
    cat > "$chrome_dir/scripts/chrome-is-running.js" <<'JS'
#!/usr/bin/env node
const CHROME_PROCESS_NAMES_BY_PLATFORM = {
  darwin: new Set(["Google Chrome", "Google Chrome Helper"]),
  win32: new Set(["chrome.exe"]),
};
JS
    cat > "$chrome_dir/scripts/check-extension-installed.js" <<'JS'
#!/usr/bin/env node
function resolveChromeUserDataDirectory() {
  return path.join(os.homedir(), ".config", "google-chrome");
}
JS
    cat > "$chrome_dir/scripts/open-chrome-window.js" <<'JS'
#!/usr/bin/env node
function resolveChromeUserDataDirectory() {
  return path.join(os.homedir(), ".config", "google-chrome");
}

function getOpenChromeCommand(profileDirectory) {
  const chromeArgs = [
    `--profile-directory=${profileDirectory}`,
    "--new-window",
    ABOUT_BLANK_URL,
  ];

  return {
    command: "google-chrome",
    args: chromeArgs,
  };
}
JS
}

test_chrome_plugin_staging() {
    info "Checking Chrome plugin staging"
    local workspace="$TMP_DIR/chrome-plugin"
    local app_dir="$workspace/Codex.app"
    local install_dir="$workspace/install"
    local output_log="$workspace/output.log"
    local chrome_dir="$install_dir/resources/plugins/openai-bundled/plugins/chrome"
    local host="$chrome_dir/extension-host/linux/x64/extension-host"

    mkdir -p "$workspace" "$install_dir/resources"
    make_fake_chrome_upstream_app "$app_dir"

    (
        SCRIPT_DIR="$REPO_DIR"
        INSTALL_DIR="$install_dir"
        WORK_DIR="$workspace/work"
        ARCH="x86_64"
        ICON_SOURCE="$workspace/missing-icon.png"
        CODEX_APP_ID="codex-desktop"
        mkdir -p "$WORK_DIR"
        warn() { echo "[WARN] $*" >&2; }
        info() { echo "[INFO] $*" >&2; }
        # shellcheck disable=SC1091
        source "$REPO_DIR/scripts/lib/bundled-plugins.sh"
        stage_linux_computer_use_plugin() { return 1; }
        build_chrome_extension_host() {
            local fake_host="$workspace/codex-chrome-extension-host"
            printf '#!/bin/sh\n' > "$fake_host"
            chmod +x "$fake_host"
            printf '%s\n' "$fake_host"
        }
        install_bundled_plugin_resources "$app_dir"
    ) >"$output_log" 2>&1

    assert_file_exists "$host"
    [ -x "$host" ] || fail "Expected Chrome extension host to be executable: $host"
    assert_mode "$chrome_dir/scripts/check-native-host-manifest.js" "755"
    assert_mode "$chrome_dir/scripts/installed-browsers.js" "755"
    assert_mode "$chrome_dir/scripts/chrome-is-running.js" "755"
    assert_mode "$chrome_dir/scripts/check-extension-installed.js" "755"
    assert_mode "$chrome_dir/scripts/open-chrome-window.js" "755"
    assert_contains "$chrome_dir/scripts/installManifest.mjs" "BraveSoftware/Brave-Browser/NativeMessagingHosts"
    assert_contains "$chrome_dir/scripts/installManifest.mjs" ".config/chromium/NativeMessagingHosts"
    assert_contains "$chrome_dir/scripts/installed-browsers.js" "Brave Browser"
    assert_contains "$chrome_dir/scripts/installed-browsers.js" "Chromium"
    assert_contains "$chrome_dir/scripts/chrome-is-running.js" "brave-browser"
    assert_contains "$chrome_dir/scripts/chrome-is-running.js" "chromium-browser"
    assert_contains "$chrome_dir/scripts/check-native-host-manifest.js" 'process.platform === "linux"'
    assert_contains "$chrome_dir/scripts/check-native-host-manifest.js" "BraveSoftware"
    assert_contains "$chrome_dir/scripts/check-native-host-manifest.js" "chromium"
    assert_contains "$chrome_dir/scripts/check-extension-installed.js" "linuxBraveUserDataDirectory"
    assert_contains "$chrome_dir/scripts/check-extension-installed.js" "linuxChromiumUserDataDirectory"
    assert_contains "$chrome_dir/scripts/check-extension-installed.js" "linuxCandidateWithInstalledExtension"
    assert_contains "$chrome_dir/scripts/open-chrome-window.js" "brave-browser"
    assert_contains "$chrome_dir/scripts/open-chrome-window.js" "chromium"
    assert_contains "$chrome_dir/scripts/open-chrome-window.js" "defaultBrowser ==="
    assert_contains "$chrome_dir/scripts/browser-client.mjs" "codexLinuxChromeUserDataDirectories"
    assert_contains "$chrome_dir/scripts/browser-client.mjs" '"BraveSoftware","Brave-Browser"'
    assert_contains "$chrome_dir/scripts/browser-client.mjs" '".config","chromium"'
    assert_contains "$chrome_dir/scripts/browser-client.mjs" "instanceId:await VI(o.id,e,r)"
    assert_contains "$chrome_dir/scripts/browser-client.mjs" "codexLinuxRankBrowserBackends"
    assert_contains "$chrome_dir/scripts/browser-client.mjs" "codexLinuxFilterBrowserBackends"
    assert_contains "$chrome_dir/scripts/browser-client.mjs" "codexLinuxCloseDiscardedBrowserBackends"
    assert_contains "$chrome_dir/scripts/browser-client.mjs" "await codexLinuxFilterBrowserBackends"
    assert_contains "$chrome_dir/scripts/browser-client.mjs" "getUserTabs()"
    assert_contains "$chrome_dir/scripts/browser-client.mjs" 'globalThis.nodeRepl?.env?.\[e\]'
    assert_not_contains "$chrome_dir/scripts/browser-client.mjs" 'globalThis.nodeRepl?.env\[e\]'
    assert_contains "$chrome_dir/scripts/browser-client.mjs" "codexLinuxBrowserUseConfigShim"
    assert_contains "$chrome_dir/scripts/browser-client.mjs" "writeValue: codexLinuxBrowserUseIgnoreConfigWrite"
    assert_contains "$chrome_dir/scripts/browser-client.mjs" "batchWrite: codexLinuxBrowserUseIgnoreConfigWrite"
    assert_not_contains "$chrome_dir/scripts/browser-client.mjs" "writeFile"
    assert_not_contains "$chrome_dir/scripts/browser-client.mjs" "codexLinuxBrowserUseStringifyToml"
    assert_contains "$chrome_dir/scripts/browser-client.mjs" 'Object.getPrototypeOf(repl)'
    assert_contains "$chrome_dir/scripts/browser-client.mjs" 'Object.defineProperty(prototype, "config"'
    assert_contains "$chrome_dir/scripts/browser-client.mjs" "codexLinuxBrowserUseConfigShim();let e=globalThis.nodeRepl"
    assert_contains "$chrome_dir/scripts/browser-client.mjs" "nativePipe??import.meta.__codexNativePipe"
    assert_not_contains "$chrome_dir/scripts/browser-client.mjs" "codexLinuxNativePipeFallback"
    assert_not_contains "$chrome_dir/scripts/browser-client.mjs" 'await import("node:net")'
    assert_contains "$chrome_dir/scripts/browser-client.mjs" "codexLinuxSiteStatusAllowlistFallback"
    assert_contains "$chrome_dir/skills/control-chrome/SKILL.md" "activeSummaries"
    assert_contains "$chrome_dir/skills/control-chrome/SKILL.md" "No active Chrome user tabs"
    assert_contains "$chrome_dir/skills/control-chrome/SKILL.md" "agent.browsers.list()"
    assert_contains "$chrome_dir/skills/control-chrome/SKILL.md" "browser.tabs.new()"
    assert_contains "$chrome_dir/skills/control-chrome/SKILL.md" "tabs: Array.isArray(tabs) ? tabs : \\[\\]"
    assert_contains "$chrome_dir/skills/control-chrome/SKILL.md" "...(error ? { error } : {})"
    assert_contains "$chrome_dir/skills/control-chrome/SKILL.md" "Promise.race"
    assert_contains "$chrome_dir/skills/control-chrome/SKILL.md" "Chrome profile tab probe timed out"
    assert_not_contains "$chrome_dir/skills/control-chrome/SKILL.md" "{ error: String(error) }"
    assert_not_contains "$chrome_dir/skills/control-chrome/SKILL.md" 'globalThis.browser = await agent.browsers.get("extension");'
    assert_contains "$install_dir/resources/plugins/openai-bundled/.agents/plugins/marketplace.json" '"name": "chrome"'
    assert_contains "$output_log" "Chrome plugin staged from upstream DMG"
}

test_chrome_browser_client_profile_root_variants() {
    info "Checking current Chrome browser-client profile root patch"
    local workspace="$TMP_DIR/chrome-browser-client-profile-roots"
    local chrome_dir="$workspace/chrome"
    local browser_client="$chrome_dir/scripts/browser-client.mjs"
    local patch_log="$workspace/current-browser-client.log"

    mkdir -p "$chrome_dir/scripts"

    cat > "$browser_client" <<'JS'
import{readdir as ZI}from"node:fs/promises";import L7,{platform as XI}from"node:os";import QI from"node:path";import{readFile as P7}from"fs/promises";import{resolve as D7}from"path";import{resolve as S7}from"path";import{homedir as v7,platform as E7}from"os";var Cd=S7(v7(),E7()==="win32"?"AppData\\Local\\Google\\Chrome\\User Data":"Library/Application Support/Google/Chrome");import{ClassicLevel as C7}from"./node_modules/classic-level.mjs";import{resolve as bg}from"path";import{tmpdir as T7}from"os";import{cp as A7,mkdtemp as I7,rm as HI}from"fs/promises";import{existsSync as k7}from"fs";var VI=async(e,t)=>{let r=bg(Cd,e,"Local Extension Settings",t);if(!k7(r))return null;let n=await I7(bg(R7(),"codex"));await A7(r,n,{recursive:!0}),await HI(bg(n,"LOCK"));let o=new C7(n,{createIfMissing:!1,keyEncoding:"utf8",valueEncoding:"utf8"});try{await o.open();let i=await o.get("extensionInstanceId");if(!i)return null;let s=JSON.parse(i);return typeof s!="string"?null:s}finally{await o.close(),await HI(n,{force:!0,recursive:!0})}},R7=()=>"nodeRepl"in globalThis&&globalThis.nodeRepl?globalThis.nodeRepl.tmpDir:T7();var GI=async e=>e,N7=async(e,t)=>(await O7(e)).find(o=>o.instanceId===t)||null,O7=async e=>{let t=await M7();return await Promise.all(t.map(async r=>({...r,instanceId:await VI(r.id,e).catch(n=>(le(n),null))})))},M7=async()=>{let e=D7(Cd,"Local State"),t=JSON.parse(await P7(e,"utf8"));return t.profile.profiles_order.map((r,n)=>{let o=t.profile.info_cache[r];return o?{id:r,name:o.name,isLastUsed:t.profile.last_used===r,orderingIndex:n,avatarUrl:o.avatar_icon}:null}).filter(r=>!!r)};var U7=5e3,_g=__(L7.platform()),j7=async(e,{codexSessionId:t})=>{let r=tl(p_),n=e.filter(i=>i.info.type==="iab"),o=q7(n,t,r);return await Promise.all(n.filter(i=>!o.includes(i)).map(async({api:i})=>i.close())),[...e.filter(i=>i.info.type!=="iab"),...o]},q7=(e,t,r)=>t==null?[]:e.filter(n=>n.info.metadata?.codexSessionId===t&&(r==null||n.info.metadata.codexAppBuildFlavor===r)),ek=async()=>{};function og(e){return e}function ig(e){return e==="extension"||e==="iab"||e==="cdp"}function li(e){return e}function KI(e){return e}class Id{async getBrowsers(){return[]}async get(e){return e}}function tI({browserId:e,clientInfo:t,requestedBrowserId:r}){return ig(r)?og(t.type)===r:e===r}function ld(){return null}async function mwe({globals:e}){let r=new Id,n=new Map(),l={browser_id:"extension"};if(ig(l.browser_id)){let _=li(l.browser_id);KI(_)}let p=await r.get(l.browser_id),f=n.get(p.api);return f}
JS
    node "$REPO_DIR/scripts/lib/patch-chrome-plugin.js" "$chrome_dir" >"$patch_log" 2>&1
    assert_not_contains "$patch_log" "browser-client.mjs missing patch target for Linux Chrome profile roots"
    assert_not_contains "$patch_log" "browser-client.mjs missing patch target for Linux Chrome profile metadata lookup"
    assert_not_contains "$patch_log" "browser-client.mjs missing patch target for Linux Chrome profile instance matching"
    assert_not_contains "$patch_log" "browser-client.mjs missing patch target for Linux Chrome active profile backend ordering"
    assert_not_contains "$patch_log" "browser-client.mjs missing patch target for Linux idle Chrome profile filtering"
    assert_not_contains "$patch_log" "browser-client.mjs missing patch target for Linux ambiguous active Chrome extension alias guard"
    assert_not_contains "$patch_log" "browser-client.mjs missing patch target for Linux ambiguous active Chrome extension alias check"
    assert_contains "$browser_client" "codexLinuxChromeUserDataDirectories"
    assert_contains "$browser_client" '"BraveSoftware","Brave-Browser"'
    assert_contains "$browser_client" '".config","chromium"'
    assert_contains "$browser_client" 'async(e,t,r=Cd)'
    assert_contains "$browser_client" "instanceId:await VI(o.id,e,r)"
    assert_contains "$browser_client" "codexLinuxRankBrowserBackends"
    assert_contains "$browser_client" "codexLinuxFilterBrowserBackends"
    assert_contains "$browser_client" "codexLinuxCloseDiscardedBrowserBackends"
    assert_contains "$browser_client" "await codexLinuxFilterBrowserBackends"
    assert_contains "$browser_client" "XI()"
    assert_contains "$browser_client" "codexLinuxRejectAmbiguousBrowserAlias"
    assert_contains "$browser_client" "codexLinuxRejectAmbiguousBrowserAlias(l.browser_id,await r.getBrowsers())"
}

test_chrome_marketplace_fallback_synthesis() {
    info "Checking Chrome marketplace fallback synthesis when upstream omits chrome"
    local workspace="$TMP_DIR/chrome-marketplace-fallback"
    local app_dir="$workspace/Codex.app"
    local install_dir="$workspace/install"
    local output_log="$workspace/output.log"
    local marketplace="$install_dir/resources/plugins/openai-bundled/.agents/plugins/marketplace.json"

    mkdir -p "$workspace" "$install_dir/resources"
    make_fake_chrome_upstream_app "$app_dir"

    # Upstream marketplace.json lists no chrome entry — exercises the
    # synthesized-fallback path in write_bundled_plugins_marketplace.
    cat > "$app_dir/Contents/Resources/plugins/openai-bundled/.agents/plugins/marketplace.json" <<'JSON'
{"plugins":[{"name":"browser-use","source":{"source":"local","path":"./plugins/browser-use"},"policy":{"installation":"AVAILABLE"}}]}
JSON

    # Distinctive name + category prove the synthesized entry actually
    # reads the staged plugin.json rather than reusing hardcoded values.
    cat > "$app_dir/Contents/Resources/plugins/openai-bundled/plugins/chrome/.codex-plugin/plugin.json" <<'JSON'
{"name":"chrome-fallback-test","version":"9.9.9","interface":{"category":"FallbackCategory"}}
JSON

    (
        SCRIPT_DIR="$REPO_DIR"
        INSTALL_DIR="$install_dir"
        WORK_DIR="$workspace/work"
        ARCH="x86_64"
        ICON_SOURCE="$workspace/missing-icon.png"
        CODEX_APP_ID="codex-desktop"
        mkdir -p "$WORK_DIR"
        warn() { echo "[WARN] $*" >&2; }
        info() { echo "[INFO] $*" >&2; }
        # shellcheck disable=SC1091
        source "$REPO_DIR/scripts/lib/bundled-plugins.sh"
        stage_linux_computer_use_plugin() { return 1; }
        install_bundled_plugin_resources "$app_dir"
    ) >"$output_log" 2>&1

    assert_file_exists "$marketplace"
    assert_contains "$marketplace" '"name": "chrome-fallback-test"'
    assert_contains "$marketplace" '"category": "FallbackCategory"'
    assert_contains "$marketplace" '"path": "./plugins/chrome"'
    assert_contains "$marketplace" '"installation": "AVAILABLE"'
    assert_contains "$marketplace" '"authentication": "ON_INSTALL"'
    assert_not_contains "$marketplace" "Bundled marketplace does not contain chrome plugin"
}

test_chrome_native_host_manifest_writer() {
    info "Checking Chrome native host manifest writer"
    local workspace="$TMP_DIR/chrome-native-host-manifest"
    local plugin_dir="$workspace/plugin"
    local home_dir="$workspace/home"
    local host_path="$workspace/extension-host"
    local manifest_path

    mkdir -p "$plugin_dir/scripts" "$home_dir" "$(dirname "$host_path")"
    printf '#!/bin/sh\n' > "$host_path"
    chmod +x "$host_path"
    cat > "$plugin_dir/scripts/extension-id.json" <<'JSON'
{"extensionId":"abcdefghijklmnopabcdefghijklmnop","extensionHostName":"com.example.codextest"}
JSON

    python3 - "$REPO_DIR/launcher/start.sh.template" "$host_path" "$home_dir" "$plugin_dir" <<'PY'
import subprocess
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "python3 - \"$host_path\" \"$HOME\" \"$plugin_dir\" <<'PY'\n"
start = source.index(marker) + len(marker)
end = source.index("\nPY\n", start)
script = source[start:end]
subprocess.run(
    ["python3", "-", sys.argv[2], sys.argv[3], sys.argv[4]],
    input=script,
    text=True,
    check=True,
)
PY

    for relative in \
        ".config/google-chrome/NativeMessagingHosts" \
        ".config/BraveSoftware/Brave-Browser/NativeMessagingHosts" \
        ".config/chromium/NativeMessagingHosts"; do
        manifest_path="$home_dir/$relative/com.example.codextest.json"
        assert_file_exists "$manifest_path"
        assert_contains "$manifest_path" "com.example.codextest"
        assert_contains "$manifest_path" "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"
        assert_contains "$manifest_path" "$host_path"
    done
}

make_fake_extracted_asar() {
    local root="$1"
    local bundle_body="$2"
    local settings_body="${3:-}"
    local index_body="${4:-}"

    mkdir -p "$root/webview/assets" "$root/.vite/build"
    printf 'png' > "$root/webview/assets/app-test.png"
    printf 'export{s as t};\n' > "$root/webview/assets/chunk-test.js"
    printf 'import{t as e}from"./chunk-test.js";Symbol.for(`react.transitional.element`);export{e as t};\n' > "$root/webview/assets/react-test.js"
    printf 'import{t as e}from"./chunk-test.js";Symbol.for(`react.transitional.element`);export{e as t};\n' > "$root/webview/assets/jsx-runtime-test.js"
    printf 'async function send(e,t,n,r,i){return fetch(`vscode://codex/${e}`)}function request(...e){let[t,n]=e,{params:r,select:i,signal:a,source:o}=n??{};return send(t,r,i,a,o)}export{request as l};\n' > "$root/webview/assets/setting-storage-test.js"
    cat > "$root/webview/assets/app-server-manager-signals-test.js" <<'JS'
function j(e){return e}function B(e){if(e==null||typeof e==`string`)return null;let t=Mi(e);return t==null?null:Ni(t)}function Mi(e){return`subAgent`in e?e.subAgent:null}function Ni(e){return typeof e==`string`?Pi():`thread_spawn`in e?{parentThreadId:j(e.thread_spawn.parent_thread_id),depth:e.thread_spawn.depth,agentNickname:e.thread_spawn.agent_nickname,agentRole:e.thread_spawn.agent_role}:Pi()}function Pi(){return{parentThreadId:null,depth:null,agentNickname:null,agentRole:null}}function Xl(e){return e==null?null:Zl(e.agentNickname)??Zl(B(e.source)?.agentNickname)}function Zl(e){if(e==null)return null;let t=e.trim();return t.length===0?null:t}
JS
    printf 'let marker=`hotkey-window-hotkey-state`;function i(){}export{i};\n' > "$root/webview/assets/general-settings-hotkey-test.js"
    printf 'function t(){}export{t};\n' > "$root/webview/assets/toggle-test.js"
    printf 'function n(){}export{n};\n' > "$root/webview/assets/settings-row-test.js"
    printf 'function r(){}function n(){}function t(){}export{r,n,t};\n' > "$root/webview/assets/settings-content-layout-test.js"
    if [ -n "$settings_body" ]; then
        printf '%s\n' "$settings_body" > "$root/webview/assets/general-settings-test.js"
    fi
    if [ -n "$index_body" ]; then
        printf '%s\n' "$index_body" > "$root/webview/assets/index-test.js"
    fi
    cat > "$root/package.json" <<'JSON'
{}
JSON
    printf '%s\n' "$bundle_body" > "$root/.vite/build/main-test.js"
}

test_linux_file_manager_patch_smoke() {
    info "Checking Linux file manager patch behavior"
    local workspace="$TMP_DIR/file-manager-patch"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"

    mkdir -p "$workspace"
    make_fake_extracted_asar "$extracted" 'let D={removeMenu(){},setMenuBarVisibility(){},setIcon(){},once(){}};let n=require(`electron`),t=require(`node:path`),a=require(`node:fs`);...process.platform===`win32`?{autoHideMenuBar:!0}:{},process.platform===`win32`&&D.removeMenu(),foo)}),D.once(`ready-to-show`,()=>{var sa=Mi({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>ai(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:ca,args:e=>ai(e),open:async({path:e})=>la(e)}});function ca(){let e=1;return e}async function la(e){let t=ua(e);if(t&&(0,a.statSync)(t).isFile()){n.shell.showItemInFolder(t);return}let r=t??e,i=await n.shell.openPath(r);if(i)throw Error(i)}function ua(e){return e}var Ua=Mi({id:`systemDefault`,label:`System Default App`,icon:`apps/file-explorer.png`,kind:`systemDefault`,hidden:!0,darwin:{icon:`apps/finder.png`,detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},win32:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},linux:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)}});async function Wa(e){return e}'

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$extracted/.vite/build/main-test.js" 'detect:()=>`linux-file-manager`'
    assert_contains "$extracted/.vite/build/main-test.js" 'linux:{label:`File Manager`'
    assert_contains "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&D.removeMenu(),process.platform===`win32`&&D.removeMenu(),'
    assert_not_contains "$extracted/.vite/build/main-test.js" 'D.setMenuBarVisibility(!1)'
    assert_contains "$extracted/.vite/build/main-test.js" '&&D.setIcon('
    assert_not_contains "$output_log" 'Failed to apply Linux File Manager Patch'

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_not_contains "$output_log" 'Failed to apply Linux File Manager Patch'
}

test_linux_translucent_sidebar_default_patch_smoke() {
    info "Checking Linux translucent sidebar default patch behavior"
    local workspace="$TMP_DIR/translucent-sidebar-patch"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"

    mkdir -p "$workspace"
    make_fake_extracted_asar \
        "$extracted" \
        'let D={removeMenu(){},setMenuBarVisibility(){},setIcon(){},once(){}};let n=require(`electron`),t=require(`node:path`),a=require(`node:fs`);...process.platform===`win32`?{autoHideMenuBar:!0}:{},process.platform===`win32`&&D.removeMenu(),foo)}),D.once(`ready-to-show`,()=>{var sa=Mi({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>ai(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:ca,args:e=>ai(e),open:async({path:e})=>la(e)}});function ca(){let e=1;return e}async function la(e){let t=ua(e);if(t&&(0,a.statSync)(t).isFile()){n.shell.showItemInFolder(t);return}let r=t??e,i=await n.shell.openPath(r);if(i)throw Error(i)}function ua(e){return e}var Ua=Mi({id:`systemDefault`,label:`System Default App`,icon:`apps/file-explorer.png`,kind:`systemDefault`,hidden:!0,darwin:{icon:`apps/finder.png`,detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},win32:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},linux:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)}});async function Wa(e){return e}' \
        'function settings(){let d=ot(r,e),f=at(e),p={codeThemeId:tt(a,e).id,theme:d},x=`settings.general.appearance.chromeTheme.translucentSidebar`;return {p,x}}' \
        'function runtime(){let o=`light`,a=`electron`,l=null,f=null,C=fl(l,`light`),w=fl(f,`dark`);let T=o===`light`?C:w,E;if(T.opaqueWindows&&!XZ()){document.body.classList.add(`electron-opaque`);return E}return E}'
    cat > "$extracted/webview/assets/app-main-test.js" <<'JS'
let{data:c}=Qc(y.APPEARANCE_LIGHT_CHROME_THEME,s),l;let{data:u}=Qc(y.APPEARANCE_DARK_CHROME_THEME,l),d;let x=b,S;let C=o===`light`?x:S,w;if(C.opaqueWindows&&!ba()){e.classList.add(`electron-opaque`)}
JS
    cat > "$extracted/webview/assets/diff-view-mode-test.js" <<'JS'
function oe(e,t){let n=o[t];return{accent:p(e?.accent)??n.accent,contrast:se(e?.contrast,n.contrast),fonts:le(e?.fonts),ink:p(e?.ink)??n.ink,opaqueWindows:e?.opaqueWindows??n.opaqueWindows,semanticColors:ue(e?.semanticColors,n.semanticColors),surface:p(e?.surface)??n.surface}}
JS

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$extracted/webview/assets/general-settings-test.js" 'navigator.userAgent.includes(`Linux`)&&r?.opaqueWindows==null&&(d={...d,opaqueWindows:!0})'
    assert_contains "$extracted/webview/assets/index-test.js" 'document.documentElement.dataset.codexOs===`linux`&&((o===`light`?l:f)?.opaqueWindows==null&&(T={...T,opaqueWindows:!0}))'
    assert_contains "$extracted/webview/assets/app-main-test.js" 'document.documentElement.dataset.codexOs===`linux`&&((o===`light`?c:u)?.opaqueWindows==null&&(C={...C,opaqueWindows:!0}))'
    assert_contains "$extracted/webview/assets/diff-view-mode-test.js" 'opaqueWindows:e?.opaqueWindows??(typeof navigator<`u`&&((navigator.userAgentData?.platform??navigator.platform??navigator.userAgent).toLowerCase().includes(`linux`))?!0:n.opaqueWindows)'
    assert_occurrence_count "$extracted/webview/assets/general-settings-test.js" 'navigator.userAgent.includes(`Linux`)' '1'
    assert_occurrence_count "$extracted/webview/assets/index-test.js" 'dataset.codexOs===`linux`' '1'
    assert_occurrence_count "$extracted/webview/assets/app-main-test.js" 'dataset.codexOs===`linux`' '1'
    assert_occurrence_count "$extracted/webview/assets/diff-view-mode-test.js" 'toLowerCase().includes(`linux`)' '1'
    assert_not_contains "$output_log" 'Could not find Linux opaque window default insertion point'

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_occurrence_count "$extracted/webview/assets/general-settings-test.js" 'navigator.userAgent.includes(`Linux`)' '1'
    assert_occurrence_count "$extracted/webview/assets/index-test.js" 'dataset.codexOs===`linux`' '1'
    assert_occurrence_count "$extracted/webview/assets/app-main-test.js" 'dataset.codexOs===`linux`' '1'
    assert_occurrence_count "$extracted/webview/assets/diff-view-mode-test.js" 'toLowerCase().includes(`linux`)' '1'
    assert_not_contains "$output_log" 'Could not find Linux opaque window default insertion point'
}

test_linux_tray_patch_smoke() {
    info "Checking Linux tray patch behavior"
    local workspace="$TMP_DIR/tray-patch"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"
    local bundle_body

    mkdir -p "$workspace"
    bundle_body="$(cat <<'JS'
let D={removeMenu(){},setMenuBarVisibility(){},setIcon(){},once(){}};
let n=require(`electron`),i=require(`node:path`),a=require(`node:fs`);
let t={join(){},C:{Prod:`prod`},A(){}};
let k={hide(){},isDestroyed(){return false}};
let f=`local`;
...process.platform===`win32`?{autoHideMenuBar:!0}:{},process.platform===`win32`&&D.removeMenu(),foo)}),D.once(`ready-to-show`,()=>{
var sa=Mi({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>ai(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:ca,args:e=>ai(e),open:async({path:e})=>la(e)}});
function ca(){let e=1;return e}
async function la(e){let t=ua(e);if(t&&(0,a.statSync)(t).isFile()){n.shell.showItemInFolder(t);return}let r=t??e,i=await n.shell.openPath(r);if(i)throw Error(i)}
function ua(e){return e}
var Ua=Mi({id:`systemDefault`,label:`System Default App`,icon:`apps/file-explorer.png`,kind:`systemDefault`,hidden:!0,darwin:{icon:`apps/finder.png`,detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},win32:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},linux:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)}});
async function Wa(e){return e}
function Nw(e,n){return `icon`}
async function Hw(e){return process.platform!==`win32`&&process.platform!==`darwin`?null:(zw=!0,Lw??Rw??(Rw=(async()=>{let r=await Ww(e.buildFlavor,e.repoRoot),i=new n.Tray(r.defaultIcon);return i})()))}
async function Ww(e,t){if(process.platform===`darwin`){return null}let r=process.platform===`win32`?`.ico`:`.png`,a=Nw(e,process.platform),o=[...n.app.isPackaged?[(0,i.join)(process.resourcesPath,`${a}${r}`)]:[],(0,i.join)(t,`electron`,`src`,`icons`,`${a}${r}`)];for(let e of o){let t=n.nativeImage.createFromPath(e);if(!t.isEmpty())return{defaultIcon:t,chronicleRunningIcon:null}}return{defaultIcon:await n.app.getFileIcon(process.execPath,{size:process.platform===`win32`?`small`:`normal`}),chronicleRunningIcon:null}}
var pb=class{trayMenuThreads={runningThreads:[],unreadThreads:[],pinnedThreads:[],recentThreads:[],usageLimits:[]};constructor(){this.tray={on(){},setContextMenu(){},popUpContextMenu(){}};this.onTrayButtonClick=()=>{};this.tray.on(`click`,()=>{this.onTrayButtonClick()}),this.tray.on(`right-click`,()=>{this.openNativeTrayMenu()})}async handleMessage(e){switch(e.type){case`tray-menu-threads-changed`:this.trayMenuThreads=e.trayMenuThreads;return}}openNativeTrayMenu(){this.updateChronicleTrayIcon();let e=n.Menu.buildFromTemplate(this.getNativeTrayMenuItems());e.once(`menu-will-show`,()=>{this.isNativeTrayMenuOpen=!0}),e.once(`menu-will-close`,()=>{this.isNativeTrayMenuOpen=!1,this.handleNativeTrayMenuClosed()}),this.tray.popUpContextMenu(e)}updateChronicleTrayIcon(){}getNativeTrayMenuItems(){return[]}}
v&&k.on(`close`,e=>{this.persistPrimaryWindowBounds(k,f);let t=this.getPrimaryWindows(f).some(e=>e!==k);if(process.platform===`win32`&&!this.isAppQuitting&&this.options.canHideLastLocalWindowToTray?.()===!0&&!t){e.preventDefault(),k.hide();return}if(process.platform===`darwin`&&!this.isAppQuitting&&!t){e.preventDefault(),k.hide()}});
let E=process.platform===`win32`;
let oe=async()=>{};
let se=async e=>{};
E&&oe();let ce=Hr({});
JS
)"
    make_fake_extracted_asar "$extracted" "$bundle_body"

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$extracted/.vite/build/main-test.js" 'process.platform!==`win32`&&process.platform!==`darwin`&&process.platform!==`linux`?null:'
    assert_contains "$extracted/.vite/build/main-test.js" 'nativeImage.createFromPath(process.resourcesPath+`/../content/webview/assets/app-test.png`)'
    assert_contains "$extracted/.vite/build/main-test.js" '(process.platform===`win32`||process.platform===`linux`)&&!this.isAppQuitting'
    assert_contains "$extracted/.vite/build/main-test.js" '!this.isAppQuitting&&!(typeof codexLinuxIsQuitInProgress===`function`&&codexLinuxIsQuitInProgress())'
    assert_contains "$extracted/.vite/build/main-test.js" 'setLinuxTrayContextMenu(){let e=n.Menu.buildFromTemplate(this.getNativeTrayMenuItems())'
    assert_contains "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&this.setLinuxTrayContextMenu(),this.tray.on(`click`'
    assert_contains "$extracted/.vite/build/main-test.js" 'process.platform===`linux`?this.openNativeTrayMenu():this.onTrayButtonClick()'
    assert_contains "$extracted/.vite/build/main-test.js" 'openNativeTrayMenu(){if(process.platform===`linux`&&(typeof codexLinuxIsQuitInProgress===`function`&&codexLinuxIsQuitInProgress()))return;'
    assert_contains "$extracted/.vite/build/main-test.js" 'let e=process.platform===`linux`&&this.setLinuxTrayContextMenu?this.setLinuxTrayContextMenu():n.Menu.buildFromTemplate'
    assert_contains "$extracted/.vite/build/main-test.js" 'if(process.platform===`linux`)return;e.once(`menu-will-show`'
    assert_contains "$extracted/.vite/build/main-test.js" 'this.trayMenuThreads=e.trayMenuThreads,process.platform===`linux`&&!(typeof codexLinuxIsQuitInProgress===`function`&&codexLinuxIsQuitInProgress())&&this.setLinuxTrayContextMenu?.()'
    assert_contains "$extracted/.vite/build/main-test.js" '(E||process.platform===`linux`&&(typeof codexLinuxIsTrayEnabled!==`function`||codexLinuxIsTrayEnabled()))&&oe();'
    assert_not_contains "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&this.tray.setContextMenu?.(e),this.tray.popUpContextMenu(e)'
    assert_not_contains "$output_log" 'WARN: Could not find tray'

    node - "$extracted/.vite/build/main-test.js" <<'NODE'
const fs = require("fs");

const source = fs.readFileSync(process.argv[2], "utf8");
const closeSnippet = source.match(/v&&k\.on\(`close`,e=>\{.*?\}\);/)?.[0];
if (!closeSnippet) {
  throw new Error("Could not extract patched Linux close handler");
}

function registerCloseHandler({ quitInProgress = false, isAppQuitting = false, trayEnabled = true } = {}) {
  const state = { hideCalls: 0 };
  const controller = {
    isAppQuitting,
    options: { canHideLastLocalWindowToTray: () => trayEnabled },
    persistPrimaryWindowBounds() {},
    getPrimaryWindows() {
      return [];
    },
  };
  const factory = new Function(
    "process",
    "codexLinuxIsQuitInProgress",
    "state",
    `return function(){const v=true;const f=\`local\`;const k={handlers:{},on(event,handler){this.handlers[event]=handler},hide(){state.hideCalls+=1}};${closeSnippet};return k.handlers.close;};`,
  );
  const makeHandler = factory({ platform: "linux" }, () => quitInProgress, state);
  const handler = makeHandler.call(controller);
  return { handler, state };
}

function runCloseWithoutHelper({ trayEnabled = true, isAppQuitting = false } = {}) {
  const event = {
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
  };
  const state = { hideCalls: 0 };
  const controller = {
    isAppQuitting,
    options: { canHideLastLocalWindowToTray: () => trayEnabled },
    persistPrimaryWindowBounds() {},
    getPrimaryWindows() {
      return [];
    },
  };
  const factory = new Function(
    "process",
    "state",
    `return function(){const v=true;const f=\`local\`;const k={handlers:{},on(event,handler){this.handlers[event]=handler},hide(){state.hideCalls+=1}};${closeSnippet};return k.handlers.close;};`,
  );
  const handler = factory({ platform: "linux" }, state).call(controller);
  handler(event);
  return { event, state };
}

function runClose(options) {
  const event = {
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
  };
  const { handler, state } = registerCloseHandler(options);
  handler(event);
  return { event, state };
}

let result = runClose({ trayEnabled: true, quitInProgress: false, isAppQuitting: false });
if (!result.event.prevented || result.state.hideCalls !== 1) {
  throw new Error("normal Linux close should still hide to tray");
}

result = runClose({ trayEnabled: true, quitInProgress: true, isAppQuitting: false });
if (result.event.prevented || result.state.hideCalls !== 0) {
  throw new Error("quit-in-progress Linux close should not hide to tray");
}

result = runClose({ trayEnabled: true, quitInProgress: false, isAppQuitting: true });
if (result.event.prevented || result.state.hideCalls !== 0) {
  throw new Error("app.quit close should not hide to tray when upstream quit flag is already set");
}

result = runCloseWithoutHelper({ trayEnabled: true, isAppQuitting: false });
if (!result.event.prevented || result.state.hideCalls !== 1) {
  throw new Error("Linux close should still hide to tray when the quit helper is unavailable");
}
NODE

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'process.platform!==`win32`&&process.platform!==`darwin`&&process.platform!==`linux`?null:' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'nativeImage.createFromPath(process.resourcesPath' '3'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'nativeImage.createFromPath(process.resourcesPath+`/../.codex-linux/codex-desktop-tray.png`)' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'nativeImage.createFromPath(process.resourcesPath+`/../.codex-linux/codex-desktop.png`)' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'nativeImage.createFromPath(process.resourcesPath+`/../content/webview/assets/app-test.png`)' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'process.platform===`linux`)&&!this.isAppQuitting' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'setLinuxTrayContextMenu(){' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&this.setLinuxTrayContextMenu(),this.tray.on(`click`' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'process.platform===`linux`?this.openNativeTrayMenu():this.onTrayButtonClick()' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'typeof codexLinuxIsQuitInProgress===`function`&&codexLinuxIsQuitInProgress()' '3'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'openNativeTrayMenu(){if(process.platform===`linux`&&(typeof codexLinuxIsQuitInProgress===`function`&&codexLinuxIsQuitInProgress()))return;' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'let e=process.platform===`linux`&&this.setLinuxTrayContextMenu?this.setLinuxTrayContextMenu():n.Menu.buildFromTemplate' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'if(process.platform===`linux`)return;e.once(`menu-will-show`' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&!(typeof codexLinuxIsQuitInProgress===`function`&&codexLinuxIsQuitInProgress())&&this.setLinuxTrayContextMenu?.()' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&(typeof codexLinuxIsTrayEnabled!==`function`||codexLinuxIsTrayEnabled()))&&oe' '1'
}

test_linux_explicit_quit_patch_smoke() {
    info "Checking Linux explicit quit patch behavior"
    local workspace="$TMP_DIR/explicit-quit-patch"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"
    local bundle_body

    mkdir -p "$workspace"
    bundle_body="$(cat <<'JS'
let n=require(`electron`),i=require(`node:path`),a=require(`node:fs`);
var pb=class{getNativeTrayMenuItems(){return[{label:rB(this.appName),click:()=>{n.app.quit()}}]}};
function qB(r,o){if(o.type===`quit-app`){n.app.quit();return}return o}
n.app.on(`before-quit`,o=>{let s=BI(),c=t.sr().some(e=>e.status===`ACTIVE`);if(e||i.canQuitWithoutPrompt()||r||!s&&!c){g=!0,a.markAppQuitting();return}let l=n.app.getName();if(n.dialog.showMessageBoxSync({type:`warning`,buttons:[`Quit`,`Cancel`],defaultId:0,cancelId:1,noLink:!0,title:`Quit ${l}?`,message:`Quit ${l}?`,detail:vB({hasInProgressLocalConversation:s,hasEnabledAutomations:c})})!==0){o.preventDefault();return}i.markQuitApproved(),g=!0,a.markAppQuitting()});
n.app.on(`will-quit`,e=>{if(g=!0,!h){if(i.shouldSkipDrainBeforeQuit()){mB({hotkeyWindowLifecycleManager:c,globalDictationLifecycleManager:l,flushAndDisposeContexts:d,disposables:f});return}e.preventDefault(),h=!0,c.dispose(),l.dispose(),Promise.all([u.flush(),p.flush()]).finally(()=>{d(),f.dispose(),n.app.quit()})}});
JS
)"
    make_fake_extracted_asar "$extracted" "$bundle_body"

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$extracted/.vite/build/main-test.js" 'codexLinuxPrepareForExplicitQuit=()=>{codexLinuxExplicitQuitApproved=!0,codexLinuxMarkQuitInProgress()}'
    assert_contains "$extracted/.vite/build/main-test.js" 'codexLinuxShouldBypassQuitPrompt=()=>codexLinuxExplicitQuitApproved===!0'
    assert_contains "$extracted/.vite/build/main-test.js" '{label:rB(this.appName),click:()=>{typeof codexLinuxPrepareForExplicitQuit===`function`?codexLinuxPrepareForExplicitQuit():typeof codexLinuxMarkQuitInProgress===`function`&&codexLinuxMarkQuitInProgress(),n.app.quit()}}'
    assert_contains "$extracted/.vite/build/main-test.js" 'if(o.type===`quit-app`){typeof codexLinuxPrepareForExplicitQuit===`function`?codexLinuxPrepareForExplicitQuit():typeof codexLinuxMarkQuitInProgress===`function`&&codexLinuxMarkQuitInProgress(),n.app.quit();return}'
    assert_contains "$extracted/.vite/build/main-test.js" 'if((typeof codexLinuxShouldBypassQuitPrompt===`function`&&codexLinuxShouldBypassQuitPrompt())||e||i.canQuitWithoutPrompt()||r||!s&&!c){process.platform===`linux`&&typeof codexLinuxMarkQuitInProgress===`function`&&codexLinuxMarkQuitInProgress(),g=!0,a.markAppQuitting();return}'
    assert_contains "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&typeof codexLinuxMarkQuitInProgress===`function`&&codexLinuxMarkQuitInProgress(),i.markQuitApproved(),g=!0,a.markAppQuitting()'
    assert_contains "$extracted/.vite/build/main-test.js" 'codexLinuxFinalizeQuit=()=>{d(),f.dispose(),n.app.quit()},codexLinuxDrainPromise=Promise.all('
    assert_contains "$extracted/.vite/build/main-test.js" 'codexLinuxExplicitQuitDrainTimeoutMs'
    assert_contains "$extracted/.vite/build/main-test.js" 'setTimeout(e,typeof codexLinuxExplicitQuitDrainTimeoutMs'
    assert_not_contains "$extracted/.vite/build/main-test.js" '\`number\`'
    assert_not_contains "$output_log" 'WARN: Could not find tray quit menu handler'
    assert_not_contains "$output_log" 'WARN: Could not find quit-app IPC handler'
    assert_not_contains "$output_log" 'WARN: Could not find before-quit confirmation guard'
    assert_not_contains "$output_log" 'WARN: Could not find will-quit drain sequence'

    node - "$extracted/.vite/build/main-test.js" <<'NODE'
const fs = require("fs");

const source = fs.readFileSync(process.argv[2], "utf8");
const helperSnippet = source.match(/let codexLinuxQuitInProgress=!1,[^;]*codexLinuxShouldBypassQuitPrompt=\(\)=>codexLinuxExplicitQuitApproved===!0,[^;]*codexLinuxIsQuitInProgress=\(\)=>codexLinuxQuitInProgress===!0;/)?.[0];
const traySnippet = source.match(/\{label:rB\(this\.appName\),click:\(\)=>\{typeof codexLinuxPrepareForExplicitQuit===`function`\?codexLinuxPrepareForExplicitQuit\(\):typeof codexLinuxMarkQuitInProgress===`function`&&codexLinuxMarkQuitInProgress\(\),n\.app\.quit\(\)\}\}/)?.[0];
const quitAppSnippet = source.match(/if\(o\.type===`quit-app`\)\{typeof codexLinuxPrepareForExplicitQuit===`function`\?codexLinuxPrepareForExplicitQuit\(\):typeof codexLinuxMarkQuitInProgress===`function`&&codexLinuxMarkQuitInProgress\(\),n\.app\.quit\(\);return\}/)?.[0];
const beforeQuitSnippet = source.match(/if\(\(typeof codexLinuxShouldBypassQuitPrompt===`function`&&codexLinuxShouldBypassQuitPrompt\(\)\)\|\|e\|\|i\.canQuitWithoutPrompt\(\)\|\|r\|\|!s&&!c\)\{process\.platform===`linux`&&typeof codexLinuxMarkQuitInProgress===`function`&&codexLinuxMarkQuitInProgress\(\),g=!0,a\.markAppQuitting\(\);return\}/)?.[0];
if (!helperSnippet || !traySnippet || !quitAppSnippet || !beforeQuitSnippet) {
  throw new Error("Could not extract explicit quit snippets");
}

function runTrayQuit({ withHelper = true } = {}) {
  const state = { markCalls: 0, prepareCalls: 0, quitCalls: 0 };
  const app = { quit() { state.quitCalls += 1; } };
  const mark = () => { state.markCalls += 1; };
  const prepare = withHelper ? () => { state.prepareCalls += 1; mark(); } : undefined;
  const factory = new Function(
    "n",
    "rB",
    "codexLinuxPrepareForExplicitQuit",
    "codexLinuxMarkQuitInProgress",
    `return (${traySnippet}).click;`,
  );
  const click = factory({ app }, () => "Quit", prepare, mark);
  click();
  return state;
}

function runQuitApp({ withHelper = true } = {}) {
  const state = { markCalls: 0, prepareCalls: 0, quitCalls: 0 };
  const app = { quit() { state.quitCalls += 1; } };
  const mark = () => { state.markCalls += 1; };
  const prepare = withHelper ? () => { state.prepareCalls += 1; mark(); } : undefined;
  const handler = new Function(
    "n",
    "codexLinuxPrepareForExplicitQuit",
    "codexLinuxMarkQuitInProgress",
    "o",
    `${quitAppSnippet};return null;`,
  );
  handler({ app }, prepare, mark, { type: "quit-app" });
  return state;
}

function runBeforeQuitBypass() {
  const state = { markCalls: 0 };
  const scope = new Function(
    "BI",
    "t",
    `${helperSnippet}return {runBeforeQuitCheck(e,i,r,a){let s=BI(),c=t.sr().some(e=>e.status===\`ACTIVE\`);${beforeQuitSnippet}return \`prompt\`;},prepare:codexLinuxPrepareForExplicitQuit,bypass:codexLinuxShouldBypassQuitPrompt,marked:codexLinuxIsQuitInProgress};`,
  )(
    () => true,
    { sr: () => [{ status: "ACTIVE" }] },
  );
  const controller = {
    canQuitWithoutPrompt() { return false; },
    markQuitApproved() {},
  };
  const appQuitting = { markAppQuitting() { state.markCalls += 1; } };
  scope.prepare();
  const bypassed = scope.runBeforeQuitCheck(false, controller, false, appQuitting);
  return { state, bypassed, shouldBypass: scope.bypass(), marked: scope.marked() };
}

let state = runTrayQuit();
if (state.prepareCalls !== 1 || state.markCalls !== 1 || state.quitCalls !== 1) {
  throw new Error("tray quit should prepare explicit quit before quitting");
}

state = runQuitApp();
if (state.prepareCalls !== 1 || state.markCalls !== 1 || state.quitCalls !== 1) {
  throw new Error("quit-app IPC should prepare explicit quit before quitting");
}

state = runTrayQuit({ withHelper: false });
if (state.prepareCalls !== 0 || state.markCalls !== 1 || state.quitCalls !== 1) {
  throw new Error("tray quit should still fall back to the quit-in-progress marker");
}

state = runQuitApp({ withHelper: false });
if (state.prepareCalls !== 0 || state.markCalls !== 1 || state.quitCalls !== 1) {
  throw new Error("quit-app IPC should still fall back to the quit-in-progress marker");
}

state = runBeforeQuitBypass();
if (!state.shouldBypass || state.bypassed !== undefined || state.state.markCalls !== 1 || !state.marked) {
  throw new Error("before-quit should bypass the Linux quit confirmation after an explicit quit");
}
NODE

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxPrepareForExplicitQuit=()=>{codexLinuxExplicitQuitApproved=!0,codexLinuxMarkQuitInProgress()}' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxShouldBypassQuitPrompt=()=>codexLinuxExplicitQuitApproved===!0' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'typeof codexLinuxPrepareForExplicitQuit===`function`?codexLinuxPrepareForExplicitQuit():typeof codexLinuxMarkQuitInProgress===`function`&&codexLinuxMarkQuitInProgress()' '2'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'typeof codexLinuxShouldBypassQuitPrompt===`function`&&codexLinuxShouldBypassQuitPrompt()' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxDrainPromise=Promise.all(' '1'
}

test_keybinds_settings_tab_patch_smoke() {
    info "Checking Linux desktop settings tab patch behavior"
    local workspace="$TMP_DIR/keybinds-settings-patch"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"

    mkdir -p "$workspace"
    make_fake_extracted_asar "$extracted" 'let D={removeMenu(){},setMenuBarVisibility(){},setIcon(){},once(){}};let t={join(){}};let a={existsSync(){return true},statSync(){return {isFile(){return false}}}};let n={shell:{openPath(){return ""},showItemInFolder(){}}};...process.platform===`win32`?{autoHideMenuBar:!0}:{},process.platform===`win32`&&D.removeMenu(),foo)}),D.once(`ready-to-show`,()=>{var sa=Mi({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>ai(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:ca,args:e=>ai(e),open:async({path:e})=>la(e)}});function ca(){let e=1;return e}async function la(e){let t=ua(e);if(t&&(0,a.statSync)(t).isFile()){n.shell.showItemInFolder(t);return}let r=t??e,i=await n.shell.openPath(r);if(i)throw Error(i)}function ua(e){return e}var Ua=Mi({id:`systemDefault`,label:`System Default App`,icon:`apps/file-explorer.png`,kind:`systemDefault`,hidden:!0,darwin:{icon:`apps/finder.png`,detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},win32:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},linux:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)}});async function Wa(e){return e}'

    cat > "$extracted/webview/assets/settings-sections-test.js" <<'JS'
var e=[`general-settings`,`profile`,`keyboard-shortcuts`,`account`],t=`general-settings`,n=function(){},r=[{slug:`general-settings`},{slug:`profile`},{slug:`appearance`},{slug:`keyboard-shortcuts`}];
JS
    cat > "$extracted/webview/assets/settings-shared-test.js" <<'JS'
import{t as d}from"./jsx-runtime-test.js";var c={"general-settings":{id:`settings.nav.general-settings`,defaultMessage:`General`,description:`Title for general settings section`},"keyboard-shortcuts":{id:`settings.nav.keyboard-shortcuts`,defaultMessage:`Keyboard shortcuts`,description:`Title for keyboard shortcuts settings section`}};function m(e){let t=(0,u.c)(17),{slug:r}=e;switch(r){case`keyboard-shortcuts`:{let e;return t[1]===Symbol.for(`react.memo_cache_sentinel`)?(e=(0,d.jsx)(n,{id:`settings.section.keyboard-shortcuts`,defaultMessage:`Keyboard shortcuts`,description:`Title for keyboard shortcuts settings section`}),t[1]=e):e=t[1],e}case`general-settings`:{let e;return t[2]===Symbol.for(`react.memo_cache_sentinel`)?(e=(0,d.jsx)(n,{id:`settings.section.general-settings`,defaultMessage:`General`,description:`Title for general settings section`}),t[2]=e):e=t[2],e}}}
JS
    cat > "$extracted/webview/assets/index-test.js" <<'JS'
var Xge={"general-settings":xh,"keyboard-shortcuts":ks,appearance:Pf,agent:gU},H7={},Zge=[`general-settings`,`profile`,`keyboard-shortcuts`,`appearance`,`agent`,`personalization`,`mcp-settings`,`connections`,`git-settings`,`local-environments`,`worktrees`,`browser-use`,`computer-use`,`data-controls`],Qge=[{key:`app`,heading:H7.appHeading,slugs:[`general-settings`,`profile`,`keyboard-shortcuts`,`appearance`,`connections`,`git-settings`,`usage`]}];function n_e(){let l=`electron`,e=e=>{switch(e.slug){case`appearance`:case`git-settings`:case`worktrees`:case`local-environments`:case`data-controls`:case`environments`:return l===`electron`;case`account`:case`general-settings`:case`agent`:case`personalization`:case`keyboard-shortcuts`:case`mcp-settings`:return!0}};if(O)bb0:switch(D.slug){case`usage`:k=g;break bb0;case`appearance`:case`general-settings`:case`agent`:case`git-settings`:case`account`:case`data-controls`:case`personalization`:case`keyboard-shortcuts`:k=!1;break bb0;}}function s_e(e){let{slug:n}=e,r=c_e[n];return (0,$.jsx)(r,{})}var c_e={"general-settings":(0,Z.lazy)(()=>s(()=>import(`./general-settings-DZbwMmWz.js`).then(e=>({default:e.GeneralSettings})),__vite__mapDeps([4]),import.meta.url)),"keyboard-shortcuts":(0,Z.lazy)(()=>s(()=>import(`./keyboard-shortcuts-settings-test.js`),[],import.meta.url)),appearance:(0,Z.lazy)(()=>s(()=>import(`./appearance-settings-D4xYjo5o.js`).then(e=>({default:e.AppearanceSettings})),__vite__mapDeps([56]),import.meta.url)),agent:(0,Z.lazy)(()=>Promise.resolve({default:l_e}))};
JS
    cat > "$extracted/webview/assets/keyboard-shortcuts-settings-test.js" <<'JS'
slug:`keyboard-shortcuts`;export default function KeyboardShortcutsSettings(){}
JS

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_file_exists "$extracted/webview/assets/linux-desktop-settings-linux.js"
    [ ! -f "$extracted/webview/assets/keybinds-settings-linux.js" ] || fail "Old Keybinds settings asset should not be written for current native Keyboard Shortcuts"
    assert_contains "$extracted/webview/assets/linux-desktop-settings-linux.js" "function LinuxDesktopSettings"
    assert_contains "$extracted/webview/assets/linux-desktop-settings-linux.js" "Linux desktop"
    assert_contains "$extracted/webview/assets/linux-desktop-settings-linux.js" "System tray"
    assert_contains "$extracted/webview/assets/linux-desktop-settings-linux.js" "Warm start"
    assert_contains "$extracted/webview/assets/linux-desktop-settings-linux.js" "Build information"
    assert_contains "$extracted/webview/assets/linux-desktop-settings-linux.js" "codex-linux-system-tray-enabled"
    assert_contains "$extracted/webview/assets/linux-desktop-settings-linux.js" "codex-linux-warm-start-enabled"
    assert_contains "$extracted/webview/assets/linux-desktop-settings-linux.js" "codex-linux-prompt-window-enabled"
    assert_contains "$extracted/webview/assets/linux-desktop-settings-linux.js" ' as Toggle}from"./'
    assert_not_contains "$extracted/webview/assets/linux-desktop-settings-linux.js" "function LinuxSwitch"
    assert_not_contains "$extracted/webview/assets/linux-desktop-settings-linux.js" "bg-token-text-primary"
    assert_not_contains "$extracted/webview/assets/linux-desktop-settings-linux.js" "translate-x-4"
    assert_contains "$extracted/webview/assets/settings-sections-test.js" 'slug:`linux-desktop`'
    assert_contains "$extracted/webview/assets/settings-shared-test.js" "settings.nav.linux-desktop"
    assert_contains "$extracted/webview/assets/settings-shared-test.js" "settings.section.linux-desktop"
    assert_contains "$extracted/webview/assets/index-test.js" "linux-desktop-settings-linux.js"
    assert_contains "$extracted/webview/assets/index-test.js" '"linux-desktop":'
    assert_contains "$extracted/webview/assets/index-test.js" 'Zge=\[`general-settings`,`linux-desktop`'
    assert_contains "$extracted/webview/assets/index-test.js" 'slugs:\[`general-settings`,`linux-desktop`'
    assert_contains "$extracted/webview/assets/index-test.js" 'case`linux-desktop`:return l===`electron`'
    assert_not_contains "$extracted/webview/assets/index-test.js" "keybinds-settings-linux.js"
    assert_not_contains "$extracted/webview/assets/index-test.js" "codexLinuxKeybindOverridesRuntime"

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_occurrence_count "$extracted/webview/assets/settings-sections-test.js" 'slug:`linux-desktop`' '1'
    assert_occurrence_count "$extracted/webview/assets/settings-shared-test.js" "settings.nav.linux-desktop" '1'
    assert_occurrence_count "$extracted/webview/assets/settings-shared-test.js" "settings.section.linux-desktop" '1'
    assert_occurrence_count "$extracted/webview/assets/index-test.js" "linux-desktop-settings-linux.js" '1'
}

test_keybinds_settings_patch_warns_on_bundle_shape_miss() {
    info "Checking Keybinds settings bundle-shape warning"
    local workspace="$TMP_DIR/keybinds-settings-shape-warning"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"

    mkdir -p "$workspace"
    make_fake_extracted_asar "$extracted" 'let D={removeMenu(){},setMenuBarVisibility(){},setIcon(){},once(){}};let t={join(){}};let a={existsSync(){return true},statSync(){return {isFile(){return false}}}};let n={shell:{openPath(){return ""},showItemInFolder(){}}};...process.platform===`win32`?{autoHideMenuBar:!0}:{},process.platform===`win32`&&D.removeMenu(),foo)}),D.once(`ready-to-show`,()=>{var sa=Mi({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>ai(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:ca,args:e=>ai(e),open:async({path:e})=>la(e)}});function ca(){let e=1;return e}async function la(e){let t=ua(e);if(t&&(0,a.statSync)(t).isFile()){n.shell.showItemInFolder(t);return}let r=t??e,i=await n.shell.openPath(r);if(i)throw Error(i)}function ua(e){return e}var Ua=Mi({id:`systemDefault`,label:`System Default App`,icon:`apps/file-explorer.png`,kind:`systemDefault`,hidden:!0,darwin:{icon:`apps/finder.png`,detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},win32:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},linux:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)}});async function Wa(e){return e}'
    rm "$extracted/webview/assets/settings-row-test.js"
    cat > "$extracted/webview/assets/keyboard-shortcuts-settings-test.js" <<'JS'
slug:`keyboard-shortcuts`;export default function KeyboardShortcutsSettings(){}
JS
    cat > "$extracted/webview/assets/settings-sections-test.js" <<'JS'
var e=[`general-settings`,`profile`,`keyboard-shortcuts`],t=`general-settings`,n=[{slug:`general-settings`},{slug:`keyboard-shortcuts`}];
JS
    cat > "$extracted/webview/assets/settings-shared-test.js" <<'JS'
var c={"general-settings":{id:`settings.nav.general-settings`,defaultMessage:`General`,description:`Title for general settings section`},"keyboard-shortcuts":{id:`settings.nav.keyboard-shortcuts`,defaultMessage:`Keyboard shortcuts`,description:`Title for keyboard shortcuts settings section`}};function m(e){let t=(0,u.c)(17),{slug:r}=e;switch(r){case`general-settings`:{let e;return t[2]===Symbol.for(`react.memo_cache_sentinel`)?(e=(0,d.jsx)(n,{id:`settings.section.general-settings`,defaultMessage:`General`,description:`Title for general settings section`}),t[2]=e):e=t[2],e}}}
JS
    cat > "$extracted/webview/assets/index-test.js" <<'JS'
var Xge={"general-settings":xh,appearance:Pf},H7={},Zge=[`general-settings`,`appearance`],Qge=[{key:`app`,heading:H7.appHeading,slugs:[`general-settings`,`appearance`,`connections`,`git-settings`,`usage`]}];
JS

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$output_log" "WARN: Keybinds settings patch skipped"
    assert_contains "$output_log" "could not add Linux desktop visibility"
    [ ! -f "$extracted/webview/assets/linux-desktop-settings-linux.js" ] || fail "Linux desktop settings asset should not be written when route bundle is missing"
    [ ! -f "$extracted/webview/assets/linux-settings-row-linux.js" ] || fail "Fallback row asset should not be written when route bundle is missing"
    [ ! -f "$extracted/webview/assets/linux-settings-section-linux.js" ] || fail "Fallback section asset should not be written when route bundle is missing"
    [ ! -f "$extracted/webview/assets/linux-settings-group-linux.js" ] || fail "Fallback group asset should not be written when route bundle is missing"
    assert_not_contains "$extracted/webview/assets/settings-sections-test.js" 'slug:`linux-desktop`'
    assert_not_contains "$extracted/webview/assets/index-test.js" "linux-desktop-settings-linux.js"
}

test_browser_annotation_screenshot_patch_smoke() {
    info "Checking browser annotation screenshot patch behavior"
    local workspace="$TMP_DIR/browser-annotation-patch"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"

    mkdir -p "$workspace"
    make_fake_extracted_asar "$extracted" 'let D={removeMenu(){},setMenuBarVisibility(){},setIcon(){},once(){}};let n=require(`electron`),t=require(`node:path`),a=require(`node:fs`);...process.platform===`win32`?{autoHideMenuBar:!0}:{},process.platform===`win32`&&D.removeMenu(),foo)}),D.once(`ready-to-show`,()=>{})'
    cat > "$extracted/.vite/build/comment-preload.js" <<'JS'
if(ve&&M?.anchor.kind===`element`){let e=hl(M,y.current)??null,t=e==null?null:El(e);ke=t?.rect??Rl(M.anchor),je=t?.borderRadius,Ae=Xl(M.anchor,ke,_.width,_.height)}
Se=(!ve&&xe!=null?k.filter(e=>e.id!==xe.id):k).flatMap
JS

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$extracted/.vite/build/comment-preload.js" 'if(ve&&M?.anchor.kind===`element`){ke=Rl(M.anchor),je=void 0,Ae=Xl(M.anchor,ke,_.width,_.height)}'
    assert_contains "$extracted/.vite/build/comment-preload.js" 'Se=(ve?_e:!ve&&xe!=null?k.filter(e=>e.id!==xe.id):k).flatMap'
    assert_not_contains "$extracted/.vite/build/comment-preload.js" 'hl(M,y.current)'

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_occurrence_count "$extracted/.vite/build/comment-preload.js" 'ke=Rl(M.anchor)' '1'
    assert_occurrence_count "$extracted/.vite/build/comment-preload.js" 'Se=(ve?_e' '1'
}

test_linux_single_instance_patch_smoke() {
    info "Checking Linux single-instance patch behavior"
    local workspace="$TMP_DIR/single-instance-patch"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"
    local bundle_body

    mkdir -p "$workspace"
    bundle_body="$(cat <<'JS'
let S=globalThis.__codexSmoke;
let n={app:{whenReady(){return Promise.resolve()},quit(){S.quitCount++},requestSingleInstanceLock(){S.lockCount++;return true},on(e,t){S.appHandlers[e]=t},off(e,t){S.offHandlers[e]=t}}};
let t={Er(){return {info(){}}},jn:class{add(e){S.disposables.push(e)}},y(){return{setSecondInstanceArgsHandler:e=>{S.initialHandler=e}}},g(e){return e},t(e){return Array.isArray(e)&&e.includes(`--open-project`)}};
let i={default:{dirname(e){S.dirnameCalls.push(e);return `/tmp`}}},o={mkdirSync(...e){S.mkdirSyncCalls.push(e)},rmSync(...e){S.rmSyncCalls.push(e)}},u={default:{createServer(e){S.createServerCalls++;S.socketConnectionHandler=e;return S.socketServer}}};
async function uT(){let{setSecondInstanceArgsHandler:l}=t.y(),k=new t.jn;k.add(()=>{}),t.Er().info(`Launching app`,{safe:{agentRunId:process.env.CODEX_ELECTRON_AGENT_RUN_ID?.trim()||null}});let A=Date.now();await n.app.whenReady();let w=(...e)=>{S.traceCalls.push(e)},M={globalState:S.globalState,repoRoot:`/tmp/codex-smoke`},z=`local`,R={deepLinks:{queueProcessArgs(e){S.queueArgs.push(e);return Array.isArray(e)&&e.some(e=>{let t=String(e);return t.startsWith(`codex://`)||t.startsWith(`codex-browser-sidebar://`)})},flushPendingDeepLinks(){S.flushPendingDeepLinksCalls++;return Promise.resolve()}},navigateToRoute(e,t){S.navigateCalls.push({windowId:e.id,path:t})}},P={windowManager:{sendMessageToWindow(e,t){S.messages.push({windowId:e.id,message:t})}},hotkeyWindowLifecycleManager:{hide(){S.hideCalls++},show(){S.showCalls++;return S.hotkeyWindowShowResult},ensureHotkeyWindowController(){S.ensureHotkeyWindowControllerCalls++;return S.hotkeyWindowController}},getPrimaryWindow(){return S.primaryWindow},createFreshLocalWindow(e){S.createFreshLocalWindowCalls.push(e);return S.createdWindow},ensureHostWindow(e){S.ensureHostWindowCalls.push(e);return S.primaryWindow??S.createdWindow}},g={reportNonFatal(e,t){S.errors.push({error:String(e),meta:t})}},re=e=>{S.focusCalls.push(e.id);e.isMinimized()&&e.restore(),e.show(),e.focus()},ie=async()=>{S.ieCalls++;try{P.hotkeyWindowLifecycleManager.hide();let e=P.getPrimaryWindow()??await P.createFreshLocalWindow(`/`);if(e==null)return;re(e)}catch(e){g.reportNonFatal(e instanceof Error?e:`Failed to open window on second instance`,{kind:`second-instance-open-window-failed`})}};l(e=>{let n=t.t(t.g(e));if(R.deepLinks.queueProcessArgs(e)){n&&ie();return}if(n){ie();return}ie()});let ae=async(e,t)=>{P.hotkeyWindowLifecycleManager.hide();let n=P.getPrimaryWindow(),r=n??await P.createFreshLocalWindow(e);r!=null&&(n!=null&&t.navigateExistingWindow&&R.navigateToRoute(r,e),re(r))},oe=async()=>{S.trayStartupCalls++};let E=process.platform===`win32`;E&&oe();let me=await P.ensureHostWindow(z);me&&re(me),w(`local window ensured`,A,{hostId:z,localWindowVisible:me?.isVisible()??!1}),A=Date.now(),await R.deepLinks.flushPendingDeepLinks()}
JS
)"
    make_fake_extracted_asar "$extracted" "$bundle_body"

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&process.env.CODEX_LINUX_MULTI_LAUNCH!==`1`&&!n.app.requestSingleInstanceLock()'
    assert_contains "$extracted/.vite/build/main-test.js" 'codexLinuxHandleLaunchActionArgs'
    assert_contains "$extracted/.vite/build/main-test.js" 'e.includes(`--new-chat`)'
    assert_contains "$extracted/.vite/build/main-test.js" 'e.includes(`--quick-chat`)'
    assert_contains "$extracted/.vite/build/main-test.js" 'e.includes(`--prompt-chat`)'
    assert_contains "$extracted/.vite/build/main-test.js" 'e.includes(`--hotkey-window`)'
    assert_contains "$extracted/.vite/build/main-test.js" 'codexLinuxHasDeepLink'
    assert_contains "$extracted/.vite/build/main-test.js" 'codexLinuxShowHotkeyWindow'
    assert_contains "$extracted/.vite/build/main-test.js" 'codexLinuxGetHotkeyWindowController'
    assert_contains "$extracted/.vite/build/main-test.js" 'ensureHotkeyWindowController'
    assert_contains "$extracted/.vite/build/main-test.js" 'codexLinuxPrewarmHotkeyWindow'
    assert_contains "$extracted/.vite/build/main-test.js" 'codexLinuxStartLaunchActionSocket'
    assert_contains "$extracted/.vite/build/main-test.js" 'CODEX_DESKTOP_LAUNCH_ACTION_SOCKET'
    assert_contains "$extracted/.vite/build/main-test.js" 'e.openHome'
    assert_contains "$extracted/.vite/build/main-test.js" 'e.prewarm'
    assert_contains "$extracted/.vite/build/main-test.js" 'type:`new-quick-chat`'

    node - "$extracted/.vite/build/main-test.js" <<'NODE'
const fs = require("fs");
const vm = require("vm");

const source = fs.readFileSync(process.argv[2], "utf8");
let state = makeState();

function makeState(settings = {}) {
  const next = {
    appHandlers: Object.create(null),
    offHandlers: Object.create(null),
    disposables: [],
    initialHandler: null,
    lockCount: 0,
    quitCount: 0,
    globalStateGetKeys: [],
    linuxSettings: {
      promptChatEnabled: true,
      warmStartEnabled: true,
      trayEnabled: true,
      ...settings,
    },
  };

  next.globalState = {
    get(key) {
      next.globalStateGetKeys.push(String(key));
      return linuxSettingForKey(next, key);
    },
  };

  return next;
}

function linuxSettingsAtom(settings) {
  return {
    "settings.keybinds.promptChatEnabled": settings.promptChatEnabled,
    "settings.keybinds.promptChat": settings.promptChatEnabled,
    "settings.keybinds.hotkeyWindowEnabled": settings.promptChatEnabled,
    "settings.keybinds.warmStartEnabled": settings.warmStartEnabled,
    "settings.keybinds.warmStart": settings.warmStartEnabled,
    "settings.keybinds.launchActionSocketEnabled": settings.warmStartEnabled,
    "settings.keybinds.trayEnabled": settings.trayEnabled,
    "settings.keybinds.tray": settings.trayEnabled,
    "settings.linux.promptChatEnabled": settings.promptChatEnabled,
    "settings.linux.warmStartEnabled": settings.warmStartEnabled,
    "settings.linux.trayEnabled": settings.trayEnabled,
  };
}

function linuxSettingForKey(next, key) {
  const keyText = String(key).toLowerCase();
  const settings = next.linuxSettings;

  if (keyText.includes("persisted") || keyText === "electron-persisted-atom-state") {
    return linuxSettingsAtom(settings);
  }

  if (keyText.includes("keybind") && !keyText.includes("prompt") && !keyText.includes("hotkey") && !keyText.includes("warm") && !keyText.includes("launch") && !keyText.includes("socket") && !keyText.includes("tray")) {
    return {
      promptChatEnabled: settings.promptChatEnabled,
      hotkeyWindowEnabled: settings.promptChatEnabled,
      warmStartEnabled: settings.warmStartEnabled,
      launchActionSocketEnabled: settings.warmStartEnabled,
      trayEnabled: settings.trayEnabled,
    };
  }

  if (keyText.includes("prompt") || keyText.includes("hotkey")) {
    return settings.promptChatEnabled;
  }

  if (keyText.includes("warm") || keyText.includes("socket") || keyText.includes("launch")) {
    return settings.warmStartEnabled;
  }

  if (keyText.includes("tray")) {
    return settings.trayEnabled;
  }

  return null;
}

function makeWindow(id) {
  return {
    id,
    isMinimized() {
      state.windowCalls.push(`${id}:isMinimized`);
      return false;
    },
    isVisible() {
      state.windowCalls.push(`${id}:isVisible`);
      return true;
    },
    restore() {
      state.windowCalls.push(`${id}:restore`);
    },
    show() {
      state.windowCalls.push(`${id}:show`);
    },
    focus() {
      state.windowCalls.push(`${id}:focus`);
    },
  };
}

function resetCalls() {
  const existingCreateServerCalls = state.createServerCalls ?? 0;
  const existingSocketConnectionHandler = state.socketConnectionHandler ?? null;
  const existingSocketListenCalls = state.socketListenCalls ?? [];
  const existingSocketServerHandlers = state.socketServerHandlers ?? Object.create(null);
  state.queueArgs = [];
  state.navigateCalls = [];
  state.messages = [];
  state.hideCalls = 0;
  state.showCalls = 0;
  state.controllerShowCalls = 0;
  state.hotkeyWindowShowResult = true;
  state.openHomeCalls = 0;
  state.hotkeyWindowOpenHomeResult = undefined;
  state.prewarmCalls = 0;
  state.prewarmThrows = false;
  state.ensureHotkeyWindowControllerCalls = 0;
  state.hotkeyWindowController = {
    show() {
      state.controllerShowCalls++;
      return state.hotkeyWindowShowResult;
    },
    openHome() {
      state.openHomeCalls++;
      return state.hotkeyWindowOpenHomeResult;
    },
    prewarm() {
      state.prewarmCalls++;
      if (state.prewarmThrows) {
        throw new Error("prewarm failed");
      }
    },
  };
  state.ensureHostWindowCalls = [];
  state.createFreshLocalWindowCalls = [];
  state.focusCalls = [];
  state.windowCalls = [];
  state.errors = [];
  state.ieCalls = 0;
  state.traceCalls = [];
  state.flushPendingDeepLinksCalls = 0;
  state.trayStartupCalls = 0;
  state.primaryWindow = null;
  state.createdWindow = makeWindow("created");
  state.dirnameCalls = [];
  state.mkdirSyncCalls = [];
  state.rmSyncCalls = [];
  state.createServerCalls = existingCreateServerCalls;
  state.socketConnectionHandler = existingSocketConnectionHandler;
  state.socketListenCalls = existingSocketListenCalls;
  state.socketCloseCalls = 0;
  state.socketServer = {
    listen(path) {
      state.socketListenCalls.push(path);
    },
    close() {
      state.socketCloseCalls += 1;
    },
    on(event, handler) {
      state.socketServerHandlers[event] = handler;
      return this;
    },
  };
  state.socketServerHandlers = existingSocketServerHandlers;
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

async function flushAsyncHandlers() {
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
}

async function boot(settings = {}, env = { CODEX_DESKTOP_LAUNCH_ACTION_SOCKET: "/tmp/codex-smoke.sock" }) {
  state = makeState(settings);
  resetCalls();
  state.primary = makeWindow("primary");

  const context = {
    console,
    process: { platform: "linux", env },
    require(moduleName) {
      if (moduleName === "node:path") {
        return {
          dirname(path) {
            state.dirnameCalls.push(path);
            return "/tmp";
          },
          join(...parts) {
            return parts.join("/").replace(/\/+/g, "/");
          },
        };
      }
      if (moduleName === "node:fs") {
        return {
          mkdirSync(...args) {
            state.mkdirSyncCalls.push(args);
          },
          rmSync(...args) {
            state.rmSyncCalls.push(args);
          },
        };
      }
      if (moduleName === "node:net") {
        return {
          createServer(handler) {
            state.createServerCalls++;
            state.socketConnectionHandler = handler;
            return state.socketServer;
          },
        };
      }
      throw new Error(`Unexpected require(${moduleName})`);
    },
    __codexSmoke: state,
  };
  context.globalThis = context;

  vm.runInNewContext(`${source}\nglobalThis.__codexSmokeRun = uT;`, context, {
    filename: "main-test.js",
  });

  await context.__codexSmokeRun();
  return context;
}

(async () => {
  await boot();
  assert(typeof state.initialHandler === "function", "setSecondInstanceArgsHandler callback was not registered");
  assert(state.createServerCalls === 1, "warm-start launch action socket server was not created");
  assert(state.socketListenCalls.length === 1 && state.socketListenCalls[0] === "/tmp/codex-smoke.sock", "warm-start launch action socket did not listen on the configured path");
  assert(typeof state.socketConnectionHandler === "function", "warm-start launch action socket connection handler was not registered");
  assert(state.mkdirSyncCalls.length === 1, "warm-start launch action socket should create its parent runtime directory");
  assert(state.rmSyncCalls.length === 1 && state.rmSyncCalls[0][0] === "/tmp/codex-smoke.sock", "warm-start launch action socket should remove a stale socket before listening");
  assert(state.prewarmCalls === 1, "startup should prewarm the compact hotkey prompt window");
  assert(state.ensureHotkeyWindowControllerCalls === 1, "startup prewarm should use the real hotkey window controller");
  assert(state.flushPendingDeepLinksCalls === 1, "startup should still flush pending deeplinks after prewarm");
  assert(state.trayStartupCalls === 1, "startup should initialize the Linux tray when the tray gate is enabled");

  async function runSecondInstance(args) {
    state.initialHandler(args);
    await flushAsyncHandlers();
  }

  async function runInitialArgs(args) {
    state.initialHandler(args);
    await flushAsyncHandlers();
  }

  function makeSocket() {
    const handlers = Object.create(null);
    return {
      destroyed: false,
      encoding: null,
      outputs: [],
      setEncoding(encoding) {
        this.encoding = encoding;
      },
      on(event, handler) {
        handlers[event] = handler;
        return this;
      },
      emit(event, payload) {
        if (handlers[event]) {
          handlers[event](payload);
        }
      },
      end(output) {
        this.outputs.push(output);
      },
      destroy() {
        this.destroyed = true;
      },
    };
  }

  async function runSocketArgs(args) {
    const socket = makeSocket();
    state.socketConnectionHandler(socket);
    socket.emit("data", `${JSON.stringify({ argv: args })}\n`);
    await flushAsyncHandlers();
    return socket;
  }

  resetCalls();
  state.primaryWindow = state.primary;
  await runSecondInstance(["codex-desktop", "--new-chat"]);
  assert(state.queueArgs.length === 0, "--new-chat without a deeplink should not be consumed by deeplink routing");
  assert(state.createFreshLocalWindowCalls.length === 0, "--new-chat should reuse the warm primary window");
  assert(state.focusCalls.length === 1 && state.focusCalls[0] === "primary", "--new-chat should focus the warm primary window");
  assert(state.navigateCalls.length === 1 && state.navigateCalls[0].path === "/", "--new-chat should navigate the warm primary window to /");
  assert(state.messages.length === 0, "--new-chat should not send a quick-chat message");

  resetCalls();
  state.primaryWindow = state.primary;
  await runSecondInstance(["codex-desktop", "--quick-chat"]);
  assert(state.queueArgs.length === 0, "--quick-chat without a deeplink should not be consumed by deeplink routing");
  assert(state.createFreshLocalWindowCalls.length === 0, "--quick-chat should reuse the warm primary window");
  assert(state.focusCalls.length === 1 && state.focusCalls[0] === "primary", "--quick-chat should focus the warm primary window");
  assert(state.messages.length === 1 && state.messages[0].windowId === "primary" && state.messages[0].message.type === "new-quick-chat", "--quick-chat should send new-quick-chat to the warm primary window");
  assert(state.navigateCalls.length === 0, "--quick-chat should not navigate by route");

  resetCalls();
  state.primaryWindow = state.primary;
  await runSecondInstance(["codex-desktop", "--prompt-chat"]);
  assert(state.queueArgs.length === 0, "--prompt-chat without a deeplink should not be consumed by deeplink routing");
  assert(state.openHomeCalls === 1, "--prompt-chat should open the compact hotkey prompt on the new-chat home surface");
  assert(state.ensureHotkeyWindowControllerCalls === 1, "--prompt-chat should use the real hotkey window controller");
  assert(state.showCalls === 0, "--prompt-chat should not reopen the last hotkey surface");
  assert(state.controllerShowCalls === 0, "--prompt-chat should not call the controller show fallback");
  assert(state.ensureHostWindowCalls.length === 0, "--prompt-chat should not open the main window when the hotkey prompt shows");
  assert(state.hideCalls === 0, "--prompt-chat should not hide the hotkey window before showing it");
  assert(state.focusCalls.length === 0, "--prompt-chat should not focus the main window");

  resetCalls();
  state.primaryWindow = state.primary;
  await runSecondInstance(["codex-desktop", "--hotkey-window"]);
  assert(state.openHomeCalls === 1, "--hotkey-window should open the compact hotkey prompt on the new-chat home surface");
  assert(state.ensureHotkeyWindowControllerCalls === 1, "--hotkey-window should use the real hotkey window controller");
  assert(state.ensureHostWindowCalls.length === 0, "--hotkey-window should not open the main window when the compact prompt shows");

  resetCalls();
  state.primaryWindow = state.primary;
  let socket = await runSocketArgs(["codex-desktop", "--prompt-chat"]);
  assert(socket.outputs[0] === "ok\n", "warm-start socket should acknowledge handled prompt args");
  assert(state.openHomeCalls === 1, "warm-start socket should open the compact prompt on the new-chat home surface");
  assert(state.ensureHotkeyWindowControllerCalls === 1, "warm-start socket prompt should use the real hotkey window controller");
  assert(state.focusCalls.length === 0, "warm-start socket prompt should not focus the main window");

  resetCalls();
  state.primaryWindow = state.primary;
  socket = await runSocketArgs(["codex://thread/abc", "--prompt-chat"]);
  assert(socket.outputs[0] === "ok\n", "warm-start socket should acknowledge deeplink args");
  assert(state.queueArgs.length === 1, "warm-start socket should check deeplinks before prompt flags");
  assert(state.openHomeCalls === 0, "warm-start socket should not open the prompt when a deeplink is present");

  resetCalls();
  socket = await runSocketArgs(["codex-desktop"]);
  assert(socket.outputs[0] === "ok\n", "warm-start socket should acknowledge fallback focus args");
  assert(state.ieCalls === 1, "warm-start socket should use the focus fallback for args without launch flags");

  resetCalls();
  state.primaryWindow = state.primary;
  await runSecondInstance(["codex://thread/abc", "--quick-chat"]);
  assert(state.queueArgs.length === 1, "deeplink+flag should check deeplinks");
  assert(state.messages.length === 0, "deeplink+flag should not open quick chat");
  assert(state.navigateCalls.length === 0, "deeplink+flag should not navigate to /");
  assert(state.ieCalls === 0, "deeplink+flag should not fall back to focus");

  resetCalls();
  state.primaryWindow = state.primary;
  await runSecondInstance(["codex-browser-sidebar://open", "--quick-chat"]);
  assert(state.queueArgs.length === 1, "browser-sidebar deeplink+flag should check deeplinks");
  assert(state.messages.length === 0, "browser-sidebar deeplink+flag should not open quick chat");
  assert(state.navigateCalls.length === 0, "browser-sidebar deeplink+flag should not navigate to /");
  assert(state.ieCalls === 0, "browser-sidebar deeplink+flag should not fall back to focus");

  resetCalls();
  state.primaryWindow = state.primary;
  await runSecondInstance(["codex://thread/abc", "--prompt-chat"]);
  assert(state.queueArgs.length === 1, "deeplink+prompt flag should check deeplinks first");
  assert(state.openHomeCalls === 0, "deeplink+prompt flag should not open the compact prompt");
  assert(state.showCalls === 0, "deeplink+prompt flag should not show the compact prompt");
  assert(state.ensureHostWindowCalls.length === 0, "deeplink+prompt flag should not fall back to the host window");

  resetCalls();
  await runSecondInstance(["codex-desktop"]);
  assert(state.queueArgs.length === 0, "no-flag args without a deeplink should not be consumed by deeplink routing");
  assert(state.ieCalls === 1, "no-flag args should use the focus fallback");
  assert(state.createFreshLocalWindowCalls.length === 1 && state.createFreshLocalWindowCalls[0] === "/", "fallback should create the default window");

  resetCalls();
  state.primaryWindow = state.primary;
  await runInitialArgs(["codex-desktop", "--quick-chat"]);
  assert(state.createFreshLocalWindowCalls.length === 0, "initial argv handler should reuse an existing primary window");
  assert(state.messages.length === 1 && state.messages[0].windowId === "primary" && state.messages[0].message.type === "new-quick-chat", "initial argv handler should open quick chat in the existing primary window");

  resetCalls();
  state.primaryWindow = state.primary;
  await runInitialArgs(["codex-desktop", "--prompt-chat"]);
  assert(state.openHomeCalls === 1, "initial argv handler should open the compact prompt on the new-chat home surface");
  assert(state.ensureHotkeyWindowControllerCalls === 1, "initial argv handler should use the real hotkey window controller");
  assert(state.showCalls === 0, "initial argv handler should not reopen the last hotkey surface");
  assert(state.ensureHostWindowCalls.length === 0, "initial argv handler should not open the main window when the compact prompt shows");

  resetCalls();
  await runInitialArgs(["codex-desktop", "--quick-chat"]);
  assert(state.createFreshLocalWindowCalls.length === 1 && state.createFreshLocalWindowCalls[0] === "/", "initial argv handler should create a window when no primary exists");
  assert(state.messages.length === 1 && state.messages[0].windowId === "created" && state.messages[0].message.type === "new-quick-chat", "initial argv handler should open quick chat in the created window when no primary exists");

  resetCalls();
  state.primaryWindow = state.primary;
  await runInitialArgs(["codex-desktop", "--new-chat"]);
  assert(state.createFreshLocalWindowCalls.length === 0, "initial --new-chat should reuse a warm primary window");
  assert(state.navigateCalls.length === 1 && state.navigateCalls[0].path === "/", "initial --new-chat should navigate an existing window to /");
  assert(state.focusCalls.length === 1 && state.focusCalls[0] === "primary", "initial --new-chat should focus the main window");

  await boot({ promptChatEnabled: false });
  resetCalls();
  state.primaryWindow = state.primary;
  await runSecondInstance(["codex://thread/abc", "--prompt-chat"]);
  assert(state.queueArgs.length === 1, "deeplink priority should still win when the prompt-chat gate is disabled");
  assert(state.openHomeCalls === 0, "disabled prompt-chat gate should not open the compact prompt for deeplink args");
  assert(state.ieCalls === 0, "deeplink args should not fall back to main-window focus when the prompt-chat gate is disabled");

  resetCalls();
  state.primaryWindow = state.primary;
  await runSecondInstance(["codex-desktop", "--prompt-chat"]);
  assert(state.queueArgs.length === 0, "disabled prompt-chat args without a deeplink should not be consumed by deeplink routing");
  assert(state.openHomeCalls === 0, "disabled prompt-chat gate should not open the compact prompt");
  assert(state.ensureHotkeyWindowControllerCalls === 0, "disabled prompt-chat gate should not create the hotkey window controller");
  assert(state.ieCalls === 1, "disabled prompt-chat gate should fall back to main-window focus");
  assert(state.focusCalls.length === 1 && state.focusCalls[0] === "primary", "disabled prompt-chat fallback should focus the warm primary window");

  resetCalls();
  state.primaryWindow = state.primary;
  await runSecondInstance(["codex-desktop", "--hotkey-window"]);
  assert(state.openHomeCalls === 0, "disabled prompt-chat gate should also block --hotkey-window prompt opening");
  assert(state.ensureHotkeyWindowControllerCalls === 0, "disabled prompt-chat gate should not create a controller for --hotkey-window");
  assert(state.ieCalls === 1, "disabled --hotkey-window should fall back to main-window focus");

  await boot({ warmStartEnabled: false }, { CODEX_DESKTOP_LAUNCH_ACTION_SOCKET: "/tmp/codex-disabled.sock" });
  assert(state.createServerCalls === 0, "disabled warm-start gate should not create the launch-action socket server");
  assert(state.socketListenCalls.length === 0, "disabled warm-start gate should not listen on the launch-action socket");
  assert(state.socketConnectionHandler == null, "disabled warm-start gate should not register a socket connection handler");

  await boot({ trayEnabled: false });
  assert(state.trayStartupCalls === 0, "disabled tray gate should not start the Linux tray during startup");
})().catch((error) => {
  console.error(error.stack || error);
  process.exit(1);
});
NODE

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_occurrence_count "$extracted/.vite/build/main-test.js" '!n.app.requestSingleInstanceLock()' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxQuitInProgress=!1' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxIsQuitInProgress=()=>codexLinuxQuitInProgress===!0' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxHandleLaunchActionArgs=' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxHandleLaunchActionArgs=async e=>(typeof codexLinuxIsQuitInProgress===`function`&&codexLinuxIsQuitInProgress())?!0:' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxHandleLaunchActionArgsFallback=(e,t)=>{if(typeof codexLinuxIsQuitInProgress===`function`&&codexLinuxIsQuitInProgress())return;' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'e.includes(`--new-chat`)' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'e.includes(`--quick-chat`)' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'e.includes(`--prompt-chat`)' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'e.includes(`--hotkey-window`)' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxShowHotkeyWindow=' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxGetHotkeyWindowController=' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxPrewarmHotkeyWindow=' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxStartLaunchActionSocket=' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxOpenQuickChat=' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxPrewarmHotkeyWindow()' '1'
}

test_linux_computer_use_gate_patch_smoke() {
    info "Checking Linux Computer Use plugin gate patch behavior"
    local workspace="$TMP_DIR/computer-use-gate-patch"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"
    local bundle_body

    mkdir -p "$workspace"
    bundle_body="$(cat <<'JS'
let n={app:{whenReady(){},quit(){},requestSingleInstanceLock(){},on(){},off(){}}};
let Qt=`openai-bundled`,$t=`browser-use`,en=`chrome-internal`,tn=`computer-use`,nn=`latex-tectonic`;
function cl(e){if(!(e.platform!==`darwin`||!e.marketplacePluginNames.includes(`computer-use`)))return e.desktopFeatureAvailability.computerUseNodeRepl?`node-repl`:`legacy-mcp`}
var $n=[{forceReload:!0,installWhenMissing:!0,name:$t,isEnabled:({features:e})=>e.browserAgentAvailable,migrate:cn},{name:en,isEnabled:({buildFlavor:e})=>rn(e)},{name:tn,isEnabled:cl,migrate:wn},{name:nn,isEnabled:()=>!0}];
JS
)"
    make_fake_extracted_asar "$extracted" "$bundle_body"

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$extracted/.vite/build/main-test.js" 'if(!((e.platform!==`darwin`&&e.platform!==`linux`)||!e.marketplacePluginNames.includes(`computer-use`))'
    assert_contains "$extracted/.vite/build/main-test.js" 'return e.platform===`darwin`&&e.desktopFeatureAvailability.computerUseNodeRepl?`node-repl`:`legacy-mcp`'
    assert_not_contains "$extracted/.vite/build/main-test.js" 'if(!(e.platform!==`darwin`||!e.marketplacePluginNames.includes(`computer-use`)))return e.desktopFeatureAvailability.computerUseNodeRepl?`node-repl`:`legacy-mcp`'

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'return e.platform===`darwin`&&e.desktopFeatureAvailability.computerUseNodeRepl?`node-repl`:`legacy-mcp`' '1'
}

test_linux_computer_use_ui_opt_in_smoke() {
    info "Checking Linux Computer Use UI opt-in gating"
    local workspace="$TMP_DIR/computer-use-ui-opt-in"
    local extracted="$workspace/extracted"
    local fake_home="$workspace/home"
    local output_log="$workspace/output.log"
    local main_bundle="$extracted/.vite/build/main-test.js"
    local renderer_asset="$extracted/webview/assets/computer-use-settings-renderer-test.js"
    local current_renderer_asset="$extracted/webview/assets/computer-use-settings-current-test.js"
    local install_flow_asset="$extracted/webview/assets/app-initial~app-main~worktree-init-v2-page~remote-conversation-page~pull-requests-page~plug~test.js"
    local native_apps_asset="$extracted/webview/assets/computer-use-settings-native-apps-test.js"
    local bundle_body
    local renderer_body
    local current_renderer_body
    local install_flow_body
    local native_apps_body

    mkdir -p "$workspace" "$fake_home/.config/codex-desktop"

    bundle_body="$(cat <<'JS'
let n={app:{whenReady(){},quit(){},requestSingleInstanceLock(){},on(){},off(){}}};
let cp=require(`node:child_process`),fs=require(`node:fs`),p=require(`node:path`),os=require(`node:os`);
let Qt=`openai-bundled`,$t=`browser-use`,en=`chrome-internal`,tn=`computer-use`,nn=`latex-tectonic`;
function cl(e){if(!(e.platform!==`darwin`||!e.marketplacePluginNames.includes(`computer-use`)))return e.desktopFeatureAvailability.computerUseNodeRepl?`node-repl`:`legacy-mcp`}
var $n=[{name:tn,isEnabled:cl,migrate:wn}];
function me(e,{env:t=process.env,platform:n=process.platform}={}){return n!==`win32`||t.CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE!==`1`?e:{...e,computerUse:!0,computerUseNodeRepl:!0}}
var h={handlers:{"native-desktop-apps":async()=>({apps:[]})}};
JS
)"
    renderer_body="$(cat <<'JS'
function hae(e){return e===`macOS`||e===`windows`}
function RS(e){let t=(0,q.c)(8),{enabled:n,hostId:r,isHostLocal:i}=e,a=n===void 0?!0:n,o=r===void 0?R:r,s=Kn(),{isLoading:c,platform:l}=Hr(),u=Vn(`1506311413`),d;t[0]===o?d=t[1]:(d={featureName:`computer_use`,hostId:o},t[0]=o,t[1]=d);let f=LS(d),p;t[2]===l?p=t[3]:(p=hae(l),t[2]=l,t[3]=p);let m=a&&i&&s===`electron`&&u&&(c||p),h=m&&!c&&f.enabled&&!f.isLoading,g=m&&f.isLoading,_=m&&(c||f.isLoading),v;return v}
JS
)"
    current_renderer_body="$(cat <<'JS'
function b(e){return e===`macOS`||e===`windows`}
function x(e){let t=(0,_.c)(16),{enabled:n,hostId:r}=e,i=n===void 0?!0:n,{isLoading:a,platform:o}=m(),s=u(`1506311413`),c;t[0]===r?c=t[1]:(c={featureName:`computer_use`,hostId:r},t[0]=r,t[1]=c);let l=v(c),d=o===`windows`&&!a,f=i&&d,p;t[2]===f?p=t[3]:(p={enabled:f},t[2]=f,t[3]=p);let h=S(p),g=l.isLoading||d&&h.isLoading,y=l.enabled&&(!d||h.enabled),x;t[4]!==y||t[5]!==i||t[6]!==g||t[7]!==s||t[8]!==a||t[9]!==o?(x=w({areRequiredFeaturesEnabled:y,enabled:i,isAnyFeatureLoading:g,isComputerUseGateEnabled:s,isHostCompatiblePlatform:b(o),isPlatformLoading:a,windowType:`electron`}),t[4]=y,t[5]=i,t[6]=g,t[7]=s,t[8]=a,t[9]=o,t[10]=x):x=t[10];return x}
JS
)"
    install_flow_body="$(cat <<'JS'
function Rj(e){return e===`macOS`||e===`windows`}
function zj(e){let t=(0,Uj.c)(16),{enabled:n,hostId:r}=e,i=n===void 0?!0:n,{isLoading:a,platform:o}=Xt(),s=cn(`1506311413`),c;t[0]===r?c=t[1]:(c={featureName:`computer_use`,hostId:r},t[0]=r,t[1]=c);let l=Fj(c),u=o===`windows`&&!a,d=i&&u,f;t[2]===d?f=t[3]:(f={enabled:d},t[2]=d,t[3]=f);let p=Bj(f),m=l.isLoading||u&&p.isLoading,h=l.enabled&&(!u||p.enabled),g;t[4]!==h||t[5]!==i||t[6]!==m||t[7]!==s||t[8]!==a||t[9]!==o?(g=Hj({areRequiredFeaturesEnabled:h,enabled:i,isAnyFeatureLoading:m,isComputerUseGateEnabled:s,isHostCompatiblePlatform:Rj(o),isPlatformLoading:a,windowType:`electron`}),t[4]=h,t[5]=i,t[6]=m,t[7]=s,t[8]=a,t[9]=o,t[10]=g):g=t[10];return g}
JS
)"
    native_apps_body="$(cat <<'JS'
function d(e){return e.find(e=>e.plugin.name===`computer-use`)??null}
function C(e){let t=(0,S.c)(9),{enabled:n}=e,{platform:a,isLoading:o}=c(),s=n&&(a===`macOS`||a===`windows`),l;t[0]===Symbol.for(`react.memo_cache_sentinel`)?(l={order:`usage`},t[0]=l):l=t[0];let u;t[1]===s?u=t[2]:(u={params:l,queryConfig:{enabled:s,staleTime:i.FIVE_MINUTES,refetchOnWindowFocus:!1}},t[1]=s,t[2]=u);let d=r(`native-desktop-apps`,u);return d}
JS
)"

    make_fake_extracted_asar "$extracted" "$bundle_body"
    printf '%s\n' "$renderer_body" > "$renderer_asset"
    printf '%s\n' "$current_renderer_body" > "$current_renderer_asset"
    printf '%s\n' "$install_flow_body" > "$install_flow_asset"
    printf '%s\n' "$native_apps_body" > "$native_apps_asset"

    # Branch 1: no env var, no settings.json — only the plugin manifest gate runs.
    HOME="$fake_home" XDG_CONFIG_HOME= unset_env_value="" \
        env -u CODEX_LINUX_ENABLE_COMPUTER_USE_UI -u CODEX_LINUX_APP_ID -u CODEX_APP_ID -u CODEX_LINUX_SETTINGS_FILE \
        HOME="$fake_home" XDG_CONFIG_HOME="$fake_home/.config" \
        node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$main_bundle" 'if(!((e.platform!==`darwin`&&e.platform!==`linux`)||!e.marketplacePluginNames.includes(`computer-use`))'
    assert_contains "$main_bundle" 'return e.platform===`darwin`&&e.desktopFeatureAvailability.computerUseNodeRepl?`node-repl`:`legacy-mcp`'
    assert_not_contains "$main_bundle" 'if(!(e.platform!==`darwin`||!e.marketplacePluginNames.includes(`computer-use`)))return e.desktopFeatureAvailability.computerUseNodeRepl?`node-repl`:`legacy-mcp`'
    assert_not_contains "$main_bundle" 'return n===`linux`?{...e,computerUse:!0,computerUseNodeRepl:!0}'
    assert_not_contains "$main_bundle" 'codexLinuxNativeDesktopApps'
    assert_not_contains "$renderer_asset" 'function hae(e){return e===`macOS`||e===`windows`||e===`linux`}'
    assert_not_contains "$current_renderer_asset" 'areRequiredFeaturesEnabled:o===`linux`||y'
    assert_not_contains "$native_apps_asset" 'a===`macOS`||a===`windows`||a===`linux`'
    assert_not_contains "$install_flow_asset" 'areRequiredFeaturesEnabled:o===`linux`||h'

    # Branch 2: env var opts in — all Computer Use UI patches apply.
    rm "$main_bundle" "$renderer_asset" "$current_renderer_asset" "$install_flow_asset" "$native_apps_asset"
    printf '%s\n' "$bundle_body" > "$main_bundle"
    printf '%s\n' "$renderer_body" > "$renderer_asset"
    printf '%s\n' "$current_renderer_body" > "$current_renderer_asset"
    printf '%s\n' "$install_flow_body" > "$install_flow_asset"
    printf '%s\n' "$native_apps_body" > "$native_apps_asset"

    env -u CODEX_LINUX_APP_ID -u CODEX_APP_ID -u CODEX_LINUX_SETTINGS_FILE \
        CODEX_LINUX_ENABLE_COMPUTER_USE_UI=1 HOME="$fake_home" XDG_CONFIG_HOME="$fake_home/.config" \
        node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$main_bundle" 'if(!((e.platform!==`darwin`&&e.platform!==`linux`)||!e.marketplacePluginNames.includes(`computer-use`))'
    assert_contains "$main_bundle" 'return e.platform===`darwin`&&e.desktopFeatureAvailability.computerUseNodeRepl?`node-repl`:`legacy-mcp`'
    assert_contains "$main_bundle" 'return n===`linux`?{...e,computerUse:!0,computerUseNodeRepl:!0}'
    assert_contains "$main_bundle" 'codexLinuxNativeDesktopApps'
    assert_contains "$main_bundle" '"computer-use-native-desktop-app-icon":async(e)=>process.platform===`linux`?codexLinuxNativeDesktopAppIcon(e):{iconSmall:``}'
    assert_contains "$renderer_asset" 'function hae(e){return e===`macOS`||e===`windows`||e===`linux`}'
    assert_contains "$current_renderer_asset" 'areRequiredFeaturesEnabled:o===`linux`||y'
    assert_contains "$current_renderer_asset" 'isAnyFeatureLoading:o===`linux`?!1:g'
    assert_contains "$native_apps_asset" 'a===`macOS`||a===`windows`||a===`linux`'
    assert_contains "$install_flow_asset" 'areRequiredFeaturesEnabled:o===`linux`||h'
    assert_contains "$install_flow_asset" 'isAnyFeatureLoading:o===`linux`?!1:m'

    # Branch 3: settings.json flag opts in even without env var.
    rm "$main_bundle" "$renderer_asset" "$current_renderer_asset" "$install_flow_asset" "$native_apps_asset"
    printf '%s\n' "$bundle_body" > "$main_bundle"
    printf '%s\n' "$renderer_body" > "$renderer_asset"
    printf '%s\n' "$current_renderer_body" > "$current_renderer_asset"
    printf '%s\n' "$install_flow_body" > "$install_flow_asset"
    printf '%s\n' "$native_apps_body" > "$native_apps_asset"
    printf '%s\n' '{"codex-linux-computer-use-ui-enabled": true}' > "$fake_home/.config/codex-desktop/settings.json"

    env -u CODEX_LINUX_ENABLE_COMPUTER_USE_UI -u CODEX_LINUX_APP_ID -u CODEX_APP_ID -u CODEX_LINUX_SETTINGS_FILE \
        HOME="$fake_home" XDG_CONFIG_HOME="$fake_home/.config" \
        node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$main_bundle" 'return n===`linux`?{...e,computerUse:!0,computerUseNodeRepl:!0}'
    assert_contains "$main_bundle" 'codexLinuxNativeDesktopApps'
    assert_contains "$renderer_asset" 'function hae(e){return e===`macOS`||e===`windows`||e===`linux`}'
    assert_contains "$current_renderer_asset" 'areRequiredFeaturesEnabled:o===`linux`||y'
    assert_contains "$native_apps_asset" 'a===`macOS`||a===`windows`||a===`linux`'
    assert_contains "$install_flow_asset" 'areRequiredFeaturesEnabled:o===`linux`||h'
}

test_linux_file_manager_patch_fails_soft() {
    info "Checking Linux file manager patch fallback"
    local workspace="$TMP_DIR/file-manager-patch-fallback"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"

    mkdir -p "$workspace"
    make_fake_extracted_asar "$extracted" 'let D={removeMenu(){},setMenuBarVisibility(){},setIcon(){},once(){}};let t={join(){}};...process.platform===`win32`?{autoHideMenuBar:!0}:{},process.platform===`win32`&&D.removeMenu(),foo)}),D.once(`ready-to-show`,()=>{var brokenFileManager=Mi({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`});var Ua=Mi({id:`systemDefault`,label:`System Default App`,icon:`apps/file-explorer.png`,kind:`systemDefault`,hidden:!0,darwin:{icon:`apps/finder.png`,detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},win32:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},linux:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)}});async function Wa(e){return e}'

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$output_log" 'Failed to apply Linux File Manager Patch'
}

test_patcher_enforce_critical_gate() {
    info "Checking --enforce-critical patcher gate"
    local workspace="$TMP_DIR/enforce-critical-gate"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"
    local report_json="$workspace/reports/patch-report.json"
    local status=0

    mkdir -p "$workspace"
    # Minimal fixture: most required patches cannot match, so enforcement must fail.
    make_fake_extracted_asar "$extracted" 'let n=require(`electron`);process.platform===`win32`&&D.removeMenu(),'

    # Bare invocation stays fail-soft (exit 0) — build scripts opt into enforcement.
    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1 \
        || fail "expected bare patcher invocation to stay fail-soft on this fixture"

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" --enforce-critical --report-json "$report_json" "$extracted" >"$output_log" 2>&1 || status=$?
    [ "$status" -ne 0 ] || fail "expected --enforce-critical to exit non-zero on critical patch failures"
    assert_contains "$output_log" 'Critical patch failures'
    [ -f "$report_json" ] || fail "expected patch report to be written despite enforcement failure"
}

test_webview_probe_equivalence() {
    info "Checking webview probe behavioral equivalence (bash + curl vs python3 reference)"
    # The harness extracts webview_port_is_open and verify_webview_origin from
    # the live launcher template, runs them against a controlled localhost
    # python3 http.server fixture, and asserts the verdicts match the
    # python3 reference implementation across every input class (open/closed
    # port, marker-OK, 404, wrong title, missing loader, dead port) plus
    # confirms the watchdog cap still fires within its 150-500 ms window.
    bash "$REPO_DIR/tests/webview_probe_equivalence.sh" \
        || fail "webview probe equivalence harness reported a verdict mismatch or unbounded watchdog"
}

test_user_local_prepare_build_repo_overlays_committed_local_changes() {
    info "Checking user-local managed checkout preserves committed local overlay changes"
    local workspace="$TMP_DIR/user-local-overlay"
    local origin_repo="$workspace/origin.git"
    local source_repo="$workspace/source"
    local upstream_repo="$workspace/upstream"
    local managed_repo="$workspace/xdg-data/codex-desktop-linux/managed-repo"
    local install_env="$workspace/install.env"

    mkdir -p "$workspace"
    git init --bare --initial-branch=main "$origin_repo" >/dev/null
    git clone "$origin_repo" "$source_repo" >/dev/null 2>&1
    git -C "$source_repo" config user.name "Smoke Test"
    git -C "$source_repo" config user.email "smoke@example.com"

    cat > "$source_repo/tracked.txt" <<'EOF'
base
EOF
    cat > "$source_repo/upstream.txt" <<'EOF'
upstream-base
EOF
    git -C "$source_repo" add tracked.txt upstream.txt
    git -C "$source_repo" commit -m "base" >/dev/null
    git -C "$source_repo" push -u origin main >/dev/null
    git -C "$source_repo" remote set-head origin -a >/dev/null 2>&1 || true

    cat > "$source_repo/tracked.txt" <<'EOF'
local-overlay
EOF
    git -C "$source_repo" commit -am "local overlay" >/dev/null

    git clone "$origin_repo" "$upstream_repo" >/dev/null 2>&1
    git -C "$upstream_repo" config user.name "Smoke Test"
    git -C "$upstream_repo" config user.email "smoke@example.com"
    cat > "$upstream_repo/upstream.txt" <<'EOF'
upstream-advanced
EOF
    cat > "$upstream_repo/remote-only.txt" <<'EOF'
remote-only
EOF
    git -C "$upstream_repo" add upstream.txt remote-only.txt
    git -C "$upstream_repo" commit -m "upstream advance" >/dev/null
    git -C "$upstream_repo" push origin main >/dev/null

    (
        export HOME="$workspace/home"
        export XDG_DATA_HOME="$workspace/xdg-data"
        export XDG_STATE_HOME="$workspace/xdg-state"
        mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

        # shellcheck disable=SC1091
        source "$REPO_DIR/contrib/user-local-install/files/.local/lib/codex-desktop-linux/common.sh"

        INSTALL_CONFIG_FILE="$install_env"
        cat > "$INSTALL_CONFIG_FILE" <<EOF
SOURCE_REPO_DIR=$(printf '%q' "$source_repo")
MANAGED_REPO_DIR=$(printf '%q' "$managed_repo")
REPO_ORIGIN_URL=$(printf '%q' "$origin_repo")
REPO_DEFAULT_BRANCH=$(printf '%q' "main")
OPT_ROOT=$(printf '%q' "$workspace/opt")
EOF

        prepare_build_repo

        [ "$(git -C "$MANAGED_REPO_DIR" rev-parse HEAD)" = "$(git -C "$upstream_repo" rev-parse HEAD)" ] \
            || fail "Expected managed checkout to reset to latest upstream commit"
        [ "$(cat "$MANAGED_REPO_DIR/tracked.txt")" = "local-overlay" ] \
            || fail "Expected committed local overlay change to be copied into managed checkout"
        [ "$(cat "$MANAGED_REPO_DIR/upstream.txt")" = "upstream-advanced" ] \
            || fail "Expected upstream-only change to remain intact in managed checkout"
        [ "$(cat "$MANAGED_REPO_DIR/remote-only.txt")" = "remote-only" ] \
            || fail "Expected upstream-only added file to remain in managed checkout"
        [ -n "$(source_repo_overlay_signature)" ] \
            || fail "Expected committed local overlay to produce a non-empty overlay signature"
    )
}

test_user_local_prepare_build_repo_detects_default_branch_without_recorded_branch() {
    info "Checking user-local managed checkout detects remote default branch when metadata leaves it empty"
    local workspace="$TMP_DIR/user-local-branch-detect"
    local origin_repo="$workspace/origin.git"
    local source_repo="$workspace/source"
    local unmanaged_source="$workspace/source-without-git"
    local managed_repo="$workspace/xdg-data/codex-desktop-linux/managed-repo"
    local install_env="$workspace/install.env"

    mkdir -p "$workspace" "$unmanaged_source"
    git init --bare --initial-branch=master "$origin_repo" >/dev/null
    git clone "$origin_repo" "$source_repo" >/dev/null 2>&1
    git -C "$source_repo" config user.name "Smoke Test"
    git -C "$source_repo" config user.email "smoke@example.com"
    cat > "$source_repo/branch.txt" <<'EOF'
master-branch
EOF
    git -C "$source_repo" add branch.txt
    git -C "$source_repo" commit -m "base" >/dev/null
    git -C "$source_repo" push -u origin master >/dev/null
    git -C "$source_repo" remote set-head origin -a >/dev/null 2>&1 || true

    (
        export HOME="$workspace/home"
        export XDG_DATA_HOME="$workspace/xdg-data"
        export XDG_STATE_HOME="$workspace/xdg-state"
        mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

        # shellcheck disable=SC1091
        source "$REPO_DIR/contrib/user-local-install/files/.local/lib/codex-desktop-linux/common.sh"

        INSTALL_CONFIG_FILE="$install_env"
        cat > "$INSTALL_CONFIG_FILE" <<EOF
SOURCE_REPO_DIR=$(printf '%q' "$unmanaged_source")
MANAGED_REPO_DIR=$(printf '%q' "$managed_repo")
REPO_ORIGIN_URL=$(printf '%q' "$origin_repo")
REPO_DEFAULT_BRANCH=$(printf '%q' "")
OPT_ROOT=$(printf '%q' "$workspace/opt")
EOF

        prepare_build_repo

        [ "$(repo_default_branch)" = "master" ] \
            || fail "Expected default branch detection to resolve to the remote master branch"
        [ "$(git -C "$MANAGED_REPO_DIR" rev-parse --abbrev-ref HEAD)" = "master" ] \
            || fail "Expected managed checkout to land on the detected master branch"
        [ "$(cat "$MANAGED_REPO_DIR/branch.txt")" = "master-branch" ] \
            || fail "Expected managed checkout contents from the detected master branch"
    )
}

test_user_local_prepare_build_repo_ignores_stale_recorded_default_branch() {
    info "Checking user-local managed checkout ignores a stale recorded default branch"
    local workspace="$TMP_DIR/user-local-stale-branch"
    local origin_repo="$workspace/origin.git"
    local source_repo="$workspace/source"
    local unmanaged_source="$workspace/source-without-git"
    local managed_repo="$workspace/xdg-data/codex-desktop-linux/managed-repo"
    local install_env="$workspace/install.env"

    mkdir -p "$workspace" "$unmanaged_source"
    git init --bare --initial-branch=main "$origin_repo" >/dev/null
    git clone "$origin_repo" "$source_repo" >/dev/null 2>&1
    git -C "$source_repo" config user.name "Smoke Test"
    git -C "$source_repo" config user.email "smoke@example.com"
    cat > "$source_repo/branch.txt" <<'EOF'
main-branch
EOF
    git -C "$source_repo" add branch.txt
    git -C "$source_repo" commit -m "base" >/dev/null
    git -C "$source_repo" push -u origin main >/dev/null
    git -C "$source_repo" remote set-head origin -a >/dev/null 2>&1 || true

    (
        export HOME="$workspace/home"
        export XDG_DATA_HOME="$workspace/xdg-data"
        export XDG_STATE_HOME="$workspace/xdg-state"
        mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

        # shellcheck disable=SC1091
        source "$REPO_DIR/contrib/user-local-install/files/.local/lib/codex-desktop-linux/common.sh"

        INSTALL_CONFIG_FILE="$install_env"
        cat > "$INSTALL_CONFIG_FILE" <<EOF
SOURCE_REPO_DIR=$(printf '%q' "$unmanaged_source")
MANAGED_REPO_DIR=$(printf '%q' "$managed_repo")
REPO_ORIGIN_URL=$(printf '%q' "$origin_repo")
REPO_DEFAULT_BRANCH=$(printf '%q' "master")
OPT_ROOT=$(printf '%q' "$workspace/opt")
EOF

        prepare_build_repo

        [ "$(repo_default_branch)" = "main" ] \
            || fail "Expected stale recorded branch to fall back to the remote default branch"
        [ "$(git -C "$MANAGED_REPO_DIR" rev-parse --abbrev-ref HEAD)" = "main" ] \
            || fail "Expected managed checkout to land on the recovered main branch"
        [ "$(cat "$MANAGED_REPO_DIR/branch.txt")" = "main-branch" ] \
            || fail "Expected managed checkout contents from the recovered main branch"
    )
}

test_user_local_prepare_build_repo_ignores_stale_source_origin_head() {
    info "Checking user-local managed checkout ignores a stale source origin/HEAD ref"
    local workspace="$TMP_DIR/user-local-stale-origin-head"
    local origin_repo="$workspace/origin.git"
    local source_repo="$workspace/source"
    local managed_repo="$workspace/xdg-data/codex-desktop-linux/managed-repo"
    local install_env="$workspace/install.env"

    mkdir -p "$workspace"
    git init --bare --initial-branch=main "$origin_repo" >/dev/null
    git clone "$origin_repo" "$source_repo" >/dev/null 2>&1
    git -C "$source_repo" config user.name "Smoke Test"
    git -C "$source_repo" config user.email "smoke@example.com"
    cat > "$source_repo/branch.txt" <<'EOF'
main-branch
EOF
    git -C "$source_repo" add branch.txt
    git -C "$source_repo" commit -m "base" >/dev/null
    git -C "$source_repo" push -u origin main >/dev/null
    git -C "$source_repo" remote set-head origin -a >/dev/null 2>&1 || true
    git -C "$source_repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

    (
        export HOME="$workspace/home"
        export XDG_DATA_HOME="$workspace/xdg-data"
        export XDG_STATE_HOME="$workspace/xdg-state"
        mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

        # shellcheck disable=SC1091
        source "$REPO_DIR/contrib/user-local-install/files/.local/lib/codex-desktop-linux/common.sh"

        INSTALL_CONFIG_FILE="$install_env"
        cat > "$INSTALL_CONFIG_FILE" <<EOF
SOURCE_REPO_DIR=$(printf '%q' "$source_repo")
MANAGED_REPO_DIR=$(printf '%q' "$managed_repo")
REPO_ORIGIN_URL=$(printf '%q' "$origin_repo")
REPO_DEFAULT_BRANCH=$(printf '%q' "")
OPT_ROOT=$(printf '%q' "$workspace/opt")
EOF

        prepare_build_repo

        [ "$(repo_default_branch)" = "main" ] \
            || fail "Expected stale source origin/HEAD to fall back to the real remote default branch"
        [ "$(git -C "$MANAGED_REPO_DIR" rev-parse --abbrev-ref HEAD)" = "main" ] \
            || fail "Expected managed checkout to land on the recovered main branch"
        [ "$(cat "$MANAGED_REPO_DIR/branch.txt")" = "main-branch" ] \
            || fail "Expected managed checkout contents from the recovered main branch"
    )
}

test_user_local_prepare_build_repo_handles_relative_origin_url() {
    info "Checking user-local managed checkout handles relative origin URLs"
    local workspace="$TMP_DIR/user-local-relative-origin"
    local origin_repo="$workspace/origin.git"
    local source_repo="$workspace/source"
    local moved_source_repo="$workspace/source-moved"
    local updater_repo="$workspace/updater"
    local managed_repo="$workspace/xdg-data/codex-desktop-linux/managed-repo"
    local install_env="$workspace/install.env"

    mkdir -p "$workspace"
    git init --bare --initial-branch=main "$origin_repo" >/dev/null
    git clone "$origin_repo" "$source_repo" >/dev/null 2>&1
    git -C "$source_repo" config user.name "Smoke Test"
    git -C "$source_repo" config user.email "smoke@example.com"
    cat > "$source_repo/relative.txt" <<'EOF'
relative-origin
EOF
    git -C "$source_repo" add relative.txt
    git -C "$source_repo" commit -m "base" >/dev/null
    git -C "$source_repo" push -u origin main >/dev/null
    git -C "$source_repo" remote set-head origin -a >/dev/null 2>&1 || true
    git -C "$source_repo" remote set-url origin ../origin.git

    (
        export HOME="$workspace/home"
        export XDG_DATA_HOME="$workspace/xdg-data"
        export XDG_STATE_HOME="$workspace/xdg-state"
        mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

        # shellcheck disable=SC1091
        source "$REPO_DIR/contrib/user-local-install/files/.local/lib/codex-desktop-linux/common.sh"

        INSTALL_CONFIG_FILE="$install_env"
        cat > "$INSTALL_CONFIG_FILE" <<EOF
SOURCE_REPO_DIR=$(printf '%q' "$source_repo")
MANAGED_REPO_DIR=$(printf '%q' "$managed_repo")
REPO_ORIGIN_URL=$(printf '%q' "../origin.git")
REPO_DEFAULT_BRANCH=$(printf '%q' "main")
OPT_ROOT=$(printf '%q' "$workspace/opt")
EOF

        prepare_build_repo

        [ "$(cat "$MANAGED_REPO_DIR/relative.txt")" = "relative-origin" ] \
            || fail "Expected managed checkout contents from relative origin URL"
        [ "$(git -C "$MANAGED_REPO_DIR" remote get-url origin)" = "$origin_repo" ] \
            || fail "Expected first relative-origin checkout to store an absolute managed origin URL"

        mv "$source_repo" "$moved_source_repo"
        git clone "$origin_repo" "$updater_repo" >/dev/null 2>&1
        git -C "$updater_repo" config user.name "Smoke Test"
        git -C "$updater_repo" config user.email "smoke@example.com"
        cat > "$updater_repo/relative.txt" <<'EOF'
relative-origin-updated
EOF
        git -C "$updater_repo" commit -am "advance remote" >/dev/null
        git -C "$updater_repo" push origin main >/dev/null

        prepare_build_repo

        [ "$(cat "$MANAGED_REPO_DIR/relative.txt")" = "relative-origin-updated" ] \
            || fail "Expected managed checkout to update after source checkout moved away"
        [ "$(git -C "$MANAGED_REPO_DIR" remote get-url origin)" = "$origin_repo" ] \
            || fail "Expected moved-source update to keep using the absolute managed origin URL"
    )
}

test_user_local_install_from_update_defers_record_only_metadata() {
    info "Checking user-local helper refresh does not record metadata before update success"
    local workspace="$TMP_DIR/user-local-from-update-record-only"
    local fake_bin="$workspace/bin"
    local home="$workspace/home"
    local marker="$workspace/record-only-attempted"
    local metadata_file="$workspace/state/codex-desktop-linux/metadata.env"
    local app_dir="$home/.local/opt/codex-desktop-linux/codex-app"

    mkdir -p "$fake_bin"
    cat > "$fake_bin/7z" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
: "${RECORD_ONLY_MARKER:?}"
mkdir -p "$(dirname "$RECORD_ONLY_MARKER")"
printf '%s\n' "attempted" > "$RECORD_ONLY_MARKER"
exit 1
SCRIPT
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/systemctl"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/update-desktop-database"
    chmod +x "$fake_bin/7z" "$fake_bin/systemctl" "$fake_bin/update-desktop-database"
    mkdir -p "$app_dir"
    printf '%s\n' "26.609.41114" > "$app_dir/version"

    PATH="$fake_bin:$PATH" \
        HOME="$home" \
        XDG_DATA_HOME="$workspace/data" \
        XDG_STATE_HOME="$workspace/state" \
        RECORD_ONLY_MARKER="$marker" \
        CODEX_USER_LOCAL_SOURCE_REPO_DIR="$REPO_DIR" \
        bash "$REPO_DIR/contrib/user-local-install/install-user-local.sh" --from-update >/dev/null
    assert_file_not_exists "$marker"
    assert_file_not_exists "$metadata_file"

    PATH="$fake_bin:$PATH" \
        HOME="$home" \
        XDG_DATA_HOME="$workspace/data" \
        XDG_STATE_HOME="$workspace/state" \
        RECORD_ONLY_MARKER="$marker" \
        CODEX_USER_LOCAL_SOURCE_REPO_DIR="$REPO_DIR" \
        bash "$REPO_DIR/contrib/user-local-install/install-user-local.sh" >/dev/null
    assert_file_not_exists "$marker"
    assert_file_exists "$metadata_file"
    assert_contains "$metadata_file" "DMG_SHA256=unavailable"
}

test_user_local_install_preserves_persisted_x11_preference_on_refresh() {
    info "Checking user-local X11 fallback preference persists across helper refreshes"
    local workspace="$TMP_DIR/user-local-x11-preference"
    local stub_bin="$workspace/bin"
    local home="$workspace/home"
    local config_home="$workspace/config"
    local preference_file="$config_home/codex-desktop-linux/user-local.env"

    mkdir -p "$stub_bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_bin/7z"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_bin/systemctl"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_bin/update-desktop-database"
    chmod +x "$stub_bin/7z" "$stub_bin/systemctl" "$stub_bin/update-desktop-database"

    PATH="$stub_bin:$PATH" \
        HOME="$home" \
        XDG_CONFIG_HOME="$config_home" \
        XDG_DATA_HOME="$workspace/data" \
        XDG_STATE_HOME="$workspace/state" \
        CODEX_USER_LOCAL_SOURCE_REPO_DIR="$REPO_DIR" \
        bash "$REPO_DIR/contrib/user-local-install/install-user-local.sh" --force-x11 >/dev/null
    assert_file_exists "$preference_file"
    assert_contains "$preference_file" "CODEX_USER_LOCAL_OZONE_PLATFORM=x11"

    PATH="$stub_bin:$PATH" \
        HOME="$home" \
        XDG_CONFIG_HOME="$config_home" \
        XDG_DATA_HOME="$workspace/data" \
        XDG_STATE_HOME="$workspace/state" \
        CODEX_USER_LOCAL_SOURCE_REPO_DIR="$REPO_DIR" \
        bash "$REPO_DIR/contrib/user-local-install/install-user-local.sh" --from-update >/dev/null
    assert_contains "$preference_file" "CODEX_USER_LOCAL_OZONE_PLATFORM=x11"

    PATH="$stub_bin:$PATH" \
        HOME="$home" \
        XDG_CONFIG_HOME="$config_home" \
        XDG_DATA_HOME="$workspace/data" \
        XDG_STATE_HOME="$workspace/state" \
        CODEX_USER_LOCAL_SOURCE_REPO_DIR="$REPO_DIR" \
        bash "$REPO_DIR/contrib/user-local-install/install-user-local.sh" --no-force-x11 >/dev/null
    assert_contains "$preference_file" "CODEX_USER_LOCAL_OZONE_PLATFORM=auto"
}

test_user_local_prepare_build_repo_copies_enabled_local_features() {
    info "Checking user-local managed checkout stages enabled local features"
    local workspace="$TMP_DIR/user-local-local-features"
    local origin_repo="$workspace/origin.git"
    local source_repo="$workspace/source"
    local managed_repo="$workspace/xdg-data/codex-desktop-linux/managed-repo"
    local install_env="$workspace/install.env"
    local feature_config="$workspace/linux-features.json"
    local staged_local_feature="$managed_repo/linux-features/local/local-tool"

    mkdir -p "$workspace"
    git init --bare --initial-branch=main "$origin_repo" >/dev/null
    git clone "$origin_repo" "$source_repo" >/dev/null 2>&1
    git -C "$source_repo" config user.name "Smoke Test"
    git -C "$source_repo" config user.email "smoke@example.com"

    mkdir -p "$source_repo/linux-features/repo-feature"
    printf '%s\n' '# Linux Features' > "$source_repo/linux-features/README.md"
    printf '%s\n' '{"enabled":[]}' > "$source_repo/linux-features/features.example.json"
    printf '%s\n' '{"id":"repo-feature","title":"Repo Feature"}' \
        > "$source_repo/linux-features/repo-feature/feature.json"
    printf '%s\n' '# Repo Feature' > "$source_repo/linux-features/repo-feature/README.md"
    git -C "$source_repo" add linux-features
    git -C "$source_repo" commit -m "base" >/dev/null
    git -C "$source_repo" push -u origin main >/dev/null

    mkdir -p "$source_repo/linux-features/local/local-tool/nested"
    mkdir -p "$source_repo/linux-features/local/repo-feature"
    printf '%s\n' '{"id":"local-tool","title":"Local Tool"}' \
        > "$source_repo/linux-features/local/local-tool/feature.json"
    printf '%s\n' '# Local Tool' > "$source_repo/linux-features/local/local-tool/README.md"
    printf '%s\n' 'payload' > "$source_repo/linux-features/local/local-tool/nested/payload.txt"
    ln -s nested/payload.txt "$source_repo/linux-features/local/local-tool/payload-link"
    printf '%s\n' '{"id":"repo-feature","title":"Local Repo Feature"}' \
        > "$source_repo/linux-features/local/repo-feature/feature.json"
    cat > "$feature_config" <<'JSON'
{
  "enabled": [
    "local-tool",
    "repo-feature",
    "missing-local",
    "bad id"
  ]
}
JSON

    (
        export HOME="$workspace/home"
        export XDG_DATA_HOME="$workspace/xdg-data"
        export XDG_STATE_HOME="$workspace/xdg-state"
        export CODEX_LINUX_FEATURES_CONFIG="$feature_config"
        mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

        # shellcheck disable=SC1091
        source "$REPO_DIR/contrib/user-local-install/files/.local/lib/codex-desktop-linux/common.sh"

        INSTALL_CONFIG_FILE="$install_env"
        cat > "$INSTALL_CONFIG_FILE" <<EOF
SOURCE_REPO_DIR=$(printf '%q' "$source_repo")
MANAGED_REPO_DIR=$(printf '%q' "$managed_repo")
REPO_ORIGIN_URL=$(printf '%q' "$origin_repo")
REPO_DEFAULT_BRANCH=$(printf '%q' "main")
OPT_ROOT=$(printf '%q' "$workspace/opt")
EOF

        prepare_build_repo
    )

    assert_file_exists "$staged_local_feature/feature.json"
    [ "$(cat "$staged_local_feature/nested/payload.txt")" = "payload" ] \
        || fail "Expected local feature nested payload to be copied"
    [ -L "$staged_local_feature/payload-link" ] \
        || fail "Expected local feature symlink to be preserved"
    [ "$(readlink "$staged_local_feature/payload-link")" = "nested/payload.txt" ] \
        || fail "Expected local feature symlink target to be preserved"
    assert_file_not_exists "$managed_repo/linux-features/local/repo-feature/feature.json"
    assert_file_not_exists "$managed_repo/linux-features/local/missing-local/feature.json"
    assert_file_exists "$managed_repo/linux-features/repo-feature/feature.json"
}

test_user_local_prepare_build_repo_updates_existing_single_branch_fetch_refspec() {
    info "Checking user-local managed checkout can switch branches after a single-branch clone"
    local workspace="$TMP_DIR/user-local-single-branch-refspec"
    local origin_repo="$workspace/origin.git"
    local upstream_repo="$workspace/upstream"
    local unmanaged_source="$workspace/source-without-git"
    local managed_repo="$workspace/xdg-data/codex-desktop-linux/managed-repo"
    local install_env="$workspace/install.env"

    mkdir -p "$workspace" "$unmanaged_source"
    git init --bare --initial-branch=main "$origin_repo" >/dev/null
    git clone "$origin_repo" "$upstream_repo" >/dev/null 2>&1
    git -C "$upstream_repo" config user.name "Smoke Test"
    git -C "$upstream_repo" config user.email "smoke@example.com"
    cat > "$upstream_repo/branch.txt" <<'EOF'
main-branch
EOF
    git -C "$upstream_repo" add branch.txt
    git -C "$upstream_repo" commit -m "base" >/dev/null
    git -C "$upstream_repo" push -u origin main >/dev/null

    (
        export HOME="$workspace/home"
        export XDG_DATA_HOME="$workspace/xdg-data"
        export XDG_STATE_HOME="$workspace/xdg-state"
        mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

        # shellcheck disable=SC1091
        source "$REPO_DIR/contrib/user-local-install/files/.local/lib/codex-desktop-linux/common.sh"

        INSTALL_CONFIG_FILE="$install_env"
        cat > "$INSTALL_CONFIG_FILE" <<EOF
SOURCE_REPO_DIR=$(printf '%q' "$unmanaged_source")
MANAGED_REPO_DIR=$(printf '%q' "$managed_repo")
REPO_ORIGIN_URL=$(printf '%q' "$origin_repo")
REPO_DEFAULT_BRANCH=$(printf '%q' "main")
OPT_ROOT=$(printf '%q' "$workspace/opt")
EOF

        prepare_build_repo

        [ "$(git -C "$MANAGED_REPO_DIR" rev-parse --abbrev-ref HEAD)" = "main" ] \
            || fail "Expected managed checkout to start on main"
        [ "$(git -C "$MANAGED_REPO_DIR" config --get-all remote.origin.fetch)" = "+refs/heads/*:refs/remotes/origin/*" ] \
            || fail "Expected managed checkout fetch refspec to include all branches"
    )

    git -C "$upstream_repo" checkout -q -b master
    cat > "$upstream_repo/branch.txt" <<'EOF'
master-branch
EOF
    git -C "$upstream_repo" commit -am "master branch" >/dev/null
    git -C "$upstream_repo" push -u origin master >/dev/null
    git --git-dir="$origin_repo" symbolic-ref HEAD refs/heads/master

    (
        export HOME="$workspace/home"
        export XDG_DATA_HOME="$workspace/xdg-data"
        export XDG_STATE_HOME="$workspace/xdg-state"
        mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

        # shellcheck disable=SC1091
        source "$REPO_DIR/contrib/user-local-install/files/.local/lib/codex-desktop-linux/common.sh"

        INSTALL_CONFIG_FILE="$install_env"
        cat > "$INSTALL_CONFIG_FILE" <<EOF
SOURCE_REPO_DIR=$(printf '%q' "$unmanaged_source")
MANAGED_REPO_DIR=$(printf '%q' "$managed_repo")
REPO_ORIGIN_URL=$(printf '%q' "$origin_repo")
REPO_DEFAULT_BRANCH=$(printf '%q' "master")
OPT_ROOT=$(printf '%q' "$workspace/opt")
EOF

        prepare_build_repo

        [ "$(git -C "$MANAGED_REPO_DIR" rev-parse --abbrev-ref HEAD)" = "master" ] \
            || fail "Expected managed checkout to switch to master"
        [ "$(cat "$MANAGED_REPO_DIR/branch.txt")" = "master-branch" ] \
            || fail "Expected managed checkout contents from the newly selected branch"
    )
}

test_user_local_prepare_build_repo_handles_deleted_overlay_paths() {
    info "Checking user-local managed checkout tolerates overlay paths deleted in the worktree"
    local workspace="$TMP_DIR/user-local-deleted-overlay"
    local origin_repo="$workspace/origin.git"
    local source_repo="$workspace/source"
    local managed_repo="$workspace/xdg-data/codex-desktop-linux/managed-repo"
    local install_env="$workspace/install.env"

    mkdir -p "$workspace"
    git init --bare --initial-branch=main "$origin_repo" >/dev/null
    git clone "$origin_repo" "$source_repo" >/dev/null 2>&1
    git -C "$source_repo" config user.name "Smoke Test"
    git -C "$source_repo" config user.email "smoke@example.com"

    cat > "$source_repo/overlay.txt" <<'EOF'
base
EOF
    git -C "$source_repo" add overlay.txt
    git -C "$source_repo" commit -m "base" >/dev/null
    git -C "$source_repo" push -u origin main >/dev/null
    git -C "$source_repo" remote set-head origin -a >/dev/null 2>&1 || true

    cat > "$source_repo/overlay.txt" <<'EOF'
committed-overlay
EOF
    git -C "$source_repo" commit -am "overlay commit" >/dev/null
    rm -f "$source_repo/overlay.txt"

    (
        export HOME="$workspace/home"
        export XDG_DATA_HOME="$workspace/xdg-data"
        export XDG_STATE_HOME="$workspace/xdg-state"
        mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

        # shellcheck disable=SC1091
        source "$REPO_DIR/contrib/user-local-install/files/.local/lib/codex-desktop-linux/common.sh"

        INSTALL_CONFIG_FILE="$install_env"
        cat > "$INSTALL_CONFIG_FILE" <<EOF
SOURCE_REPO_DIR=$(printf '%q' "$source_repo")
MANAGED_REPO_DIR=$(printf '%q' "$managed_repo")
REPO_ORIGIN_URL=$(printf '%q' "$origin_repo")
REPO_DEFAULT_BRANCH=$(printf '%q' "main")
OPT_ROOT=$(printf '%q' "$workspace/opt")
EOF

        prepare_build_repo

        [ ! -e "$MANAGED_REPO_DIR/overlay.txt" ] \
            || fail "Expected deleted overlay path to be removed from managed checkout"
    )
}

test_user_local_prepare_build_repo_removes_rename_source_paths() {
    info "Checking user-local managed checkout removes rename source paths"
    local workspace="$TMP_DIR/user-local-rename-overlay"
    local origin_repo="$workspace/origin.git"
    local source_repo="$workspace/source"
    local managed_repo="$workspace/xdg-data/codex-desktop-linux/managed-repo"
    local install_env="$workspace/install.env"

    mkdir -p "$workspace"
    git init --bare --initial-branch=main "$origin_repo" >/dev/null
    git clone "$origin_repo" "$source_repo" >/dev/null 2>&1
    git -C "$source_repo" config user.name "Smoke Test"
    git -C "$source_repo" config user.email "smoke@example.com"

    cat > "$source_repo/old-name.txt" <<'EOF'
base
EOF
    git -C "$source_repo" add old-name.txt
    git -C "$source_repo" commit -m "base" >/dev/null
    git -C "$source_repo" push -u origin main >/dev/null
    git -C "$source_repo" remote set-head origin -a >/dev/null 2>&1 || true

    git -C "$source_repo" mv old-name.txt new-name.txt
    git -C "$source_repo" commit -m "rename overlay file" >/dev/null

    (
        export HOME="$workspace/home"
        export XDG_DATA_HOME="$workspace/xdg-data"
        export XDG_STATE_HOME="$workspace/xdg-state"
        mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

        # shellcheck disable=SC1091
        source "$REPO_DIR/contrib/user-local-install/files/.local/lib/codex-desktop-linux/common.sh"

        INSTALL_CONFIG_FILE="$install_env"
        cat > "$INSTALL_CONFIG_FILE" <<EOF
SOURCE_REPO_DIR=$(printf '%q' "$source_repo")
MANAGED_REPO_DIR=$(printf '%q' "$managed_repo")
REPO_ORIGIN_URL=$(printf '%q' "$origin_repo")
REPO_DEFAULT_BRANCH=$(printf '%q' "main")
OPT_ROOT=$(printf '%q' "$workspace/opt")
EOF

        prepare_build_repo

        [ ! -e "$MANAGED_REPO_DIR/old-name.txt" ] \
            || fail "Expected rename source path to be removed from managed checkout"
        [ "$(cat "$MANAGED_REPO_DIR/new-name.txt")" = "base" ] \
            || fail "Expected rename destination path to be present in managed checkout"
    )
}

test_user_local_prepare_build_repo_skips_unmerged_overlay_paths() {
    info "Checking user-local managed checkout skips unmerged overlay paths"
    local workspace="$TMP_DIR/user-local-unmerged-overlay"
    local origin_repo="$workspace/origin.git"
    local source_repo="$workspace/source"
    local managed_repo="$workspace/xdg-data/codex-desktop-linux/managed-repo"
    local install_env="$workspace/install.env"

    mkdir -p "$workspace"
    git init --bare --initial-branch=main "$origin_repo" >/dev/null
    git clone "$origin_repo" "$source_repo" >/dev/null 2>&1
    git -C "$source_repo" config user.name "Smoke Test"
    git -C "$source_repo" config user.email "smoke@example.com"

    cat > "$source_repo/conflict.txt" <<'EOF'
base
EOF
    git -C "$source_repo" add conflict.txt
    git -C "$source_repo" commit -m "base" >/dev/null
    git -C "$source_repo" push -u origin main >/dev/null
    git -C "$source_repo" remote set-head origin -a >/dev/null 2>&1 || true

    git -C "$source_repo" checkout -q -b feature
    cat > "$source_repo/conflict.txt" <<'EOF'
feature-change
EOF
    git -C "$source_repo" commit -am "feature change" >/dev/null
    git -C "$source_repo" checkout -q main
    cat > "$source_repo/conflict.txt" <<'EOF'
main-change
EOF
    git -C "$source_repo" commit -am "main change" >/dev/null
    if git -C "$source_repo" merge feature >/dev/null 2>&1; then
        fail "Expected merge to conflict in unmerged overlay smoke test"
    fi
    assert_contains "$source_repo/conflict.txt" "<<<<<<<"

    (
        export HOME="$workspace/home"
        export XDG_DATA_HOME="$workspace/xdg-data"
        export XDG_STATE_HOME="$workspace/xdg-state"
        mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

        # shellcheck disable=SC1091
        source "$REPO_DIR/contrib/user-local-install/files/.local/lib/codex-desktop-linux/common.sh"

        INSTALL_CONFIG_FILE="$install_env"
        cat > "$INSTALL_CONFIG_FILE" <<EOF
SOURCE_REPO_DIR=$(printf '%q' "$source_repo")
MANAGED_REPO_DIR=$(printf '%q' "$managed_repo")
REPO_ORIGIN_URL=$(printf '%q' "$origin_repo")
REPO_DEFAULT_BRANCH=$(printf '%q' "main")
OPT_ROOT=$(printf '%q' "$workspace/opt")
EOF

        prepare_build_repo

        [ "$(cat "$MANAGED_REPO_DIR/conflict.txt")" = "base" ] \
            || fail "Expected managed checkout to keep clean upstream content for unmerged overlay paths"
        assert_not_contains "$MANAGED_REPO_DIR/conflict.txt" "<<<<<<<"
    )
}

test_upstream_build_app_workflow_tracks_dmg_metadata() {
    info "Checking upstream build-app workflow metadata and cache behavior"
    local workflow="$REPO_DIR/.github/workflows/upstream-build-app.yml"

    assert_file_exists "$workflow"
    assert_contains "$workflow" 'name: Upstream Build App'
    assert_contains "$workflow" 'UPSTREAM_DMG_URL: https://persistent.oaistatic.com/codex-app-prod/Codex.dmg'
    assert_contains "$workflow" 'actions/cache@v4'
    assert_contains "$workflow" 'path: /tmp/codex-upstream-ci/Codex.dmg'
    assert_contains "$workflow" 'Last-Modified'
    assert_contains "$workflow" 'sha256sum'
    assert_contains "$workflow" 'CODEX_PATCH_REPORT_JSON="$GITHUB_WORKSPACE/patch-report.json"'
    assert_contains "$workflow" 'node scripts/ci/validate-patch-report.js patch-report.json --profile upstream-build'
    assert_contains "$workflow" 'make build-app DMG=/tmp/codex-upstream-ci/Codex.dmg'
    assert_contains "$workflow" 'DMG Last-Modified'
    assert_contains "$workflow" 'DMG SHA-256'
}

main() {
    test_common_helper_sourcing
    test_appimage_builder_smoke
    test_make_build_app_uses_installer_download_flow_by_default
    test_make_build_app_fresh_uses_installer_fresh_flow
    test_upstream_build_app_workflow_tracks_dmg_metadata
    test_installer_detects_electron_version_from_plist
    test_installer_keeps_electron_fallback_for_bad_metadata
    test_port_validation_rejects_oversized_numeric_values
    test_managed_node_runtime_source_install
    test_better_sqlite3_electron_42_source_patch
    test_native_module_rebuild_uses_local_electron_rebuild_toolchain
    test_native_module_rebuild_accepts_prebuilt_source
    test_bundled_plugin_builders_accept_prebuilt_binaries
    test_browser_use_node_repl_fallback_runtime
    test_browser_use_node_repl_glibc_pidfd_patch_static
    test_browser_use_node_repl_ldd_output_compatibility
    test_chrome_plugin_staging
    test_chrome_browser_client_profile_root_variants
    test_chrome_marketplace_fallback_synthesis
    test_chrome_native_host_manifest_writer
    test_process_detection_helper_cmdline_shapes
    test_webview_probe_equivalence
    test_side_by_side_launcher_identity
    test_linux_file_manager_patch_smoke
    test_linux_translucent_sidebar_default_patch_smoke
    test_keybinds_settings_tab_patch_smoke
    test_keybinds_settings_patch_warns_on_bundle_shape_miss
    test_linux_tray_patch_smoke
    test_linux_explicit_quit_patch_smoke
    test_browser_annotation_screenshot_patch_smoke
    test_linux_single_instance_patch_smoke
    test_linux_computer_use_gate_patch_smoke
    test_linux_computer_use_ui_opt_in_smoke
    test_linux_file_manager_patch_fails_soft
    test_patcher_enforce_critical_gate
    test_user_local_prepare_build_repo_overlays_committed_local_changes
    test_user_local_prepare_build_repo_detects_default_branch_without_recorded_branch
    test_user_local_prepare_build_repo_ignores_stale_recorded_default_branch
    test_user_local_prepare_build_repo_ignores_stale_source_origin_head
    test_user_local_prepare_build_repo_handles_relative_origin_url
    test_user_local_install_from_update_defers_record_only_metadata
    test_user_local_install_preserves_persisted_x11_preference_on_refresh
    test_user_local_prepare_build_repo_copies_enabled_local_features
    test_user_local_prepare_build_repo_updates_existing_single_branch_fetch_refspec
    test_user_local_prepare_build_repo_handles_deleted_overlay_paths
    test_user_local_prepare_build_repo_removes_rename_source_paths
    test_user_local_prepare_build_repo_skips_unmerged_overlay_paths
    info "All script smoke tests passed"
}

main "$@"
