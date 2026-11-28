
use serde::Serialize;
use std::process::Output;

const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
const APPROVED_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
const VALUE: &str = "Wisp";
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Login {
    Enabled,
    Disabled,
    TurnedOffByUser,
    OtherCopy,
}

#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct AutostartStatus {
    pub state: Login,
    pub error: Option<String>,
}

fn quoted(exe: &str) -> String {
    format!("\"{exe}\"")
}

pub fn add_args(exe: &str) -> Vec<String> {
    let mut args: Vec<String> = ["add", RUN_KEY, "/v", VALUE, "/t", "REG_SZ", "/d"].map(String::from).to_vec();
    args.push(quoted(exe));
    args.push("/f".to_string());
    args
}

pub fn delete_args() -> Vec<String> {
    ["delete", RUN_KEY, "/v", VALUE, "/f"].map(String::from).to_vec()
}

pub fn query_args() -> Vec<String> {
    ["query", RUN_KEY, "/v", VALUE].map(String::from).to_vec()
}

pub fn approved_query_args() -> Vec<String> {
    ["query", APPROVED_KEY, "/v", VALUE].map(String::from).to_vec()
}

pub fn approved_delete_args() -> Vec<String> {
    ["delete", APPROVED_KEY, "/v", VALUE, "/f"].map(String::from).to_vec()
}

fn value_data(output: &str, kind: &str) -> Option<String> {
    output.lines().find_map(|line| {
        let mut parts = line.trim().splitn(2, char::is_whitespace);
        if parts.next()? != VALUE {
            return None;
        }
        let rest = parts.next()?.trim_start();
        let data = rest.strip_prefix(kind)?;
        Some(data.trim().to_string())
    })
}

pub fn classify(run_output: Option<&str>, approved_output: Option<&str>, exe: &str) -> Login {
    let Some(command) = run_output.and_then(|o| value_data(o, "REG_SZ")) else {
        return Login::Disabled;
    };
    if command.trim_matches('"').to_lowercase() != exe.to_lowercase() {
        return Login::OtherCopy;
    }
    let off = approved_output
        .and_then(|o| value_data(o, "REG_BINARY"))
        .map(|hex| hex.starts_with("03"))
        .unwrap_or(false);
    if off {
        Login::TurnedOffByUser
    } else {
        Login::Enabled
    }
}

#[cfg(windows)]
fn reg(args: &[String]) -> std::io::Result<Output> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;
    Command::new("reg.exe").args(args).creation_flags(CREATE_NO_WINDOW).output()
}

#[cfg(not(windows))]
fn reg(_args: &[String]) -> std::io::Result<Output> {
    Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "o Registro do Windows só existe no Windows"))
}

fn stdout_if_ok(args: &[String]) -> Option<String> {
    reg(args).ok().filter(|o| o.status.success()).map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
}

fn current_exe() -> Result<String, String> {
    let path = std::env::current_exe().map_err(|e| e.to_string())?;
    let text = path.to_string_lossy();
    Ok(text.strip_prefix(r"\\?\").unwrap_or(&text).to_string())
}

fn status_for(exe: &str) -> AutostartStatus {
    let state = classify(stdout_if_ok(&query_args()).as_deref(), stdout_if_ok(&approved_query_args()).as_deref(), exe);
    AutostartStatus { state, error: None }
}

#[tauri::command]
pub fn autostart_status() -> AutostartStatus {
    match current_exe() {
        Ok(exe) => status_for(&exe),
        Err(e) => AutostartStatus { state: Login::Disabled, error: Some(e) },
    }
}

#[tauri::command]
pub fn autostart_set(on: bool) -> Result<AutostartStatus, String> {
    let exe = current_exe()?;
    if on {
        let out = reg(&add_args(&exe)).map_err(|e| e.to_string())?;
        if !out.status.success() {
            return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
        }
        let _ = reg(&approved_delete_args());
    } else if stdout_if_ok(&query_args()).is_some() {
        let out = reg(&delete_args()).map_err(|e| e.to_string())?;
        if !out.status.success() {
            return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
        }
    }
    Ok(status_for(&exe))
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXE: &str = r"C:\Users\ana\AppData\Local\Programs\Wisp\wisp-win.exe";

    fn run_output(command: &str) -> String {
        format!("\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\r\n    Wisp    REG_SZ    {command}\r\n\r\n")
    }

    fn approved(hex: &str) -> String {
        format!("\r\nHKEY_CURRENT_USER\\...\\StartupApproved\\Run\r\n    Wisp    REG_BINARY    {hex}\r\n\r\n")
    }

    #[test]
    fn add_writes_the_quoted_exe_into_the_current_user_run_key() {
        let args = add_args(EXE);
        assert_eq!(args[0], "add");
        assert!(args[1].starts_with("HKCU\\"));
        assert_eq!(&args[2..6], ["/v", "Wisp", "/t", "REG_SZ"]);
        assert_eq!(args[7], format!("\"{EXE}\""));
        assert_eq!(args.last().unwrap(), "/f");
    }

    #[test]
    fn delete_and_query_target_only_the_wisp_value() {
        assert_eq!(delete_args(), ["delete", RUN_KEY, "/v", "Wisp", "/f"]);
        assert_eq!(query_args(), ["query", RUN_KEY, "/v", "Wisp"]);
        assert!(approved_delete_args()[1].ends_with("StartupApproved\\Run"));
    }

    #[test]
    fn no_run_value_is_disabled() {
        assert_eq!(classify(None, None, EXE), Login::Disabled);
        assert_eq!(classify(Some("\r\n"), None, EXE), Login::Disabled);
    }

    #[test]
    fn run_value_pointing_here_is_enabled_whatever_the_quotes_or_case() {
        let quoted = run_output(&format!("\"{EXE}\""));
        assert_eq!(classify(Some(&quoted), None, EXE), Login::Enabled);
        let shouting = run_output(&EXE.to_uppercase());
        assert_eq!(classify(Some(&shouting), None, EXE), Login::Enabled);
    }

    #[test]
    fn run_value_pointing_elsewhere_is_another_copy() {
        let other = run_output(r"C:\old\wisp-win.exe");
        assert_eq!(classify(Some(&other), None, EXE), Login::OtherCopy);
    }

    #[test]
    fn task_manager_switch_off_is_reported() {
        let on = run_output(EXE);
        assert_eq!(classify(Some(&on), Some(&approved("020000000000000000000000")), EXE), Login::Enabled);
        assert_eq!(classify(Some(&on), Some(&approved("060000000000000000000000")), EXE), Login::Enabled);
        assert_eq!(classify(Some(&on), Some(&approved("030000000000000000000000")), EXE), Login::TurnedOffByUser);
    }

    #[test]
    fn a_path_with_spaces_survives_the_parse() {
        let spaced = r"C:\Program Files\Wisp\wisp-win.exe";
        let out = run_output(&format!("\"{spaced}\""));
        assert_eq!(classify(Some(&out), None, spaced), Login::Enabled);
    }
}
