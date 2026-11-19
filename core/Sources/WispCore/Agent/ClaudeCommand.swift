public enum ClaudeCommand {
    public static func arguments(model: String?, resume: String?, permissionMode: String? = nil, appendSystemPrompt: String? = nil, settings: String? = nil, disallowedTools: [String] = []) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        if let model { args += ["--model", model] }
        if let resume { args += ["--resume", resume] }
        if let permissionMode { args += ["--permission-mode", permissionMode] }
        if let appendSystemPrompt { args += ["--append-system-prompt", appendSystemPrompt] }
        if let settings { args += ["--settings", settings] }
        if !disallowedTools.isEmpty { args += ["--disallowedTools"] + disallowedTools }
        args += ["--permission-prompt-tool", "stdio"]
        return args
    }
}
