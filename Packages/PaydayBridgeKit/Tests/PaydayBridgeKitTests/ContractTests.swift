import Testing
@testable import PaydayBridgeKit

@Suite("Skeleton contract")
struct ContractTests {
    @Test func domainNamespace() {
        #expect(PaydayBridgeKit.domain == "PaydayBridgeKit")
        #expect(PaydayBridgeKit.milestone == "M1-skeleton")
    }

    @Test func planningTruth() {
        #expect(PaydayBridgeKit.planningDisclaimer ==
                "Manual planning estimates, not bank-verified funds or financial advice.")
        #expect(PaydayBridgeKit.zeroNetworkContract)
    }
}
