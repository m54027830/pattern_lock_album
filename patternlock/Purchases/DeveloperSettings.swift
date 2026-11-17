/// Local development switches. PurchaseAccess ignores this flag in Release builds.
nonisolated enum DeveloperSettings {
    /// Set to true, then rebuild and run the Debug configuration to test every Pro feature.
    /// Set back to false, rebuild, and relaunch to test normal purchases and free limits.
    static let enableProForTesting = true
}
