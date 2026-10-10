import Foundation

/// Pure-domain constants and markers for Payday Bridge.
///
/// Offline payday planning domain: decimal-safe money, civil calendar
/// recurrence, and envelope assignments land in issue #2.
public enum PaydayBridgeKit {
    public static let domain = "PaydayBridgeKit"
    public static let milestone = "M1-skeleton"

    /// Mandatory planning truth declaration: manual estimates, not bank-verified funds.
    public static let planningDisclaimer =
        "Manual planning estimates, not bank-verified funds or financial advice."

    /// Zero network calls allowed anywhere in the app or domain kit.
    public static let zeroNetworkContract = true
}
