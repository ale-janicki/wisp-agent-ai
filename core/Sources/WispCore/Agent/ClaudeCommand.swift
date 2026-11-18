public enum ClaudeCommand {
    /// `--permission-prompt-tool stdio` sends every prompt to the host as a `can_use_tool` control request;
    /// without it a prompt in `-p` mode is denied on the spot.
    public static func arguments(model: String?, resume: String?, permissionMode: String? = nil) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        if let model { args += ["--model", model] }
        if let resume { args += ["--resume", resume] }
        if let permissionMode { args += ["--permission-mode", permissionMode] }
        args += ["--permission-prompt-tool", "stdio"]
        return args
    }
}
