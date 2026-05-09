use crate::cosmic_helper;
use crate::diagnostics::hydrate_session_bus_env;
use crate::terminal::{enrich_terminal_windows, TerminalWindowContext};
use anyhow::{bail, Context, Result};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::Write,
    process::Command,
    sync::mpsc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::time::{sleep, timeout};
use zbus::{zvariant::OwnedValue, Proxy};

pub const GNOME_SHELL_INTROSPECT_BACKEND: &str = "gnome-shell-introspect";
pub const GNOME_SHELL_EXTENSION_BACKEND: &str = "gnome-shell-extension";
pub const COSMIC_WAYLAND_BACKEND: &str = "cosmic-wayland";
pub const KWIN_BACKEND: &str = "kwin";
pub const HYPRLAND_BACKEND: &str = "hyprland";
pub const GNOME_SHELL_EXTENSION_SERVICE: &str = "com.openai.Codex.WindowControl";
pub const GNOME_SHELL_EXTENSION_OBJECT_PATH: &str = "/com/openai/Codex/WindowControl";
pub const WINDOW_PERMISSION_HINT: &str = "Computer Use could not access a supported window list backend. Targeted window input requires session-bus access plus GNOME Shell Introspect, the Codex GNOME Shell extension, the COSMIC Wayland helper, KWin/Plasma DBus scripting, or Hyprland hyprctl. On GNOME, run setup_window_targeting to install the extension backend.";
const FOCUS_VERIFY_ATTEMPTS: usize = 6;
const FOCUS_VERIFY_DELAY: Duration = Duration::from_millis(50);
const KWIN_SCRIPT_TIMEOUT: Duration = Duration::from_secs(2);
const KWIN_SCRIPTING_SERVICE: &str = "org.kde.KWin";
const KWIN_SCRIPTING_OBJECT_PATH: &str = "/Scripting";
const KWIN_SCRIPTING_INTERFACE: &str = "org.kde.kwin.Scripting";
const KWIN_CALLBACK_OBJECT_PATH_PREFIX: &str = "/com/openai/Codex/KWinWindowQuery";
const KWIN_CALLBACK_INTERFACE: &str = "com.openai.Codex.KWinWindowQuery";

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
pub struct WindowInfo {
    pub window_id: u64,
    pub title: Option<String>,
    pub app_id: Option<String>,
    pub wm_class: Option<String>,
    pub pid: Option<u32>,
    pub bounds: Option<WindowBounds>,
    pub workspace: Option<i32>,
    pub focused: bool,
    pub hidden: bool,
    pub client_type: Option<String>,
    pub backend: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal: Option<TerminalWindowContext>,
}

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
pub struct WindowBounds {
    pub x: Option<i32>,
    pub y: Option<i32>,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
pub struct WindowTarget {
    #[serde(default)]
    pub window_id: Option<u64>,
    #[serde(default)]
    pub pid: Option<u32>,
    #[serde(default)]
    pub tty: Option<String>,
    #[serde(default)]
    pub terminal_pid: Option<u32>,
    #[serde(default)]
    pub terminal_command: Option<String>,
    #[serde(default)]
    pub terminal_cwd: Option<String>,
    #[serde(default)]
    pub app_id: Option<String>,
    #[serde(default)]
    pub wm_class: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct WindowFocusResult {
    pub requested_window: WindowInfo,
    pub focused_window: Option<WindowInfo>,
    pub exact_window_focused: bool,
    pub app_focused: bool,
    pub backend: String,
    pub note: String,
}

impl WindowTarget {
    pub fn has_target(&self) -> bool {
        self.window_id.is_some()
            || self.pid.is_some()
            || self.has_terminal_target()
            || self
                .app_id
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
            || self
                .wm_class
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
            || self
                .title
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
    }

    pub fn requires_exact_focus(&self) -> bool {
        self.window_id.is_some()
            || self.pid.is_some()
            || self.has_terminal_target()
            || self
                .title
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
    }

