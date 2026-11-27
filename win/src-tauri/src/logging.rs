use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::Path;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

const ROTATE_AT: u64 = 2_000_000;

pub struct Logger {
    file: Mutex<File>,
}

impl Logger {
    pub fn open(dir: &Path) -> std::io::Result<Self> {
        fs::create_dir_all(dir)?;
        let path = dir.join("app.log");
        if fs::metadata(&path).map(|m| m.len() > ROTATE_AT).unwrap_or(false) {
            let _ = fs::rename(&path, dir.join("app.log.old"));
        }
        let file = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Self { file: Mutex::new(file) })
    }

    pub fn line(&self, message: &str) {
        let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        if let Ok(mut file) = self.file.lock() {
            let _ = writeln!(file, "[{secs}] {message}");
        }
    }

    pub fn handle(&self) -> Option<File> {
        self.file.lock().ok()?.try_clone().ok()
    }
}
