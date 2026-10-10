import Testing
@testable import PaydayBridgeKit

@Suite("Package contract")
struct ContractTests {
    @Test func domainNamespace() {
        #expect(PaydayBridgeKit.domain == "PaydayBridgeKit")
        #expect(PaydayBridgeKit.milestone == "M2-domain")
    }

    @Test func planningTruth() {
        #expect(PaydayBridgeKit.planningDisclaimer ==
                "Manual planning estimates, not bank-verified funds or financial advice.")
        #expect(PaydayBridgeKit.zeroNetworkContract)
    }
}