    fn has_terminal_target(&self) -> bool {
        self.terminal_pid.is_some()
            || self
                .tty
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
            || self
                .terminal_command
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
            || self
                .terminal_cwd
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
    }
}

pub async fn list_windows() -> Result<Vec<WindowInfo>> {
    match list_extension_windows().await {
        Ok(windows) => Ok(windows),
        Err(extension_error) => match list_gnome_shell_introspect_windows().await {
            Ok(windows) => Ok(windows),
            Err(introspect_error) => match list_cosmic_helper_windows() {
                Ok(windows) => Ok(windows),
                Err(cosmic_error) => match list_kwin_windows().await {
                    Ok(windows) => Ok(windows),
                    Err(kwin_error) => match list_hyprland_windows() {
                        Ok(windows) => Ok(windows),
                        Err(hyprland_error) => Err(anyhow::anyhow!(
                            "Codex GNOME Shell extension failed: {extension_error:#}; GNOME Shell Introspect failed: {introspect_error:#}; COSMIC helper failed: {cosmic_error:#}; KWin failed: {kwin_error:#}; Hyprland failed: {hyprland_error:#}"
                        )),
                    },
                },
            },
        },
    }
}

async fn list_gnome_shell_introspect_windows() -> Result<Vec<WindowInfo>> {
    hydrate_session_bus_env();

    let connection = zbus::Connection::session()
        .await
        .context("failed to connect to session bus")?;
    let proxy = Proxy::new(
        &connection,
        "org.gnome.Shell",
        "/org/gnome/Shell/Introspect",
        "org.gnome.Shell.Introspect",
    )
    .await
    .context("failed to create GNOME Shell introspection proxy")?;
    let windows: HashMap<u64, HashMap<String, OwnedValue>> = proxy
        .call("GetWindows", &())
        .await
        .context("GNOME Shell GetWindows call failed")?;

    let mut windows = windows
        .into_iter()
        .map(|(window_id, properties)| window_from_properties(window_id, &properties))
        .collect::<Vec<_>>();
    windows.sort_by_key(|window| window.window_id);
    enrich_terminal_windows(&mut windows);
    Ok(windows)
}

pub async fn list_extension_windows() -> Result<Vec<WindowInfo>> {
    let json = call_extension_json("ListWindows").await?;
    let mut windows: Vec<WindowInfo> =
        serde_json::from_str(&json).context("Codex GNOME Shell extension returned invalid JSON")?;
    for window in &mut windows {
        window.backend = GNOME_SHELL_EXTENSION_BACKEND.to_string();
    }
    windows.sort_by_key(|window| window.window_id);
    enrich_terminal_windows(&mut windows);
    Ok(windows)
}

fn list_cosmic_helper_windows() -> Result<Vec<WindowInfo>> {
    let json = cosmic_helper::list_windows_json()?;
    let mut windows: Vec<WindowInfo> =
        serde_json::from_str(&json).context("COSMIC helper returned invalid list-windows JSON")?;
    for window in &mut windows {
        window.backend = COSMIC_WAYLAND_BACKEND.to_string();
    }
    windows.sort_by_key(|window| window.window_id);
    enrich_terminal_windows(&mut windows);
    Ok(windows)
}

fn focused_cosmic_helper_window() -> Result<Option<WindowInfo>> {
    let json = cosmic_helper::focused_window_json()?;
    let mut window: Option<WindowInfo> = serde_json::from_str(&json)
        .context("COSMIC helper returned invalid focused-window JSON")?;
    if let Some(window) = window.as_mut() {
        window.backend = COSMIC_WAYLAND_BACKEND.to_string();
    }
    Ok(window)
}

fn list_hyprland_windows() -> Result<Vec<WindowInfo>> {
    let output = Command::new("hyprctl")
        .args(["clients", "-j"])
        .output()
        .context("failed to run hyprctl clients -j")?;
    if !output.status.success() {
        bail!(
            "hyprctl clients -j failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }

    parse_hyprland_clients(&String::from_utf8_lossy(&output.stdout))
}

fn parse_hyprland_clients(json: &str) -> Result<Vec<WindowInfo>> {
    let clients: Vec<HyprlandClient> =
        serde_json::from_str(json).context("failed to parse hyprctl clients -j output")?;

    let mut windows = clients
        .into_iter()
        .filter(|client| client.mapped.unwrap_or(true))
        .map(WindowInfo::try_from)
        .collect::<Result<Vec<_>>>()?;
    windows.sort_by_key(|window| window.window_id);
    enrich_terminal_windows(&mut windows);
    Ok(windows)
}

async fn list_kwin_windows() -> Result<Vec<WindowInfo>> {
    let json = call_kwin_window_script().await?;
    let mut windows = parse_kwin_windows(&json)?;
    enrich_terminal_windows(&mut windows);
    Ok(windows)
}

pub async fn focused_window() -> Result<Option<WindowInfo>> {
    current_focused_window().await
}

pub async fn focus_window_target(target: &WindowTarget) -> Result<WindowFocusResult> {
    if !target.has_target() {
        bail!("Pass window_id, pid, app_id, wm_class, title, tty, terminal_pid, terminal_command, or terminal_cwd to target a window.");
    }

    let windows = list_windows().await?;
    let requested_window = resolve_window_target(&windows, target)?.clone();
    ensure_backend_can_focus_target(target, &requested_window)?;

    if requested_window.backend == HYPRLAND_BACKEND {
        activate_hyprland_window(requested_window.window_id)?;
    } else if requested_window.backend == KWIN_BACKEND {
        activate_kwin_window(requested_window.window_id).await?;
    } else if requested_window.backend == COSMIC_WAYLAND_BACKEND {
        let activation = cosmic_helper::activate_window(requested_window.window_id)?;
        if !activation.ok {
            bail!("COSMIC helper refused activation: {}", activation.detail);
        }
    } else if requested_window.backend == GNOME_SHELL_EXTENSION_BACKEND {
        activate_extension_window(requested_window.window_id).await?;
    } else {
        let app_id = requested_window
            .app_id
            .as_deref()
            .or(target.app_id.as_deref())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .context("GNOME Shell can only focus by app_id; the matched window has no app_id")?
            .to_string();
        focus_app(&app_id).await?;
    }

    let focused_window = wait_for_focused_window(&requested_window).await;
    let exact_window_focused = focused_window
        .as_ref()
        .is_some_and(|window| window.window_id == requested_window.window_id);
    let app_focused = focused_window
        .as_ref()
        .is_some_and(|window| same_optional_string(&window.app_id, &requested_window.app_id));

    Ok(WindowFocusResult {
        backend: requested_window.backend.clone(),
        requested_window,
        focused_window,
        exact_window_focused,
        app_focused,
        note: "Computer Use activated the requested window through the available window backend, then verified focus through a fresh window query."
            .to_string(),
    })
}

fn ensure_backend_can_focus_target(target: &WindowTarget, window: &WindowInfo) -> Result<()> {
    if target.requires_exact_focus()
        && window.backend != GNOME_SHELL_EXTENSION_BACKEND
        && window.backend != COSMIC_WAYLAND_BACKEND
        && window.backend != KWIN_BACKEND
        && window.backend != HYPRLAND_BACKEND
    {
        bail!(
            "Exact window targeting requires the Codex GNOME Shell extension, COSMIC helper, KWin, or Hyprland backend; {} can list the matched window but cannot activate a specific window safely.",
            window.backend
        );
    }
    Ok(())
}

async fn current_focused_window() -> Result<Option<WindowInfo>> {
    if let Ok(window) = focused_cosmic_helper_window() {
        if window.is_some() {
            return Ok(window);
        }
    }

    Ok(list_windows()
        .await?
        .into_iter()
        .find(|window| window.focused))
}

async fn wait_for_focused_window(requested_window: &WindowInfo) -> Option<WindowInfo> {
    let mut last_focused_window = None;
    for attempt in 0..FOCUS_VERIFY_ATTEMPTS {
        if let Ok(focused_window) = current_focused_window().await {
            if focused_window
                .as_ref()
                .is_some_and(|window| window.window_id == requested_window.window_id)
            {
                return focused_window;
            }
            if focused_window.is_some() {
                last_focused_window = focused_window;
            }
        }

        if attempt + 1 < FOCUS_VERIFY_ATTEMPTS {
            sleep(FOCUS_VERIFY_DELAY).await;
        }
    }
    last_focused_window
}

pub fn resolve_window_target<'a>(
    windows: &'a [WindowInfo],
    target: &WindowTarget,
) -> Result<&'a WindowInfo> {
    if let Some(window_id) = target.window_id {
        return windows
            .iter()
            .find(|window| window.window_id == window_id)
            .with_context(|| format!("No window matched window_id {window_id}."));
    }

    if target.has_terminal_target() {
        let matches = windows
            .iter()
            .filter(|window| window_matches_terminal_target(window, target))
            .filter(|window| target.pid.is_none_or(|pid| window.pid == Some(pid)))
            .filter(|window| optional_exact_match(&window.app_id, target.app_id.as_deref()))
            .filter(|window| optional_exact_match(&window.wm_class, target.wm_class.as_deref()))
            .filter(|window| optional_title_match(&window.title, target.title.as_deref()))
            .collect::<Vec<_>>();
        return unique_window_match(matches, "terminal target");
    }

    if let Some(pid) = target.pid {
        let matches = windows
            .iter()
            .filter(|window| window.pid == Some(pid))
            .collect::<Vec<_>>();
        return unique_window_match(matches, &format!("pid {pid}"));
    }

    if let Some(app_id) = normalized_target(target.app_id.as_deref()) {
        if let Some(window) = windows.iter().find(|window| {
            window
                .app_id
                .as_deref()
                .is_some_and(|value| value.eq_ignore_ascii_case(&app_id))
        }) {
            return Ok(window);
        }
        bail!("No window matched app_id {app_id}.");
    }

    if let Some(wm_class) = normalized_target(target.wm_class.as_deref()) {
        if let Some(window) = windows.iter().find(|window| {
            window
                .wm_class
                .as_deref()
                .is_some_and(|value| value.eq_ignore_ascii_case(&wm_class))
        }) {
            return Ok(window);
        }
        bail!("No window matched wm_class {wm_class}.");
    }

    if let Some(title) = normalized_target(target.title.as_deref()) {
        let title_lower = title.to_ascii_lowercase();
        if let Some(window) = windows.iter().find(|window| {
            window
                .title
                .as_deref()
                .is_some_and(|value| value.to_ascii_lowercase().contains(&title_lower))
        }) {
            return Ok(window);
        }
        bail!("No window title contained {title}.");
    }

    bail!("Pass window_id, pid, app_id, wm_class, title, tty, terminal_pid, terminal_command, or terminal_cwd to target a window.");
}

fn unique_window_match<'a>(
    matches: Vec<&'a WindowInfo>,
    description: &str,
) -> Result<&'a WindowInfo> {
    match matches.as_slice() {
        [window] => Ok(*window),
        [] => bail!("No window matched {description}."),
        windows => {
            let ids = windows
                .iter()
                .map(|window| window.window_id.to_string())
                .collect::<Vec<_>>()
                .join(", ");
            bail!(
                "{description} matched multiple windows ({ids}); add window_id, tty, title, or terminal_command to disambiguate."
            );
        }
    }
}

