use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use portable_pty::{native_pty_system, Child, ChildKiller, CommandBuilder, MasterPty, PtySize, PtySystem, SlavePty};
use serde::Serialize;
use tauri::ipc::Channel;
use tauri::State;

#[cfg_attr(not(windows), allow(dead_code))]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
#[cfg(windows)]
const NULL_DEVICE: &str = "NUL";
#[cfg(not(windows))]
const NULL_DEVICE: &str = "/dev/null";
const GIT_TIMEOUT: Duration = Duration::from_secs(1);
const HISTORY_TAIL_BYTES: u64 = 4_000_000;
const MAX_LISTED: usize = 5_000;

#[derive(Clone, Serialize)]
#[serde(tag = "event", rename_all = "camelCase")]
pub enum PtyEvent {
    Output { text: String },
    Exit { code: Option<u32> },
}

struct PtySession {
    serial: u64,
    master: Arc<Mutex<Box<dyn MasterPty + Send>>>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    _job: Job,
}

impl PtySession {
    fn end(mut self) {
        let _ = self.killer.kill();
    }
}

type Sessions = Arc<Mutex<HashMap<String, PtySession>>>;

#[derive(Default)]
pub struct TerminalHost {
    sessions: Sessions,
}

impl TerminalHost {
    pub fn kill_all(&self) {
        let all: Vec<PtySession> = match self.sessions.lock() {
            Ok(mut map) => map.drain().map(|(_, session)| session).collect(),
            Err(_) => return,
        };
        for session in all {
            session.end();
        }
    }
}

#[cfg(windows)]
struct Job(windows_sys::Win32::Foundation::HANDLE);

#[cfg(windows)]
unsafe impl Send for Job {}

#[cfg(windows)]
impl Job {
    fn holding(process: Option<std::os::windows::io::RawHandle>) -> Job {
        use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
        use windows_sys::Win32::System::JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        };
        unsafe {
            let job: HANDLE = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job.is_null() {
                return Job(std::ptr::null_mut());
            }
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let limited = SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION as *const std::ffi::c_void,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            );
            let assigned = match process {
                Some(handle) if limited != 0 => AssignProcessToJobObject(job, handle as HANDLE),
                _ => 0,
            };
            if assigned == 0 {
                CloseHandle(job);
                return Job(std::ptr::null_mut());
            }
            Job(job)
        }
    }
}

#[cfg(windows)]
impl Drop for Job {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { windows_sys::Win32::Foundation::CloseHandle(self.0) };
        }
    }
}

#[cfg(not(windows))]
struct Job;

#[cfg(not(windows))]
impl Job {
    fn holding(_process: Option<*mut std::ffi::c_void>) -> Job {
        Job
    }
}

static SERIAL: AtomicU64 = AtomicU64::new(1);

fn take(sessions: &Sessions, id: &str) -> Option<PtySession> {
    sessions.lock().ok().and_then(|mut map| map.remove(id))
}

fn take_serial(sessions: &Sessions, id: &str, serial: u64) -> Option<PtySession> {
    let mut map = sessions.lock().ok()?;
    if map.get(id).map(|s| s.serial) == Some(serial) {
        map.remove(id)
    } else {
        None
    }
}

const PROGRAMS: [(&str, &str, &str); 3] = [
    ("pwsh", "pwsh.exe", "PowerShell 7"),
    ("powershell", "powershell.exe", "Windows PowerShell"),
    ("cmd", "cmd.exe", "Prompt de Comando"),
];

fn find_in_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|dir| dir.join(name)).find(|candidate| candidate.is_file())
}

#[derive(Serialize)]
pub struct ShellInfo {
    id: &'static str,
    label: &'static str,
}

#[tauri::command]
pub fn terminal_shells() -> Vec<ShellInfo> {
    PROGRAMS
        .iter()
        .filter(|(_, exe, _)| find_in_path(exe).is_some())
        .map(|(id, _, label)| ShellInfo { id: *id, label: *label })
        .collect()
}

#[tauri::command]
pub fn terminal_home() -> String {
    std::env::var("USERPROFILE").or_else(|_| std::env::var("HOME")).unwrap_or_else(|_| "C:\\".to_string())
}

