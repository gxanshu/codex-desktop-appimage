# Codex Desktop for Linux (AppImage fork)

Unofficial AppImage build of [OpenAI Codex Desktop](https://openai.com/codex/) for Linux. The official Codex Desktop app is macOS-only — a GitHub Action in this repo downloads the upstream macOS `Codex.dmg` daily, patches its Electron resources for Linux, and publishes a new GitHub Release whenever upstream changes.

This is a fork of [`ilysenko/codex-desktop-linux`](https://github.com/ilysenko/codex-desktop-linux). The upstream project ships `.deb` / `.rpm` / `.pkg.tar.zst` and an on-device rebuild daemon (`codex-update-manager`) that re-extracts and re-packages the app on each user's machine. **This fork strips all of that out** and produces a single artifact: an AppImage that auto-updates from this repo's GitHub Releases via the standard AppImage update protocol.

## Install

1. Download the latest `codex-desktop-*-x86_64.AppImage` from the [Releases page](../../releases).
2. Open it with [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) (recommended) or run it directly:
   ```bash
   chmod +x codex-desktop-*-x86_64.AppImage
   ./codex-desktop-*-x86_64.AppImage
   ```
3. Gear Lever integrates the AppImage with your desktop and checks for updates automatically.

The AppImage carries embedded update info (`gh-releases-zsync|<owner>|<repo>|latest|...`) so Gear Lever, AppImageUpdate, and other AppImage tools can pull new releases as they appear. No daemon, no systemd unit, no polkit — Gear Lever is the only thing running on your machine.

## How updates work

A scheduled GitHub Actions workflow (`.github/workflows/release-appimage.yml`) runs daily:

1. Sends a `HEAD` request to OpenAI's upstream `Codex.dmg` URL.
2. Compares the new SHA-256 against the last release's `upstream-dmg-metadata.json` asset.
3. If unchanged → exits without publishing.
4. If changed → downloads the DMG, runs `make build-app`, runs `scripts/build-appimage.sh` with `APPIMAGE_UPDATE_INFO` set, and publishes a new release with the `.AppImage`, `.AppImage.zsync`, and metadata sidecar attached.

You can also trigger the workflow manually from the Actions tab.

## Pulling fork upstream fixes

When `ilysenko/codex-desktop-linux` lands a fix you want, sync it into this fork:

```bash
# one-time
git remote add upstream https://github.com/ilysenko/codex-desktop-linux.git

# whenever an upstream fix matters
git fetch upstream
git checkout -b sync/upstream-$(date +%Y%m%d) main
git merge upstream/main          # resolve conflicts; ours are the AppImage workflow and infra
git push -u origin HEAD
gh pr create --fill --base main
```

Use `merge` (not `rebase`): this fork has diverged in infrastructure (workflow, slimmed Makefile, removed packaging), so rebasing multiplies the conflict surface across upstream history.

## Linux features

Optional Linux-only additions live in `linux-features/`. Use them for integrations that are useful for some users but should not become mandatory core patches. Copy `linux-features/features.example.json` to the git-ignored `linux-features/features.json` before building; enabled features are applied during the install/build pipeline. See [`linux-features/README.md`](linux-features/README.md) for the feature contract.

## Build locally

You generally don't need to — GitHub Actions builds an AppImage and attaches it to a release every time upstream changes. If you want to build one yourself:

```bash
# Install build deps (Debian/Ubuntu)
sudo apt install python3 p7zip-full curl unzip build-essential

# Install appimagetool
curl -fL -o /tmp/appimagetool \
  https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x /tmp/appimagetool
( cd /tmp && ./appimagetool --appimage-extract >/dev/null )
sudo install -m 0755 /tmp/squashfs-root/AppRun /usr/local/bin/appimagetool

# Build
make build-app          # extracts and patches the upstream DMG into codex-app/
make appimage           # writes dist/codex-desktop-*-x86_64.AppImage
```

Local builds don't embed update info by default — set `APPIMAGE_UPDATE_INFO` if you want your own AppImage to update from your own GitHub repo:

```bash
APPIMAGE_UPDATE_INFO='gh-releases-zsync|you|your-repo|latest|codex-desktop-*-x86_64.AppImage.zsync' \
    make appimage
```

## Architecture

Only `x86_64` is supported. OpenAI's upstream `Codex.dmg` is macOS x86_64 only; the Electron resources extracted from it are not portable to aarch64 without a separate upstream build.

## Linux Computer Use

Linux Computer Use is an **opt-in** plugin that lets Codex inspect and control desktop apps on Linux through a native Rust MCP backend (`codex-computer-use-linux`). It is designed and maintained by [@avifenesh](https://github.com/avifenesh) and supports:

- app listing and accessibility trees via AT-SPI
- screenshots through GNOME Shell DBus or XDG Desktop Portal
- window listing and focusing on GNOME, KWin/Plasma, Hyprland, and i3
- keyboard, text, click, scroll, and drag input through `ydotool`

### Runtime dependencies

```bash
# Debian / Ubuntu
sudo apt install ydotool
# Some Ubuntu releases package the daemon separately:
sudo apt install ydotoold

# Fedora
sudo dnf install ydotool

# Arch
sudo pacman -S ydotool

# openSUSE
sudo zypper install ydotool
```

`ydotool` needs `/dev/uinput` access. The usual setup is to run `ydotoold`, add your user to the `input` group, then re-login:

```bash
sudo systemctl enable --now ydotoold
sudo usermod -a -G input "$USER"
```

On Fedora 44, the packaged unit is commonly named `ydotool.service` rather than `ydotoold.service`. Some distros install `/usr/bin/ydotoold` without any service unit. If `systemctl enable --now ydotoold` fails, start the distro-provided unit instead or create a user-session service that binds `%t/.ydotool_socket`. If `doctor` reports `ydotool_socket: Permission denied`, make sure the socket is usable by users in the `input` group.

If you are on Fedora + KDE Plasma and the system unit path is awkward, a user-session `ydotoold` service is also a valid setup. In that case, make sure:

- the socket is reachable at `%t/.ydotool_socket`
- the service runs inside your user session
- old system-level overrides are removed if they force the wrong socket path
- `codex-computer-use-linux doctor` reports `can_send_development_input: true`

A working XDG Desktop Portal implementation is needed if you are not on GNOME — `xdg-desktop-portal-kde` for KDE Plasma, `xdg-desktop-portal-wlr` for sway / Hyprland, or your distro's preferred portal backend for i3. GNOME ships a working portal by default.

### Verifying readiness

Once Computer Use is visible in the Codex UI, ask the LLM:

> Check whether Linux Computer Use is ready

You can also invoke the backend binary directly:

```bash
./codex-app/resources/plugins/openai-bundled/plugins/computer-use/bin/codex-computer-use-linux doctor
./codex-app/resources/plugins/openai-bundled/plugins/computer-use/bin/codex-computer-use-linux setup    # enables GNOME accessibility
./codex-app/resources/plugins/openai-bundled/plugins/computer-use/bin/codex-computer-use-linux apps     # lists running apps via AT-SPI
./codex-app/resources/plugins/openai-bundled/plugins/computer-use/bin/codex-computer-use-linux windows  # lists targetable windows
./codex-app/resources/plugins/openai-bundled/plugins/computer-use/bin/codex-computer-use-linux screenshot
```

### Enabling Computer Use UI

By default the MCP backend registers, but the Codex Desktop sidebar does not surface the Computer Use controls. If you want to use it through the in-app UI, opt in by setting one of:

```bash
# Ad-hoc, for a single build:
CODEX_LINUX_ENABLE_COMPUTER_USE_UI=1 make build-app

# Persistent (also picked up by the auto-updater on future rebuilds):
mkdir -p ~/.config/codex-desktop
echo '{"codex-linux-computer-use-ui-enabled": true}' > ~/.config/codex-desktop/settings.json
```

Either path enables the in-app controls on subsequent builds. To opt back out, unset the env var and remove or set the settings flag to `false`.

### Side-by-side dev variant

If you'd like to test the backend without affecting your default install, the side-by-side dev variant builds a separate app under a different ID and webview port:

```bash
make build-dev-app
make run-dev-app
```

Override the dev identity with `DEV_APP_ID`, `DEV_APP_NAME`, and `CODEX_WEBVIEW_PORT` if needed.

### Multiple app instances

By default, second launches reuse the running app through the Linux warm-start handoff. To intentionally open another independent Codex Desktop process, use:

```bash
./codex-app/start.sh --new-instance
```

The launcher picks the first free webview port from a bounded range, then uses per-port pid files, launch socket, log, and Electron user-data dir. This keeps Electron's single-instance lock scoped to that new instance while leaving normal launches unchanged. The default range allows up to five instances.

Configure the range or make every launch use this mode with:

```bash
CODEX_MULTI_LAUNCH_PORT_RANGE=5175-5199 ./codex-app/start.sh --new-instance
CODEX_MULTI_LAUNCH=1 CODEX_MULTI_LAUNCH_PORT_RANGE=5175-5199 ./codex-app/start.sh
```

## Build from source / custom DMG

### Prerequisites

You need:

- `python3`, `7z` (or `7zz`), `curl`, `unzip`, `make`, `g++`
- Rust toolchain (`cargo`) for the `codex-computer-use-linux` crate, including the Chrome extension host binary

The installer downloads a managed Linux Node.js runtime into `codex-app/resources/node-runtime` and uses it for `node`, `npm`, and `npx` during the build. Existing `nvm`, asdf, Volta, NodeSource, or nodejs.org tarball installs are still fine, but they are no longer required for this project.

Install dependencies manually per distro:

```bash
# Debian / Ubuntu
sudo apt install python3 p7zip-full curl unzip build-essential

# Fedora 41+
sudo dnf install python3 7zip curl unzip @development-tools

# Fedora < 41
sudo dnf install python3 p7zip p7zip-plugins curl unzip
sudo dnf groupinstall 'Development Tools'

# openSUSE
sudo zypper install python3 p7zip-full curl unzip
sudo zypper install -t pattern devel_basis

# Arch / Manjaro
sudo pacman -S --needed python p7zip curl unzip zstd base-devel

# Rust toolchain (any distro)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Ubuntu-family `p7zip-full` can be too old for newer APFS DMGs. If `make build-app` fails on the DMG extraction step, install a current `7zz` from <https://www.7-zip.org/> and put it on `PATH` before re-running.

### Generate the local Electron app

This produces `codex-app/` from the upstream DMG and writes the Linux launcher to `codex-app/start.sh`:

```bash
make build-app                              # download upstream DMG if no cached Codex.dmg exists
make build-app-fresh                        # remove codex-app/ + cached Codex.dmg, then download current upstream DMG
make build-app DMG=/path/to/Codex.dmg       # use a local copy
make run-app                                # launches the generated app
```

Equivalent direct commands:

```bash
./install.sh                                # default: download or reuse cached DMG
./install.sh /path/to/Codex.dmg             # use a specific DMG
./install.sh --fresh                        # remove existing install dir + cached DMG
./codex-app/start.sh                        # run after build
```

### Electron download mirrors

The app build commands download Electron headers while rebuilding native modules, then download a Linux Electron runtime. If the runtime download from GitHub is slow or blocked, use a mirror:

```bash
ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/ \
make build-app
```

`ELECTRON_HEADERS_URL` is passed to `@electron/rebuild --dist-url` and must provide both `node-v<version>-headers.tar.gz` and the matching `SHASUMS256.txt`.

## Package format

This fork produces a single artifact: an AppImage with embedded GitHub-Releases update info.

| Output | Build command | Notes |
|---|---|---|
| `dist/codex-desktop-<version>-x86_64.AppImage` | `make appimage` | Requires `appimagetool` on `PATH` (or `APPIMAGETOOL=/path/to/appimagetool`) |
| `dist/codex-desktop-<version>-x86_64.AppImage.zsync` | same | Auto-generated alongside the AppImage when `APPIMAGE_UPDATE_INFO` is set |

`make appimage` only repackages what's already in `codex-app/`. It does not download or extract the DMG itself — run `make build-app` first.

Override the version with `PACKAGE_VERSION=YYYY.MM.DD.HHMMSS+commitish make appimage`.

The deb/rpm/pacman builders and on-device update daemon from upstream `codex-desktop-linux` have been removed. If you need them, use the upstream repo directly.

## Make targets

```bash
make help
make build-app           # patch upstream DMG -> codex-app/
make build-app-fresh     # same, but redownload the DMG
make appimage            # package codex-app/ into dist/*.AppImage
make run-app             # launch codex-app/start.sh locally
make build-dev-app       # build side-by-side variant
make run-dev-app
make inspect-upstream    # write rebuild reports without changing codex-app/
make rebuild-next        # build a side-by-side candidate into codex-app-next/
make clean-dist
```

## Troubleshooting

| Problem | Solution |
|---|---|
| `Error: write EPIPE` | Run `start.sh` directly instead of piping output |
| Blank window | Check whether the configured webview port is already in use: `ss -tlnp \| grep -E '5175\|5176'` |
| `ERR_CONNECTION_REFUSED` on the webview port | The webview HTTP server failed to start. Ensure `python3` works and the configured port is free |
| Stuck on Codex logo splash | Check `~/.cache/codex-desktop/launcher.log`. If webview origin validation failed, another process is probably serving the configured webview port or the extracted `content/webview/` bundle is incomplete |
| `CODEX_CLI_PATH` error | Reopen the app to retry the automatic CLI install flow, or install manually with `npm i -g @openai/codex` / `npm i -g --prefix ~/.local @openai/codex` |
| Electron hangs while CLI is outdated | Re-run the launcher and check `~/.cache/codex-desktop/launcher.log`. Best-effort CLI preflight will warn if the automatic refresh fails |
| GPU / Vulkan / Wayland errors | Under Wayland with `DISPLAY` available, the launcher uses `--ozone-platform=x11` for window-positioning compatibility. Otherwise it uses `--ozone-platform-hint=auto`. GPU sandbox / compositing are disabled by default |
| Window flickering | GPU compositing is disabled by default. If flickering persists, try `./codex-app/start.sh --disable-gpu` to fully disable GPU acceleration |
| Sandbox errors | The launcher already sets `--no-sandbox` |
| Stale install / cached DMG | `make build-app-fresh` removes the existing install dir and cached DMG, then re-downloads |
| Computer Use plugin invisible in UI | Ensure you enabled the Computer Use UI. If it is enabled and still hidden, the OpenAI per-account rollout may not be available |
| Computer Use `doctor` reports `ydotool not running` | Start the distro-provided daemon unit (`ydotoold` or `ydotool`), or use a user-session `ydotoold` service, then add your user to the `input` group |
| Computer Use `doctor` reports `ydotool_socket: Permission denied` | The daemon socket is root-only. Adjust the `ydotoold` service so `/tmp/.ydotool_socket` becomes `root:input` with `0660` permissions |
| `ConnectTimeoutError` for `www.electronjs.org` during `@electron/rebuild` | Re-run `make build-app`; the installer now uses `https://artifacts.electronjs.org/headers/dist` for Electron headers by default |
| Computer Use AT-SPI tree empty | Run `codex-computer-use-linux setup` to flip GNOME accessibility on, then restart the target app |
| Stale `codex-update-manager` service from an old native package install | `systemctl --user disable --now codex-update-manager.service` once in the affected session, then remove `/opt/codex-desktop` and any installed deb/rpm/pacman packages from the upstream project |
| Resize ghosting or stale frame trails | Try `CODEX_ELECTRON_DISABLE_GPU_COMPOSITING=1 ./codex-app/start.sh` or `--disable-gpu-compositing` |
| UI oversized or blurry (HiDPI / fractional scaling) | Try `CODEX_FORCE_DEVICE_SCALE_FACTOR=1 ./codex-app/start.sh` or `CODEX_OZONE_PLATFORM=x11 ./codex-app/start.sh`; inspect the detected scaling with `./codex-app/start.sh --diagnose-scaling` |
| Wayland GPU / Vulkan hang | Try `CODEX_LINUX_RENDERING_MODE=wayland-gpu ./codex-app/start.sh`, or the default X11/auto fallback |
| `/tmp` mounted `noexec` | Set `TMPDIR` and `XDG_CACHE_HOME` to executable directories under `$HOME` before launching |

## How it works

1. `install.sh` extracts `Codex.dmg` with `7z`/`7zz`
2. It auto-detects the Electron version from upstream metadata, falling back to a pinned constant
3. It extracts and patches `app.asar` (Linux File Manager integration, tray, single-instance handoff, browser-annotation fixes, Computer Use platform gate, Linux opaque background, etc.) — every patch fail-soft, with regex-driven needles
4. It rebuilds native Node modules (`better-sqlite3`, `node-pty`) for Linux via `@electron/rebuild`
5. It downloads the matching Linux Electron runtime (cached under `~/.cache/codex-desktop/electron/`)
6. It writes the Linux launcher into `codex-app/start.sh` (body sourced from `launcher/start.sh.template`)
7. `scripts/build-appimage.sh` packages `codex-app/` into `dist/codex-desktop-*-x86_64.AppImage`. When `APPIMAGE_UPDATE_INFO` is set (in the release workflow), `appimagetool -u` embeds GitHub-Releases update info into the AppImage and writes a matching `.zsync` sidecar.
8. The `.github/workflows/release-appimage.yml` workflow detects upstream DMG changes daily and publishes a new release.

The installer replaces the macOS Electron binary with a Linux build, recompiles native modules, and removes macOS-only pieces such as `sparkle`.

The launcher serves extracted webview assets from `content/webview/` on `127.0.0.1` (`5175` by default, `5176` for the dev app), validates the origin, then starts Electron. Warm-start launches hand off actions such as `--new-chat` over a Unix-domain socket instead of spawning a second app process.

The current evaluation for a future Rust replacement of the local webview server lives in `docs/webview-server-evaluation.md`.

## Validation

After changing installer, packaging, or patch logic:

```bash
bash -n install.sh scripts/lib/*.sh launcher/start.sh.template scripts/build-appimage.sh
node --check scripts/patch-linux-window-ui.js
for file in scripts/patches/*.js; do node --check "$file"; done
node --check scripts/ci/validate-patch-report.js
node --test scripts/patch-linux-window-ui.test.js
node --test linux-features/*/test.js
bash tests/scripts_smoke.sh
cargo check -p codex-computer-use-linux
cargo test -p codex-computer-use-linux
```

Inspect an embedded AppImage update string after building:

```bash
strings dist/codex-desktop-*-x86_64.AppImage | grep '^gh-releases-zsync|'
# expected: gh-releases-zsync|<owner>|<repo>|latest|codex-desktop-*-x86_64.AppImage.zsync
```

## Versioning

Releases are tagged `vYYYY.MM.DD.HHMMSS+<dmg-sha256[0:8]>` — the build timestamp plus the first 8 hex chars of the upstream DMG's SHA-256. Two releases with the same DMG hash never get built (the workflow short-circuits on unchanged upstream).

See [CHANGELOG.md](CHANGELOG.md) for per-version detail.

## Disclaimer

This is an unofficial community project. Codex Desktop is a product of OpenAI. This tool does not redistribute any OpenAI software; it automates the conversion process that users perform on their own copies.

## License

MIT