fn window_matches_terminal_target(window: &WindowInfo, target: &WindowTarget) -> bool {
    let Some(terminal) = &window.terminal else {
        return false;
    };

    if let Some(tty) = normalized_target(target.tty.as_deref()) {
        if !tty_matches(&terminal.tty, &tty) {
            return false;
        }
    }

    if let Some(pid) = target.terminal_pid {
        let active_pid = terminal.active_process.as_ref().map(|process| process.pid);
        if active_pid != Some(pid) && terminal.root_process.pid != pid {
            return false;
        }
    }

    if let Some(command) = normalized_target(target.terminal_command.as_deref()) {
        let command = command.to_ascii_lowercase();
        let active_matches = terminal
            .active_process
            .as_ref()
            .is_some_and(|process| terminal_process_matches_command(process, &command));
        if !active_matches && !terminal_process_matches_command(&terminal.root_process, &command) {
            return false;
        }
    }

    if let Some(cwd) = normalized_target(target.terminal_cwd.as_deref()) {
        let active_matches = terminal
            .active_process
            .as_ref()
            .is_some_and(|process| terminal_process_matches_cwd(process, &cwd));
        if !active_matches && !terminal_process_matches_cwd(&terminal.root_process, &cwd) {
            return false;
        }
    }

    true
}

fn terminal_process_matches_command(
    process: &crate::terminal::TerminalProcess,
    command_lower: &str,
) -> bool {
    process
        .command_name
        .to_ascii_lowercase()
        .contains(command_lower)
        || process
            .command_line
            .to_ascii_lowercase()
            .contains(command_lower)
}

fn terminal_process_matches_cwd(process: &crate::terminal::TerminalProcess, cwd: &str) -> bool {
    let requested = cwd.trim_end_matches('/');
    process.cwd.as_deref().is_some_and(|value| {
        let actual = value.trim_end_matches('/');
        actual == requested
            || (!requested.starts_with('/')
                && actual
                    .strip_suffix(requested)
                    .is_some_and(|prefix| prefix.ends_with('/')))
    })
}

fn tty_matches(actual: &str, requested: &str) -> bool {
    actual == requested
        || actual
            .strip_prefix("/dev/")
            .is_some_and(|value| value == requested)
        || actual
            .strip_prefix("/dev/pts/")
            .is_some_and(|value| value == requested)
}

fn optional_exact_match(actual: &Option<String>, requested: Option<&str>) -> bool {
    normalized_target(requested).is_none_or(|requested| {
        actual
            .as_deref()
            .is_some_and(|value| value.eq_ignore_ascii_case(&requested))
    })
}

fn optional_title_match(actual: &Option<String>, requested: Option<&str>) -> bool {
    normalized_target(requested).is_none_or(|requested| {
        let requested = requested.to_ascii_lowercase();
        actual
            .as_deref()
            .is_some_and(|value| value.to_ascii_lowercase().contains(&requested))
    })
}

pub fn window_permission_hint(error: &str) -> Option<String> {
    let lower = error.to_ascii_lowercase();
    if lower.contains("accessdenied")
        || lower.contains("access denied")
        || lower.contains("not allowed")
        || lower.contains("operation not permitted")
        || lower.contains("failed to connect to session bus")
    {
        Some(WINDOW_PERMISSION_HINT.to_string())
    } else {
        None
    }
}

async fn focus_app(app_id: &str) -> Result<()> {
    let connection = zbus::Connection::session()
        .await
        .context("failed to connect to session bus")?;
    let proxy = Proxy::new(
        &connection,
        "org.gnome.Shell",
        "/org/gnome/Shell",
        "org.gnome.Shell",
    )
    .await
    .context("failed to create GNOME Shell proxy")?;
    let _: () = proxy
        .call("FocusApp", &(app_id))
        .await
        .with_context(|| format!("GNOME Shell FocusApp failed for app_id {app_id}"))?;
    Ok(())
}

async fn call_extension_json(method: &str) -> Result<String> {
    hydrate_session_bus_env();

    let connection = zbus::Connection::session()
        .await
        .context("failed to connect to session bus")?;
    let proxy = Proxy::new(
        &connection,
        GNOME_SHELL_EXTENSION_SERVICE,
        GNOME_SHELL_EXTENSION_OBJECT_PATH,
        GNOME_SHELL_EXTENSION_SERVICE,
    )
    .await
    .context("failed to create Codex GNOME Shell extension proxy")?;
    let json: String = proxy
        .call(method, &())
        .await
        .with_context(|| format!("Codex GNOME Shell extension {method} call failed"))?;
    Ok(json)
}

async fn activate_extension_window(window_id: u64) -> Result<()> {
    hydrate_session_bus_env();

    let connection = zbus::Connection::session()
        .await
        .context("failed to connect to session bus")?;
    let proxy = Proxy::new(
        &connection,
        GNOME_SHELL_EXTENSION_SERVICE,
        GNOME_SHELL_EXTENSION_OBJECT_PATH,
        GNOME_SHELL_EXTENSION_SERVICE,
    )
    .await
    .context("failed to create Codex GNOME Shell extension proxy")?;
    let (ok, message): (bool, String) = proxy
        .call("ActivateWindow", &(window_id))
        .await
        .with_context(|| {
            format!("Codex GNOME Shell extension ActivateWindow failed for {window_id}")
        })?;
    if ok {
        Ok(())
    } else {
        bail!("Codex GNOME Shell extension refused activation: {message}");
    }
}

