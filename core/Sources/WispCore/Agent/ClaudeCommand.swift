public enum ClaudeCommand {
    public static func arguments(model: String?, resume: String?) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        if let model { args += ["--model", model] }
        if let resume { args += ["--resume", resume] }
        return args
    }
}