fn is_withheld(key: &str) -> bool {
    let key = key.to_ascii_uppercase();
    key.starts_with("WISP_")
        || key.starts_with("CLAUDE_CODE_")
        || key.starts_with("CODEX_")
        || ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CLAUDE_CONFIG_DIR", "CLAUDECODE", "COLUMNS", "LINES"].contains(&key.as_str())
}

const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64(input: &[u8]) -> String {
    let mut out = String::with_capacity((input.len() + 2) / 3 * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = chunk.get(1).copied().unwrap_or(0) as u32;
        let b2 = chunk.get(2).copied().unwrap_or(0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(BASE64[((n >> 18) & 63) as usize] as char);
        out.push(BASE64[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 { BASE64[((n >> 6) & 63) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { BASE64[(n & 63) as usize] as char } else { '=' });
    }
    out
}

fn encoded_command(script: &str) -> String {
    let bytes: Vec<u8> = script.encode_utf16().flat_map(|unit| unit.to_le_bytes()).collect();
    base64(&bytes)
}

fn decode_chunk(pending: &mut Vec<u8>) -> String {
    let mut out = String::new();
    let mut start = 0;
    loop {
        match std::str::from_utf8(&pending[start..]) {
            Ok(text) => {
                out.push_str(text);
                start = pending.len();
                break;
            }
            Err(err) => {
                let good = start + err.valid_up_to();
                out.push_str(&String::from_utf8_lossy(&pending[start..good]));
                match err.error_len() {
                    Some(len) => {
                        out.push('\u{FFFD}');
                        start = good + len;
                    }
                    None => {
                        start = good;
                        break;
                    }
                }
            }
        }
    }
    pending.drain(..start);
    out
}

#[tauri::command(async)]
#[allow(clippy::too_many_arguments)]
pub fn terminal_spawn(
    host: State<'_, TerminalHost>,
    id: String,
    shell: String,
    cwd: Option<String>,
    cols: u16,
    rows: u16,
    nonce: Option<String>,
    integration: Option<String>,
    on_event: Channel<PtyEvent>,
) -> Result<(), String> {
    let (_, exe, _) = PROGRAMS.iter().find(|(name, _, _)| *name == shell).ok_or_else(|| format!("shell desconhecido: {shell}"))?;
    let program = find_in_path(exe).ok_or_else(|| format!("{exe} não encontrado"))?;

    let mut command = CommandBuilder::new(&program);
    for (key, _) in std::env::vars() {
        if is_withheld(&key) {
            command.env_remove(&key);
        }
    }
    command.env("TERM_PROGRAM", "Wisp");
    command.env("COLORTERM", "truecolor");
    if let Some(nonce) = nonce.as_deref() {
        command.env("WISP_MARK_NONCE", nonce);
    }
    if shell == "pwsh" || shell == "powershell" {
        command.arg("-NoLogo");
        if let Some(script) = integration.as_deref() {
            command.arg("-NoProfile");
            command.arg("-NoExit");
            command.arg("-EncodedCommand");
            command.arg(encoded_command(script));
        }
    }
    if let Some(dir) = cwd.as_deref().filter(|dir| Path::new(dir).is_dir()) {
        command.cwd(dir);
    }

    let pair = native_pty_system()
        .openpty(PtySize { rows: rows.max(1), cols: cols.max(2), pixel_width: 0, pixel_height: 0 })
        .map_err(|e| e.to_string())?;
    let mut child = pair.slave.spawn_command(command).map_err(|e| e.to_string())?;
    drop(pair.slave);
    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
    let killer = child.clone_killer();
    #[cfg(windows)]
    let job = Job::holding(child.as_raw_handle());
    #[cfg(not(windows))]
    let job = Job::holding(None);

    let serial = SERIAL.fetch_add(1, Ordering::Relaxed);
    let old = {
        let mut map = host.sessions.lock().map_err(|_| "terminal ocupado".to_string())?;
        map.insert(
            id.clone(),
            PtySession { serial, master: Arc::new(Mutex::new(pair.master)), writer: Arc::new(Mutex::new(writer)), killer, _job: job },
        )
    };
    if let Some(old) = old {
        old.end();
    }

    let (done_tx, done_rx) = mpsc::channel::<Option<u32>>();
    let sessions = Arc::clone(&host.sessions);
    let waiting_id = id.clone();
    thread::spawn(move || {
        let code = child.wait().ok().map(|status| status.exit_code());
        drop(take_serial(&sessions, &waiting_id, serial));
        let _ = done_tx.send(code);
    });
    let sessions = Arc::clone(&host.sessions);
    thread::spawn(move || {
        let mut pending: Vec<u8> = Vec::new();
        let mut buffer = [0u8; 8192];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    pending.extend_from_slice(&buffer[..n]);
                    let text = decode_chunk(&mut pending);
                    if !text.is_empty() && on_event.send(PtyEvent::Output { text }).is_err() {
                        if let Some(session) = take_serial(&sessions, &id, serial) {
                            session.end();
                        }
                        return;
                    }
                }
            }
        }
        let code = done_rx.recv_timeout(Duration::from_secs(5)).ok().flatten();
        let _ = on_event.send(PtyEvent::Exit { code });
    });
    Ok(())
}

fn handles(host: &TerminalHost, id: &str) -> Result<(Arc<Mutex<Box<dyn Write + Send>>>, Arc<Mutex<Box<dyn MasterPty + Send>>>), String> {
    let map = host.sessions.lock().map_err(|_| "terminal ocupado".to_string())?;
    let session = map.get(id).ok_or_else(|| "sessão encerrada".to_string())?;
    Ok((Arc::clone(&session.writer), Arc::clone(&session.master)))
}

#[tauri::command(async)]
pub fn terminal_write(host: State<'_, TerminalHost>, id: String, data: String) -> Result<(), String> {
    let (writer, _) = handles(&host, &id)?;
    let mut writer = writer.lock().map_err(|_| "terminal ocupado".to_string())?;
    writer.write_all(data.as_bytes()).map_err(|e| e.to_string())?;
    writer.flush().map_err(|e| e.to_string())
}

#[tauri::command(async)]
pub fn terminal_resize(host: State<'_, TerminalHost>, id: String, cols: u16, rows: u16) -> Result<(), String> {
    let (_, master) = handles(&host, &id)?;
    let master = master.lock().map_err(|_| "terminal ocupado".to_string())?;
    master
        .resize(PtySize { rows: rows.max(1), cols: cols.max(2), pixel_width: 0, pixel_height: 0 })
        .map_err(|e| e.to_string())
}

#[tauri::command(async)]
pub fn terminal_kill(host: State<'_, TerminalHost>, id: String) -> Result<(), String> {
    if let Some(session) = take(&host.sessions, &id) {
        session.end();
    }
    Ok(())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirEntryInfo {
    name: String,
    is_dir: bool,
}

#[tauri::command(async)]
pub fn terminal_list_dir(path: String) -> Vec<DirEntryInfo> {
    let Ok(entries) = fs::read_dir(&path) else { return Vec::new() };
    entries
        .flatten()
        .take(MAX_LISTED)
        .map(|entry| DirEntryInfo { name: entry.file_name().to_string_lossy().into_owned(), is_dir: entry.path().is_dir() })
        .collect()
}

const EXECUTABLE_EXTENSIONS: [&str; 5] = ["exe", "cmd", "bat", "com", "ps1"];

#[tauri::command(async)]
pub fn terminal_executables() -> Vec<String> {
    let Some(path) = std::env::var_os("PATH") else { return Vec::new() };
    let mut seen = HashSet::new();
    let mut names = Vec::new();
    for dir in std::env::split_paths(&path) {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let file = entry.path();
            let Some(extension) = file.extension().and_then(|e| e.to_str()) else { continue };
            if !EXECUTABLE_EXTENSIONS.contains(&extension.to_ascii_lowercase().as_str()) {
                continue;
            }
            let Some(stem) = file.file_stem().and_then(|s| s.to_str()) else { continue };
            if seen.insert(stem.to_ascii_lowercase()) {
                names.push(stem.to_string());
            }
        }
    }
    names
}

#[derive(Serialize)]
pub struct GitRaw {
    porcelain: String,
    shortstat: String,
}

fn run_git(directory: &str, args: &[&str]) -> Option<String> {
    let mut command = Command::new("git");
    command
        .args(["-c", "core.fsmonitor=false", "-c"])
        .arg(format!("core.hooksPath={NULL_DEVICE}"))
        .args(["-c", "core.untrackedCache=false"])
        .arg("-C")
        .arg(directory)
        .args(args)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let mut child = command.spawn().ok()?;
    let mut stdout = child.stdout.take()?;
    let reader = thread::spawn(move || {
        let mut data = Vec::new();
        let _ = stdout.read_to_end(&mut data);
        data
    });
    let deadline = Instant::now() + GIT_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let data = reader.join().ok()?;
    match status {
        Some(status) if status.success() => Some(String::from_utf8_lossy(&data).into_owned()),
        _ => None,
    }
}

#[tauri::command(async)]
pub fn terminal_git_status(directory: String) -> Option<GitRaw> {
    if !Path::new(&directory).is_dir() {
        return None;
    }
    let porcelain = run_git(&directory, &["status", "--porcelain=v2", "--branch"])?;
    let shortstat = run_git(&directory, &["diff", "HEAD", "--shortstat"]).unwrap_or_default();
    Some(GitRaw { porcelain, shortstat })
}

fn psreadline_dir() -> Option<PathBuf> {
    let appdata = std::env::var_os("APPDATA")?;
    fs::canonicalize(PathBuf::from(appdata).join("Microsoft").join("Windows").join("PowerShell").join("PSReadLine")).ok()
}

fn is_history_file(file: &Path, dir: &Path) -> bool {
    let Ok(resolved) = fs::canonicalize(file) else { return false };
    let named = resolved
        .file_name()
        .and_then(|n| n.to_str())
        .map(|n| n.to_ascii_lowercase().ends_with("_history.txt"))
        .unwrap_or(false);
    named && resolved.parent() == Some(dir)
}

#[tauri::command(async)]
pub fn terminal_read_history(path: String) -> Option<String> {
    let dir = psreadline_dir()?;
    let file = Path::new(&path);
    if !is_history_file(file, &dir) {
        return None;
    }
    let mut handle = fs::File::open(file).ok()?;
    let size = handle.metadata().ok()?.len();
    let start = size.saturating_sub(HISTORY_TAIL_BYTES);
    handle.seek(SeekFrom::Start(start)).ok()?;
    let mut data = Vec::new();
    handle.read_to_end(&mut data).ok()?;
    if start > 0 {
        if let Some(newline) = data.iter().position(|b| *b == b'\n') {
            data.drain(..=newline);
        }
    }
    Some(String::from_utf8_lossy(&data).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_the_rfc_vectors() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"M"), "TQ==");
        assert_eq!(base64(b"Ma"), "TWE=");
        assert_eq!(base64(b"Man"), "TWFu");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn the_encoded_command_is_utf16le() {
        assert_eq!(encoded_command("A"), "QQA=");
    }

    #[test]
    fn a_character_cut_between_two_reads_is_kept_for_the_next() {
        let mut pending = "ação".as_bytes()[..2].to_vec();
        assert_eq!(decode_chunk(&mut pending), "a");
        pending.extend_from_slice(&"ação".as_bytes()[2..]);
        assert_eq!(decode_chunk(&mut pending), "ção");
        assert!(pending.is_empty());
    }

    #[test]
    fn an_invalid_byte_becomes_the_replacement_character() {
        let mut pending = vec![b'a', 0xFF, b'b'];
        assert_eq!(decode_chunk(&mut pending), "a\u{FFFD}b");
    }

    #[test]
    fn only_a_history_file_inside_the_psreadline_folder_is_read() {
        let base = std::env::temp_dir().join(format!("wisp-history-test-{}", std::process::id()));
        let dir = base.join("PSReadLine");
        fs::create_dir_all(&dir).unwrap();
        let dir = fs::canonicalize(&dir).unwrap();
        let good = dir.join("ConsoleHost_history.txt");
        let other = dir.join("notes.txt");
        let outside = base.join("x_history.txt");
        for file in [&good, &other, &outside] {
            fs::write(file, "dir\n").unwrap();
        }
        assert!(is_history_file(&good, &dir));
        assert!(!is_history_file(&other, &dir));
        assert!(!is_history_file(&outside, &dir));
        assert!(!is_history_file(&dir.join("..").join("x_history.txt"), &dir));
        assert!(!is_history_file(&dir.join("missing_history.txt"), &dir));
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn engine_variables_are_withheld_and_the_rest_is_not() {
        assert!(is_withheld("anthropic_api_key"));
        assert!(is_withheld("WISP_MARK_NONCE"));
        assert!(is_withheld("CLAUDE_CODE_ENTRYPOINT"));
        assert!(!is_withheld("PATH"));
        assert!(!is_withheld("USERPROFILE"));
    }
}