fn activate_hyprland_window(window_id: u64) -> Result<()> {
    let address = format!("address:0x{window_id:x}");
    let output = Command::new("hyprctl")
        .args(["dispatch", "focuswindow", &address])
        .output()
        .with_context(|| format!("failed to run hyprctl dispatch focuswindow {address}"))?;
    if output.status.success() {
        Ok(())
    } else {
        bail!(
            "hyprctl dispatch focuswindow {address} failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
}

async fn activate_kwin_window(window_id: u64) -> Result<()> {
    let uuid = kwin_uuid_for_window_id(window_id).await?.with_context(|| {
        format!("No KWin window matched window_id {window_id} during activation")
    })?;
    call_kwin_activate_script(&uuid).await
}

async fn kwin_uuid_for_window_id(window_id: u64) -> Result<Option<String>> {
    let json = call_kwin_window_script().await?;
    let snapshot = parse_kwin_snapshot(&json)?;
    Ok(snapshot.windows.into_iter().find_map(|window| {
        let uuid = window.kwin_uuid()?;
        (kwin_window_id_from_uuid(&uuid) == window_id).then_some(uuid)
    }))
}

#[derive(Debug, Deserialize)]
struct KwinScriptResult {
    #[serde(default)]
    ok: bool,
    error: Option<String>,
}

async fn call_kwin_activate_script(uuid: &str) -> Result<()> {
    let uuid = uuid.to_string();
    let json = call_kwin_script(|service_name, callback_object_path, plugin_name| {
        write_kwin_activate_script(service_name, callback_object_path, plugin_name, &uuid)
    })
    .await?;
    let result: KwinScriptResult =
        serde_json::from_str(&json).context("failed to parse KWin activation script output")?;

    if result.ok {
        Ok(())
    } else {
        bail!(
            "KWin activation script refused activation: {}",
            result.error.unwrap_or_else(|| "unknown error".to_string())
        );
    }
}

async fn call_kwin_window_script() -> Result<String> {
    call_kwin_script(write_kwin_window_script).await
}

async fn call_kwin_script<F>(write_script: F) -> Result<String>
where
    F: FnOnce(&str, &str, &str) -> Result<std::path::PathBuf>,
{
    hydrate_session_bus_env();

    let connection = zbus::Connection::session()
        .await
        .context("failed to connect to session bus")?;
    let unique_name = connection
        .unique_name()
        .context("session bus did not assign a unique name")?
        .to_string();
    let plugin_name = temporary_kwin_plugin_name();
    let callback_object_path = format!("{KWIN_CALLBACK_OBJECT_PATH_PREFIX}/{plugin_name}");
    let (sender, receiver) = mpsc::channel();
    connection
        .object_server()
        .at(callback_object_path.as_str(), KwinWindowCallback { sender })
        .await
        .context("failed to register temporary KWin callback object")?;

    let mut script_path = None;
    let mut loaded_script = false;
    let result = async {
        let path = write_script(&unique_name, &callback_object_path, &plugin_name)?;
        script_path = Some(path.clone());
        let scripting_proxy = Proxy::new(
            &connection,
            KWIN_SCRIPTING_SERVICE,
            KWIN_SCRIPTING_OBJECT_PATH,
            KWIN_SCRIPTING_INTERFACE,
        )
        .await
        .context("failed to create KWin scripting proxy")?;

        // Plasma 6 can return 0 here even when isScriptLoaded reports success;
        // the callback below is the authoritative completion signal.
        let _script_id: i32 = scripting_proxy
            .call(
                "loadScript",
                &(path.to_string_lossy().as_ref(), plugin_name.as_str()),
            )
            .await
            .context("KWin loadScript failed")?;
        loaded_script = true;

        let _: () = scripting_proxy
            .call("start", &())
            .await
            .context("KWin start failed after loading the temporary script")?;

        timeout(KWIN_SCRIPT_TIMEOUT, async move {
            loop {
                match receiver.try_recv() {
                    Ok(json) => return Ok(json),
                    Err(mpsc::TryRecvError::Disconnected) => {
                        bail!("KWin temporary script callback disconnected before returning data");
                    }
                    Err(mpsc::TryRecvError::Empty) => sleep(Duration::from_millis(20)).await,
                }
            }
        })
        .await
        .context("KWin temporary script did not return data before timeout")?
    }
    .await;

    if loaded_script {
        if let Ok(scripting_proxy) = Proxy::new(
            &connection,
            KWIN_SCRIPTING_SERVICE,
            KWIN_SCRIPTING_OBJECT_PATH,
            KWIN_SCRIPTING_INTERFACE,
        )
        .await
        {
            let _: Result<bool, _> = scripting_proxy
                .call("unloadScript", &(plugin_name.as_str()))
                .await;
        }
    }
    let _: Result<bool, _> = connection
        .object_server()
        .remove::<KwinWindowCallback, _>(callback_object_path.as_str())
        .await;
    if let Some(script_path) = script_path {
        let _ = fs::remove_file(script_path);
    }

    result
}

struct KwinWindowCallback {
    sender: mpsc::Sender<String>,
}

#[zbus::interface(name = "com.openai.Codex.KWinWindowQuery")]
impl KwinWindowCallback {
    fn receive_windows(&self, json: &str) -> zbus::fdo::Result<()> {
        self.sender
            .send(json.to_string())
            .map_err(|error| zbus::fdo::Error::Failed(error.to_string()))
    }

    fn receive_result(&self, json: &str) -> zbus::fdo::Result<()> {
        self.sender
            .send(json.to_string())
            .map_err(|error| zbus::fdo::Error::Failed(error.to_string()))
    }
}

fn temporary_kwin_plugin_name() -> String {
    let pid = std::process::id();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    format!("codex_kwin_window_query_{pid}_{nanos}")
}

fn write_kwin_window_script(
    service_name: &str,
    callback_object_path: &str,
    plugin_name: &str,
) -> Result<std::path::PathBuf> {
    let script = kwin_window_script_source(service_name, callback_object_path, plugin_name)?;
    write_kwin_script_file(plugin_name, &script)
}

fn kwin_window_script_source(
    service_name: &str,
    callback_object_path: &str,
    plugin_name: &str,
) -> Result<String> {
    let service_name = serde_json::to_string(service_name)?;
    let object_path = serde_json::to_string(callback_object_path)?;
    let interface = serde_json::to_string(KWIN_CALLBACK_INTERFACE)?;
    let plugin_name_json = serde_json::to_string(plugin_name)?;
    Ok(format!(
        r#"(function() {{
    var serviceName = {service_name};
    var objectPath = {object_path};
    var iface = {interface};
    var pluginName = {plugin_name_json};

    function read(obj, key) {{
        try {{
            if (obj === null || obj === undefined) {{
                return null;
            }}
            var value = obj[key];
            if (typeof value === "function") {{
                return null;
            }}
            return serialize(value);
        }} catch (error) {{
            return null;
        }}
    }}

    function serialize(value) {{
        if (value === null || value === undefined) {{
            return null;
        }}
        if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {{
            return value;
        }}
        if (Array.isArray(value)) {{
            return value.map(serialize);
        }}
        try {{
            if (typeof value.toString === "function") {{
                return value.toString();
            }}
        }} catch (error) {{}}
        return null;
    }}

    function geometry(window) {{
        var frame = null;
        try {{
            frame = window.frameGeometry;
        }} catch (error) {{}}
        var x = read(window, "x");
        var y = read(window, "y");
        var width = read(window, "width");
        var height = read(window, "height");
        return {{
            x: x !== null ? x : read(frame, "x"),
            y: y !== null ? y : read(frame, "y"),
            width: width !== null ? width : read(frame, "width"),
            height: height !== null ? height : read(frame, "height")
        }};
    }}

    function firstDesktop(window) {{
        var desktops = read(window, "desktops");
        if (!Array.isArray(desktops) || desktops.length === 0) {{
            return null;
        }}
        var first = desktops[0];
        var parsed = parseInt(first, 10);
        return isFinite(parsed) ? parsed : null;
    }}

    function clientType(window) {{
        if (read(window, "waylandClient")) {{
            return "wayland";
        }}
        if (read(window, "x11Client")) {{
            return "x11";
        }}
        return null;
    }}

    var activeWindow = null;
    try {{
        activeWindow = workspace.activeWindow;
    }} catch (error) {{}}
    var windows = workspace.windowList().map(function(window) {{
        var geo = geometry(window);
        return {{
            uuid: read(window, "uuid"),
            internalId: read(window, "internalId"),
            caption: read(window, "caption"),
            desktopFile: read(window, "desktopFile"),
            resourceClass: read(window, "resourceClass"),
            resourceName: read(window, "resourceName"),
            windowClass: read(window, "windowClass"),
            pid: read(window, "pid"),
            x: geo.x,
            y: geo.y,
            width: geo.width,
            height: geo.height,
            workspace: firstDesktop(window),
            minimized: read(window, "minimized"),
            active: read(window, "active") || window === activeWindow,
            clientType: clientType(window),
            normalWindow: read(window, "normalWindow"),
            desktopWindow: read(window, "desktopWindow"),
            skipTaskbar: read(window, "skipTaskbar"),
            dock: read(window, "dock")
        }};
    }});

    callDBus(serviceName, objectPath, iface, "ReceiveWindows", JSON.stringify({{
        backend: "kwin",
        pluginName: pluginName,
        windows: windows
    }}));
}})();
"#
    ))
}

fn write_kwin_activate_script(
    service_name: &str,
    callback_object_path: &str,
    plugin_name: &str,
    uuid: &str,
) -> Result<std::path::PathBuf> {
    let script =
        kwin_activate_script_source(service_name, callback_object_path, plugin_name, uuid)?;
    write_kwin_script_file(plugin_name, &script)
}

