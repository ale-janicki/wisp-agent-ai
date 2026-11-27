use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use serde::Serialize;
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Emitter, Manager};

use crate::logging::Logger;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const READY_TIMEOUT: Duration = Duration::from_secs(60);

#[derive(Clone, Serialize)]
#[serde(tag = "status", rename_all = "lowercase")]
pub enum SidecarState {
    Preparing,
    Ready { port: u16, token: String },
    Failed { message: String },
}

pub struct SidecarHost {
    state: Mutex<SidecarState>,
    child: Mutex<Option<Child>>,
}

impl Default for SidecarHost {
    fn default() -> Self {
        Self { state: Mutex::new(SidecarState::Preparing), child: Mutex::new(None) }
    }
}

impl SidecarHost {
    pub fn state(&self) -> SidecarState {
        self.state.lock().map(|s| s.clone()).unwrap_or(SidecarState::Preparing)
    }

    pub fn kill(&self) {
        if let Ok(mut slot) = self.child.lock() {
            if let Some(mut child) = slot.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }

    fn publish(&self, app: &AppHandle, next: SidecarState) {
        if let Ok(mut state) = self.state.lock() {
            *state = next.clone();
        }
        let _ = app.emit("sidecar://state", next);
    }
}

pub fn start(app: AppHandle, log: Arc<Logger>) {
    thread::spawn(move || {
        let host = app.state::<SidecarHost>();
        match bootstrap(&app, &log) {
            Ok((port, token)) => {
                log.line(&format!("sidecar ready on 127.0.0.1:{port}"));
                host.publish(&app, SidecarState::Ready { port, token });
                watch(&app, &log);
            }
            Err(message) => {
                log.line(&format!("sidecar failed: {message}"));
                host.publish(&app, SidecarState::Failed { message });
            }
        }
    });
}

fn watch(app: &AppHandle, log: &Logger) {
    let host = app.state::<SidecarHost>();
    loop {
        thread::sleep(Duration::from_secs(3));
        let exited = {
            let Ok(mut slot) = host.child.lock() else { return };
            let Some(child) = slot.as_mut() else { return };
            match child.try_wait() {
                Ok(Some(status)) => Some(status.to_string()),
                _ => None,
            }
        };
        if let Some(status) = exited {
            log.line(&format!("sidecar exited: {status}"));
            host.publish(app, SidecarState::Failed { message: "O Wisp parou de responder".into() });
            return;
        }
    }
}

fn bootstrap(app: &AppHandle, log: &Arc<Logger>) -> Result<(u16, String), String> {
    let resources = resource_dir(app)?;
    let root = app.path().local_data_dir().map_err(|e| e.to_string())?.join("wisp");
    let runtime = root.join("runtime");
    let venv = runtime.join("venv");
    let python = runtime.join("python");
    let stamp = runtime.join("uv.lock.sha256");
    let serve = venv.join("Scripts").join("wisp-serve.exe");

    let lock = fs::read(resources.join("uv.lock")).map_err(|e| format!("uv.lock ausente: {e}"))?;
    let hash = format!("{:x}", Sha256::digest(&lock));
    let stamped = fs::read_to_string(&stamp).map(|s| s.trim().to_string()).unwrap_or_default();

    if !serve.exists() || stamped != hash {
        log.line("preparing runtime (uv sync)");
        fs::create_dir_all(&runtime).map_err(|e| e.to_string())?;
        sync(&resources, &venv, &python, log)?;
        fs::write(&stamp, &hash).map_err(|e| e.to_string())?;
    }
    spawn(app, &serve, log)
}

fn sync(resources: &Path, venv: &Path, python: &Path, log: &Logger) -> Result<(), String> {
    let mut cmd = Command::new(resources.join("uv.exe"));
    cmd.args(["sync", "--frozen", "--no-dev", "--project"])
        .arg(resources)
        .env("UV_PROJECT_ENVIRONMENT", venv)
        .env("UV_PYTHON_INSTALL_DIR", python)
        .stdin(Stdio::null());
    hide(&mut cmd);
    let out = cmd.output().map_err(|e| format!("não consegui rodar o uv: {e}"))?;
    log.line(&format!("uv sync: {}", out.status));
    log.line(&String::from_utf8_lossy(&out.stdout));
    log.line(&String::from_utf8_lossy(&out.stderr));
    if out.status.success() {
        Ok(())
    } else {
        Err("Não consegui preparar o Wisp (detalhes em app.log)".into())
    }
}

fn spawn(app: &AppHandle, serve: &Path, log: &Arc<Logger>) -> Result<(u16, String), String> {
    let token = random_token()?;
    let mut cmd = Command::new(serve);
    cmd.args(["--port", "0"])
        .env("WISP_SERVE_TOKEN", &token)
        .env("PYTHONUTF8", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped());
    match log.handle() {
        Some(file) => cmd.stderr(Stdio::from(file)),
        None => cmd.stderr(Stdio::null()),
    };
    hide(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| format!("não consegui iniciar o servidor: {e}"))?;
    let stdout = child.stdout.take().ok_or("sem stdout do servidor")?;

    let (tx, rx) = mpsc::channel();
    let reader_log = Arc::clone(log);
    thread::spawn(move || {
        let mut announced = false;
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if !announced {
                if let Some(port) = parse_ready(&line) {
                    announced = true;
                    let _ = tx.send(port);
                    continue;
                }
            }
            reader_log.line(&format!("serve: {line}"));
        }
    });

    app.state::<SidecarHost>().child.lock().map_err(|e| e.to_string())?.replace(child);
    match rx.recv_timeout(READY_TIMEOUT) {
        Ok(port) => Ok((port, token)),
        Err(_) => {
            app.state::<SidecarHost>().kill();
            Err("O servidor do Wisp não respondeu a tempo (detalhes em app.log)".into())
        }
    }
}

fn parse_ready(line: &str) -> Option<u16> {
    let value: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
    if value.get("ready")?.as_bool()? {
        u16::try_from(value.get("port")?.as_u64()?).ok()
    } else {
        None
    }
}

fn random_token() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    getrandom::getrandom(&mut bytes).map_err(|e| format!("sem entropia: {e}"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

fn resource_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = match std::env::var_os("WISP_RESOURCE_DIR") {
        Some(dir) => PathBuf::from(dir),
        None => app.path().resource_dir().map_err(|e| e.to_string())?,
    };
    let text = dir.to_string_lossy();
    Ok(match text.strip_prefix(r"\\?\") {
        Some(rest) => PathBuf::from(rest),
        None => dir,
    })
}

#[cfg(windows)]
fn hide(cmd: &mut Command) {
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
fn hide(_cmd: &mut Command) {
    let _ = CREATE_NO_WINDOW;
}
