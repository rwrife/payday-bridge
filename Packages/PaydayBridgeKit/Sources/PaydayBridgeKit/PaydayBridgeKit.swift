import Foundation

/// Pure-domain constants and markers for Payday Bridge.
///
/// Offline payday planning domain: decimal-safe money, civil calendar
/// recurrence, and explainable envelope assignments.
public enum PaydayBridgeKit {
    public static let domain = "PaydayBridgeKit"
    public static let milestone = "M2-domain"

    /// Mandatory planning truth declaration: manual estimates, not bank-verified funds.
    public static let planningDisclaimer =
        "Manual planning estimates, not bank-verified funds or financial advice."

    /// Zero network calls allowed anywhere in the app or domain kit.
    public static let zeroNetworkContract = true
}