fn kwin_activate_script_source(
    service_name: &str,
    callback_object_path: &str,
    plugin_name: &str,
    uuid: &str,
) -> Result<String> {
    let target_uuid = normalize_kwin_uuid(uuid).context("KWin activation requires a uuid")?;
    let service_name = serde_json::to_string(service_name)?;
    let object_path = serde_json::to_string(callback_object_path)?;
    let interface = serde_json::to_string(KWIN_CALLBACK_INTERFACE)?;
    let plugin_name_json = serde_json::to_string(plugin_name)?;
    let target_uuid = serde_json::to_string(&target_uuid)?;

    Ok(format!(
        r#"(function() {{
    var serviceName = {service_name};
    var objectPath = {object_path};
    var iface = {interface};
    var pluginName = {plugin_name_json};
    var targetUuid = {target_uuid};

    function send(payload) {{
        payload.backend = "kwin";
        payload.pluginName = pluginName;
        callDBus(serviceName, objectPath, iface, "ReceiveResult", JSON.stringify(payload));
    }}

    function serialize(value) {{
        if (value === null || value === undefined) {{
            return null;
        }}
        if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {{
            return value;
        }}
        try {{
            if (typeof value.toString === "function") {{
                return value.toString();
            }}
        }} catch (error) {{}}
        return null;
    }}

    function read(obj, key) {{
        try {{
            if (obj === null || obj === undefined) {{
                return null;
            }}
            var value = obj[key];
            if (typeof value === "function") {{
                return null;
            }}
            return serialize(value);
        }} catch (error) {{
            return null;
        }}
    }}

    function normalizeUuid(value) {{
        var text = serialize(value);
        if (text === null || text === undefined) {{
            return null;
        }}
        text = String(text).trim().toLowerCase();
        if (text.charAt(0) === "{{" && text.charAt(text.length - 1) === "}}") {{
            text = text.substring(1, text.length - 1);
        }}
        return text.length > 0 ? text : null;
    }}

    function windowUuid(window) {{
        return normalizeUuid(read(window, "uuid")) || normalizeUuid(read(window, "internalId"));
    }}

    function listWindows() {{
        try {{
            if (typeof workspace.windowList === "function") {{
                return workspace.windowList();
            }}
        }} catch (error) {{}}
        try {{
            if (workspace.stackingOrder && typeof workspace.stackingOrder.length === "number") {{
                return workspace.stackingOrder;
            }}
        }} catch (error) {{}}
        return [];
    }}

    function activateDesktop(window) {{
        var desktops = null;
        try {{
            desktops = window.desktops;
        }} catch (error) {{}}
        if (desktops && desktops.length > 0) {{
            try {{
                workspace.currentDesktop = desktops[0];
            }} catch (error) {{}}
        }}
    }}

    try {{
        var targetWindow = null;
        var windows = listWindows();
        for (var i = 0; i < windows.length; i++) {{
            if (windowUuid(windows[i]) === targetUuid) {{
                targetWindow = windows[i];
                break;
            }}
        }}

        if (!targetWindow) {{
            throw new Error("window not found: " + targetUuid);
        }}

        try {{
            targetWindow.minimized = false;
        }} catch (error) {{}}
        activateDesktop(targetWindow);

        var activated = false;
        var activationError = null;
        try {{
            workspace.activeWindow = targetWindow;
            activated = true;
        }} catch (error) {{
            activationError = error;
        }}
        if (!activated) {{
            try {{
                workspace.activeClient = targetWindow;
                activated = true;
            }} catch (error) {{
                activationError = error;
            }}
        }}
        if (!activated) {{
            try {{
                if (typeof targetWindow.activate === "function") {{
                    targetWindow.activate();
                    activated = true;
                }}
            }} catch (error) {{
                activationError = error;
            }}
        }}
        if (!activated) {{
            throw activationError || new Error("workspace refused activeWindow assignment");
        }}

        try {{
            if (typeof workspace.raiseWindow === "function") {{
                workspace.raiseWindow(targetWindow);
            }}
        }} catch (error) {{}}

        send({{
            ok: true,
            uuid: windowUuid(targetWindow)
        }});
    }} catch (error) {{
        send({{
            ok: false,
            error: String(error && error.message ? error.message : error)
        }});
    }}
}})();
"#
    ))
}

fn write_kwin_script_file(plugin_name: &str, script: &str) -> Result<std::path::PathBuf> {
    for attempt in 0..4 {
        let filename = if attempt == 0 {
            format!("{plugin_name}.js")
        } else {
            format!("{plugin_name}-{attempt}.js")
        };
        let path = std::env::temp_dir().join(filename);
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(mut file) => {
                if let Err(error) = file.write_all(script.as_bytes()) {
                    let _ = fs::remove_file(&path);
                    return Err(error).with_context(|| {
                        format!("failed to write temporary KWin script {}", path.display())
                    });
                }
                return Ok(path);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("failed to create temporary KWin script {}", path.display())
                });
            }
        }
    }

    bail!("failed to create a unique temporary KWin script path for {plugin_name}")
}

fn parse_kwin_windows(json: &str) -> Result<Vec<WindowInfo>> {
    let snapshot = parse_kwin_snapshot(json)?;
    let mut windows = snapshot
        .windows
        .into_iter()
        .filter(|window| !json_value_as_bool(window.desktop_window.as_ref()).unwrap_or(false))
        .filter(|window| !json_value_as_bool(window.dock.as_ref()).unwrap_or(false))
        .filter(|window| !json_value_as_bool(window.skip_taskbar.as_ref()).unwrap_or(false))
        .filter(|window| json_value_as_bool(window.normal_window.as_ref()).unwrap_or(true))
        .map(WindowInfo::try_from)
        .collect::<Result<Vec<_>>>()?;
    windows.sort_by_key(|window| window.window_id);
    Ok(windows)
}

fn parse_kwin_snapshot(json: &str) -> Result<KwinWindowSnapshot> {
    serde_json::from_str(json).context("failed to parse KWin temporary script output")
}

#[derive(Debug, Deserialize)]
struct KwinWindowSnapshot {
    windows: Vec<KwinRawWindow>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct KwinRawWindow {
    uuid: Option<String>,
    internal_id: Option<String>,
    caption: Option<String>,
    desktop_file: Option<String>,
    resource_class: Option<String>,
    resource_name: Option<String>,
    window_class: Option<String>,
    pid: Option<serde_json::Value>,
    x: Option<serde_json::Value>,
    y: Option<serde_json::Value>,
    width: Option<serde_json::Value>,
    height: Option<serde_json::Value>,
    workspace: Option<serde_json::Value>,
    minimized: Option<serde_json::Value>,
    active: Option<serde_json::Value>,
    client_type: Option<String>,
    normal_window: Option<serde_json::Value>,
    desktop_window: Option<serde_json::Value>,
    skip_taskbar: Option<serde_json::Value>,
    dock: Option<serde_json::Value>,
}

impl KwinRawWindow {
    fn kwin_uuid(&self) -> Option<String> {
        self.uuid
            .as_deref()
            .or(self.internal_id.as_deref())
            .and_then(normalize_kwin_uuid)
    }
}

impl TryFrom<KwinRawWindow> for WindowInfo {
    type Error = anyhow::Error;

