public enum SettingsSectionMigration {
    public static func current(_ id: String?) -> String? {
        id == "claude" ? "model" : id
    }
}