    fn try_from(window: KwinRawWindow) -> Result<Self> {
        let uuid = window
            .kwin_uuid()
            .context("KWin window did not include uuid or internalId")?;
        let width = json_value_as_u32(window.width.as_ref());
        let height = json_value_as_u32(window.height.as_ref());
        let bounds = width.zip(height).map(|(width, height)| WindowBounds {
            x: json_value_as_i32(window.x.as_ref()),
            y: json_value_as_i32(window.y.as_ref()),
            width,
            height,
        });
        let app_id = clean_string(window.desktop_file.as_deref())
            .or_else(|| clean_string(window.resource_class.as_deref()));
        let wm_class = clean_string(window.resource_class.as_deref())
            .or_else(|| clean_string(window.window_class.as_deref()))
            .or_else(|| clean_string(window.resource_name.as_deref()));
        let client_type = clean_string(window.client_type.as_deref());

        Ok(WindowInfo {
            window_id: kwin_window_id_from_uuid(&uuid),
            title: clean_string(window.caption.as_deref()),
            app_id,
            wm_class,
            pid: json_value_as_u32(window.pid.as_ref()),
            bounds,
            workspace: json_value_as_i32(window.workspace.as_ref()),
            focused: json_value_as_bool(window.active.as_ref()).unwrap_or(false),
            hidden: json_value_as_bool(window.minimized.as_ref()).unwrap_or(false),
            client_type,
            backend: KWIN_BACKEND.to_string(),
            terminal: None,
        })
    }
}

fn kwin_window_id_from_uuid(uuid: &str) -> u64 {
    let normalized = normalize_kwin_uuid(uuid).unwrap_or_else(|| uuid.trim().to_ascii_lowercase());
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in normalized.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn normalize_kwin_uuid(uuid: &str) -> Option<String> {
    let value = uuid
        .trim()
        .trim_start_matches('{')
        .trim_end_matches('}')
        .trim()
        .to_ascii_lowercase();
    (!value.is_empty()).then_some(value)
}

fn clean_string(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty() && *value != "null")
        .map(ToOwned::to_owned)
}

fn json_value_as_bool(value: Option<&serde_json::Value>) -> Option<bool> {
    match value? {
        serde_json::Value::Bool(value) => Some(*value),
        serde_json::Value::String(value) => match value.to_ascii_lowercase().as_str() {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        },
        _ => None,
    }
}

fn json_value_as_u32(value: Option<&serde_json::Value>) -> Option<u32> {
    let value = json_value_as_f64(value)?;
    if !value.is_finite() || value < 0.0 || value > u32::MAX as f64 {
        return None;
    }
    Some(value.round() as u32)
}

fn json_value_as_i32(value: Option<&serde_json::Value>) -> Option<i32> {
    let value = json_value_as_f64(value)?;
    if !value.is_finite() || value < i32::MIN as f64 || value > i32::MAX as f64 {
        return None;
    }
    Some(value.round() as i32)
}

fn json_value_as_f64(value: Option<&serde_json::Value>) -> Option<f64> {
    match value? {
        serde_json::Value::Number(value) => value.as_f64(),
        serde_json::Value::String(value) => value.parse::<f64>().ok(),
        _ => None,
    }
}

#[derive(Debug, Deserialize)]
struct HyprlandClient {
    address: String,
    mapped: Option<bool>,
    hidden: Option<bool>,
    at: Option<[i32; 2]>,
    size: Option<[u32; 2]>,
    workspace: Option<HyprlandWorkspace>,
    #[serde(rename = "class")]
    class_name: Option<String>,
    title: Option<String>,
    pid: Option<i64>,
    xwayland: Option<bool>,
    #[serde(rename = "focusHistoryID")]
    focus_history_id: Option<i32>,
}

#[derive(Debug, Deserialize)]
struct HyprlandWorkspace {
    id: Option<i32>,
}

impl TryFrom<HyprlandClient> for WindowInfo {
    type Error = anyhow::Error;

    fn try_from(client: HyprlandClient) -> Result<Self> {
        let window_id = parse_hyprland_address(&client.address)?;
        let bounds = client.size.map(|[width, height]| WindowBounds {
            x: client.at.map(|[x, _]| x),
            y: client.at.map(|[_, y]| y),
            width,
            height,
        });
        let client_type = client.xwayland.map(|xwayland| {
            if xwayland {
                "x11".to_string()
            } else {
                "wayland".to_string()
            }
        });

        Ok(WindowInfo {
            window_id,
            title: client.title,
            app_id: client.class_name.clone(),
            wm_class: client.class_name,
            pid: client.pid.and_then(|pid| u32::try_from(pid).ok()),
            bounds,
            workspace: client.workspace.and_then(|workspace| workspace.id),
            focused: client.focus_history_id == Some(0),
            hidden: client.hidden.unwrap_or(false),
            client_type,
            backend: HYPRLAND_BACKEND.to_string(),
            terminal: None,
        })
    }
}

fn parse_hyprland_address(address: &str) -> Result<u64> {
    let hex = address
        .trim()
        .strip_prefix("0x")
        .context("Hyprland window address did not start with 0x")?;
    u64::from_str_radix(hex, 16)
        .with_context(|| format!("failed to parse Hyprland window address {address}"))
}

fn window_from_properties(window_id: u64, properties: &HashMap<String, OwnedValue>) -> WindowInfo {
    let width = get_u32(properties, "width");
    let height = get_u32(properties, "height");
    let bounds = width.zip(height).map(|(width, height)| WindowBounds {
        x: get_i32(properties, "x"),
        y: get_i32(properties, "y"),
        width,
        height,
    });

    WindowInfo {
        window_id,
        title: get_string(properties, "title"),
        app_id: get_string(properties, "app-id"),
        wm_class: get_string(properties, "wm-class"),
        pid: get_u32(properties, "pid"),
        bounds,
        workspace: get_i32(properties, "workspace"),
        focused: get_bool(properties, "has-focus").unwrap_or(false),
        hidden: get_bool(properties, "is-hidden").unwrap_or(false),
        client_type: get_u32(properties, "client-type").map(client_type_name),
        backend: GNOME_SHELL_INTROSPECT_BACKEND.to_string(),
        terminal: None,
    }
}

fn get_string(properties: &HashMap<String, OwnedValue>, key: &str) -> Option<String> {
    properties
        .get(key)
        .and_then(|value| <&str>::try_from(value).ok())
        .map(ToOwned::to_owned)
}

fn get_bool(properties: &HashMap<String, OwnedValue>, key: &str) -> Option<bool> {
    properties
        .get(key)
        .and_then(|value| bool::try_from(value).ok())
}

fn get_u32(properties: &HashMap<String, OwnedValue>, key: &str) -> Option<u32> {
    properties
        .get(key)
        .and_then(|value| u32::try_from(value).ok())
}

fn get_i32(properties: &HashMap<String, OwnedValue>, key: &str) -> Option<i32> {
    properties.get(key).and_then(|value| {
        i32::try_from(value).ok().or_else(|| {
            u32::try_from(value)
                .ok()
                .and_then(|value| value.try_into().ok())
        })
    })
}

fn client_type_name(value: u32) -> String {
    match value {
        0 => "wayland",
        1 => "x11",
        _ => "unknown",
    }
    .to_string()
}

fn normalized_target(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn same_optional_string(left: &Option<String>, right: &Option<String>) -> bool {
    match (left.as_deref(), right.as_deref()) {
        (Some(left), Some(right)) => left.eq_ignore_ascii_case(right),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::{TerminalProcess, TerminalWindowContext};
    use zbus::zvariant::Value;

    fn owned_value(value: Value<'_>) -> OwnedValue {
        OwnedValue::try_from(value).unwrap()
    }

    fn window(window_id: u64, title: &str, app_id: &str, wm_class: &str) -> WindowInfo {
        WindowInfo {
            window_id,
            title: Some(title.to_string()),
            app_id: Some(app_id.to_string()),
            wm_class: Some(wm_class.to_string()),
            pid: Some(window_id as u32 + 1000),
            bounds: Some(WindowBounds {
                x: None,
                y: None,
                width: 800,
                height: 600,
            }),
            workspace: None,
            focused: false,
            hidden: false,
            client_type: Some("wayland".to_string()),
            backend: GNOME_SHELL_INTROSPECT_BACKEND.to_string(),
            terminal: None,
        }
    }

    fn terminal_window(
        window_id: u64,
        title: &str,
        tty: &str,
        active_pid: u32,
        active_command: &str,
        active_cwd: &str,
    ) -> WindowInfo {
        let mut window = window(
            window_id,
            title,
            "com.mitchellh.ghostty.desktop",
            "com.mitchellh.ghostty",
        );
        window.terminal = Some(TerminalWindowContext {
            tty: tty.to_string(),
            root_process: TerminalProcess {
                pid: active_pid - 1,
                command_name: "zsh".to_string(),
                command_line: "zsh --login".to_string(),
                cwd: Some("/home/avifenesh".to_string()),
            },
            active_process: Some(TerminalProcess {
                pid: active_pid,
                command_name: active_command.to_string(),
                command_line: format!("{active_command} resume 123"),
                cwd: Some(active_cwd.to_string()),
            }),
            process_count: 2,
            confidence: "heuristic".to_string(),
            match_reason: "test".to_string(),
        });
        window
    }

    #[test]
    fn target_reports_when_any_selector_is_present() {
        assert!(!WindowTarget::default().has_target());
        assert!(WindowTarget {
            title: Some("Ghostty".to_string()),
            ..Default::default()
        }
        .has_target());
        assert!(WindowTarget {
            tty: Some("/dev/pts/1".to_string()),
            ..Default::default()
        }
        .has_target());
    }

    #[test]
    fn title_pid_and_window_id_targets_require_exact_focus() {
        assert!(WindowTarget {
            title: Some("Ghostty".to_string()),
            ..Default::default()
        }
        .requires_exact_focus());
        assert!(WindowTarget {
            pid: Some(123),
            ..Default::default()
        }
        .requires_exact_focus());
        assert!(WindowTarget {
            window_id: Some(123),
            ..Default::default()
        }
        .requires_exact_focus());
        assert!(WindowTarget {
            terminal_command: Some("codex".to_string()),
            ..Default::default()
        }
        .requires_exact_focus());
        assert!(!WindowTarget {
            app_id: Some("com.mitchellh.ghostty.desktop".to_string()),
            ..Default::default()
        }
        .requires_exact_focus());
    }

    #[test]
    fn exact_targets_require_extension_activation_backend() {
        let window = window(
            2,
            "Ghostty",
            "com.mitchellh.ghostty.desktop",
            "com.mitchellh.ghostty",
        );

        let error = ensure_backend_can_focus_target(
            &WindowTarget {
                terminal_command: Some("codex".to_string()),
                ..Default::default()
            },
            &window,
        )
        .unwrap_err()
        .to_string();

        assert!(error.contains("Exact window targeting requires"));
    }

    #[test]
    fn app_targets_can_use_app_level_focus_backend() {
        let window = window(
            2,
            "Ghostty",
            "com.mitchellh.ghostty.desktop",
            "com.mitchellh.ghostty",
        );

        ensure_backend_can_focus_target(
            &WindowTarget {
                app_id: Some("com.mitchellh.ghostty.desktop".to_string()),
                ..Default::default()
            },
            &window,
        )
        .unwrap();
    }

    #[test]
    fn cosmic_backend_can_exact_focus_targets() {
        let mut window = window(2, "Codex", "codex-desktop", "codex-desktop");
        window.backend = COSMIC_WAYLAND_BACKEND.to_string();

        ensure_backend_can_focus_target(
            &WindowTarget {
                title: Some("Codex".to_string()),
                ..Default::default()
            },
            &window,
        )
        .unwrap();
    }

    #[test]
    fn resolves_target_by_window_id_first() {
        let windows = vec![
            window(1, "Codex", "codex.desktop", "Codex"),
            window(2, "Ghostty", "com.mitchellh.ghostty.desktop", "Ghostty"),
        ];

        let matched = resolve_window_target(
            &windows,
            &WindowTarget {
                window_id: Some(2),
                title: Some("Codex".to_string()),
                ..Default::default()
            },
        )
        .unwrap();

        assert_eq!(matched.window_id, 2);
    }

    #[test]
    fn pid_target_reports_ambiguous_matches() {
        let mut first = window(1, "Ghostty One", "com.mitchellh.ghostty.desktop", "Ghostty");
        let mut second = window(2, "Ghostty Two", "com.mitchellh.ghostty.desktop", "Ghostty");
        first.pid = Some(300);
        second.pid = Some(300);

        let error = resolve_window_target(
            &[first, second],
            &WindowTarget {
                pid: Some(300),
                ..Default::default()
            },
        )
        .unwrap_err()
        .to_string();

        assert!(error.contains("pid 300 matched multiple windows"));
    }

    #[test]
    fn resolves_target_by_title_substring_case_insensitive() {
        let windows = vec![window(
            2,
            "avifenesh@host: ~/projects/codex",
            "com.mitchellh.ghostty.desktop",
            "Ghostty",
        )];

        let matched = resolve_window_target(
            &windows,
            &WindowTarget {
                title: Some("PROJECTS/CODEX".to_string()),
                ..Default::default()
            },
        )
        .unwrap();

        assert_eq!(matched.window_id, 2);
    }

    #[test]
    fn resolves_terminal_target_by_tty() {
        let windows = vec![
            terminal_window(1, "Claude", "/dev/pts/0", 101, "claude", "/tmp"),
            terminal_window(2, "Codex", "/dev/pts/1", 201, "codex", "/home/avifenesh"),
        ];

        let matched = resolve_window_target(
            &windows,
            &WindowTarget {
                tty: Some("pts/1".to_string()),
                ..Default::default()
            },
        )
        .unwrap();

        assert_eq!(matched.window_id, 2);
    }

    #[test]
    fn resolves_terminal_target_by_active_command() {
        let windows = vec![
            terminal_window(1, "Claude", "/dev/pts/0", 101, "claude", "/tmp"),
            terminal_window(2, "Codex", "/dev/pts/1", 201, "codex", "/home/avifenesh"),
        ];

        let matched = resolve_window_target(
            &windows,
            &WindowTarget {
                terminal_command: Some("codex resume".to_string()),
                ..Default::default()
            },
        )
        .unwrap();

        assert_eq!(matched.window_id, 2);
    }

    #[test]
    fn resolves_terminal_target_by_cwd_suffix() {
        let windows = vec![
            terminal_window(1, "Home", "/dev/pts/0", 101, "zsh", "/home/avifenesh"),
            terminal_window(
                2,
                "Project",
                "/dev/pts/1",
                201,
                "codex",
                "/home/avifenesh/projects/codex-desktop-linux",
            ),
        ];

        let matched = resolve_window_target(
            &windows,
            &WindowTarget {
                terminal_cwd: Some("projects/codex-desktop-linux".to_string()),
                ..Default::default()
            },
        )
        .unwrap();

        assert_eq!(matched.window_id, 2);
    }

    #[test]
    fn terminal_cwd_does_not_match_arbitrary_substrings() {
        let windows = vec![terminal_window(
            1,
            "Project",
            "/dev/pts/1",
            201,
            "codex",
            "/home/avifenesh/projects/codex-desktop-linux",
        )];

        let error = resolve_window_target(
            &windows,
            &WindowTarget {
                terminal_cwd: Some("fenesh/proj".to_string()),
                ..Default::default()
            },
        )
        .unwrap_err()
        .to_string();

        assert!(error.contains("No window matched terminal target"));
    }

    #[test]
    fn terminal_target_reports_ambiguous_matches() {
        let windows = vec![
            terminal_window(1, "One", "/dev/pts/0", 101, "zsh", "/home/avifenesh"),
            terminal_window(2, "Two", "/dev/pts/1", 201, "zsh", "/home/avifenesh"),
        ];

        let error = resolve_window_target(
            &windows,
            &WindowTarget {
                terminal_command: Some("zsh".to_string()),
                ..Default::default()
            },
        )
        .unwrap_err()
        .to_string();

        assert!(error.contains("matched multiple windows"));
    }

    #[test]
    fn maps_access_denied_errors_to_permission_hint() {
        let hint = window_permission_hint(
            "GDBus.Error:org.freedesktop.DBus.Error.AccessDenied: GetWindows is not allowed",
        );

        assert_eq!(hint.as_deref(), Some(WINDOW_PERMISSION_HINT));
    }

    #[test]
    fn parses_hyprland_clients_as_window_info() {
        let clients_json = r#"[
          {
            "address": "0x559952b6db60",
            "mapped": true,
            "hidden": false,
            "at": [10, 48],
            "size": [1900, 1022],
            "workspace": {"id": 2, "name": "2"},
            "class": "brave-browser",
            "title": "Repo - Brave",
            "pid": 24134,
            "xwayland": false,
            "focusHistoryID": 1
          },
          {
            "address": "0x559952be43d0",
            "mapped": true,
            "hidden": false,
            "at": [10, 48],
            "size": [1900, 1022],
            "workspace": {"id": 1, "name": "1"},
            "class": "codex-desktop",
            "title": "Codex",
            "pid": 68986,
            "xwayland": false,
            "focusHistoryID": 0
          },
          {
            "address": "0x559952c99aa0",
            "mapped": true,
            "hidden": false,
            "at": [0, 0],
            "size": [400, 300],
            "workspace": {"id": 3, "name": "3"},
            "class": "transient",
            "title": "Transient",
            "pid": -1,
            "xwayland": false,
            "focusHistoryID": 2
          }
        ]"#;

        let windows = parse_hyprland_clients(clients_json).unwrap();

        assert_eq!(windows.len(), 3);
        assert_eq!(windows[0].window_id, 0x559952b6db60);
        assert_eq!(windows[0].app_id.as_deref(), Some("brave-browser"));
        assert_eq!(windows[0].wm_class.as_deref(), Some("brave-browser"));
        assert_eq!(windows[0].title.as_deref(), Some("Repo - Brave"));
        assert_eq!(windows[0].pid, Some(24134));
        assert_eq!(windows[0].bounds.as_ref().unwrap().x, Some(10));
        assert_eq!(windows[0].bounds.as_ref().unwrap().height, 1022);
        assert_eq!(windows[0].workspace, Some(2));
        assert!(!windows[0].focused);
        assert_eq!(windows[0].client_type.as_deref(), Some("wayland"));
        assert_eq!(windows[0].backend, HYPRLAND_BACKEND);
        assert!(windows[1].focused);
        assert_eq!(windows[2].pid, None);
    }

    #[test]
    fn parses_kwin_windows_as_window_info() {
        let uuid = "b4dfacf8-a559-43c9-8b1f-ecd5cfd78359";
        let windows_json = r#"{
          "backend": "kwin",
          "windows": [
            {
              "uuid": "{b4dfacf8-a559-43c9-8b1f-ecd5cfd78359}",
              "caption": "Codex",
              "desktopFile": "codex-desktop",
              "resourceClass": "codex-desktop",
              "resourceName": "codex",
              "pid": 68986,
              "x": 10,
              "y": 48,
              "width": 1200,
              "height": 800,
              "workspace": 1,
              "minimized": false,
              "active": true,
              "clientType": "wayland",
              "normalWindow": true,
              "desktopWindow": false,
              "dock": false
            },
            {
              "uuid": "{11111111-2222-3333-4444-555555555555}",
              "caption": "Desktop",
              "desktopWindow": true
            }
          ]
        }"#;

        let windows = parse_kwin_windows(windows_json).unwrap();

        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].window_id, kwin_window_id_from_uuid(uuid));
        assert_eq!(windows[0].title.as_deref(), Some("Codex"));
        assert_eq!(windows[0].app_id.as_deref(), Some("codex-desktop"));
        assert_eq!(windows[0].wm_class.as_deref(), Some("codex-desktop"));
        assert_eq!(windows[0].pid, Some(68986));
        assert_eq!(windows[0].bounds.as_ref().unwrap().x, Some(10));
        assert_eq!(windows[0].bounds.as_ref().unwrap().height, 800);
        assert_eq!(windows[0].workspace, Some(1));
        assert!(windows[0].focused);
        assert!(!windows[0].hidden);
        assert_eq!(windows[0].client_type.as_deref(), Some("wayland"));
        assert_eq!(windows[0].backend, KWIN_BACKEND);
    }

    #[test]
    fn kwin_window_ids_are_stable_across_uuid_formats() {
        let bare = "b4dfacf8-a559-43c9-8b1f-ecd5cfd78359";
        let braced_upper = "{B4DFACF8-A559-43C9-8B1F-ECD5CFD78359}";

        assert_eq!(
            kwin_window_id_from_uuid(bare),
            kwin_window_id_from_uuid(braced_upper)
        );
    }

    #[test]
    fn kwin_activation_script_focuses_window_directly() {
        let script = kwin_activate_script_source(
            ":1.234",
            "/com/openai/Codex/KWinWindowQuery/test",
            "codex_kwin_window_query_test",
            "{B4DFACF8-A559-43C9-8B1F-ECD5CFD78359}",
        )
        .unwrap();

        assert!(script.contains(r#"var targetUuid = "b4dfacf8-a559-43c9-8b1f-ecd5cfd78359";"#));
        assert!(script.contains("targetWindow.minimized = false;"));
        assert!(script.contains("workspace.activeWindow = targetWindow;"));
        assert!(script.contains(r#""ReceiveResult""#));
        assert!(!script.contains("WindowsRunner"));
    }

    #[test]
    fn hyprland_backend_can_exact_focus_targets() {
        let mut window = window(2, "Codex", "codex-desktop", "codex-desktop");
        window.backend = HYPRLAND_BACKEND.to_string();

        ensure_backend_can_focus_target(
            &WindowTarget {
                title: Some("Codex".to_string()),
                ..Default::default()
            },
            &window,
        )
        .unwrap();
    }

    #[test]
    fn kwin_backend_can_exact_focus_targets() {
        let mut window = window(2, "Codex", "codex-desktop", "codex-desktop");
        window.backend = KWIN_BACKEND.to_string();

        ensure_backend_can_focus_target(
            &WindowTarget {
                title: Some("Codex".to_string()),
                ..Default::default()
            },
            &window,
        )
        .unwrap();
    }

    #[test]
    fn extracts_known_window_properties() {
        let properties = HashMap::from([
            ("title".to_string(), owned_value(Value::from("Ghostty"))),
            (
                "app-id".to_string(),
                owned_value(Value::from("com.mitchellh.ghostty.desktop")),
            ),
            ("wm-class".to_string(), owned_value(Value::from("Ghostty"))),
            ("client-type".to_string(), owned_value(Value::from(0_u32))),
            ("is-hidden".to_string(), owned_value(Value::from(false))),
            ("has-focus".to_string(), owned_value(Value::from(true))),
            ("width".to_string(), owned_value(Value::from(1200_u32))),
            ("height".to_string(), owned_value(Value::from(800_u32))),
        ]);

        let info = window_from_properties(42, &properties);

        assert_eq!(info.window_id, 42);
        assert_eq!(info.title.as_deref(), Some("Ghostty"));
        assert!(info.focused);
        assert_eq!(info.client_type.as_deref(), Some("wayland"));
        assert_eq!(info.bounds.unwrap().width, 1200);
    }
}
