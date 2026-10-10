import Foundation
import Testing
@testable import PaydayBridgeKit

@Suite("Payday worksheet domain")
struct PlanningTests {
    private let usd = "USD"
    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> CivilDate {
        try CivilDate(year: year, month: month, day: day)
    }
    private func amount(_ text: String) throws -> Money {
        try Money(text, currency: usd)
    }

    @Test func decimalPrecisionAndLimits() throws {
        let total = try amount("0.10") + amount("0.20")
        #expect(try total == amount("0.30"))
        #expect(throws: PlanningError.self) { try Money("0.001", currency: usd) }
        #expect(throws: PlanningError.self) { try Money("-1", currency: usd) }
        #expect(throws: PlanningError.self) { try Money("NaN", currency: usd) }
        #expect(throws: PlanningError.self) { try Money("1000000000", currency: usd) }
        #expect(throws: PlanningError.self) { try Money("3", currency: "US") }
        #expect(throws: PlanningError.self) { try amount("2") + Money("3", currency: "EUR") }
    }

    @Test func civilDatesAndRecurrenceKeepAnchor() throws {
        #expect(throws: PlanningError.self) { try CivilDate(year: 2025, month: 2, day: 29) }
        let bill = Bill(id: UUID(), title: "Rent", firstDue: try date(2024, 1, 31),
                        recurrence: .monthly, amount: try amount("10"))
        let occurrences = try bill.occurrences(from: try date(2024, 1, 1), days: 90)
        let expectedDates = [try date(2024, 1, 31), try date(2024, 2, 29), try date(2024, 3, 31)]
        #expect(occurrences.map(\.due) == expectedDates)
        #expect(Set(occurrences.map(\.key)).count == 3)
        #expect(throws: PlanningError.self) { try bill.occurrences(from: try date(2024, 1, 1), days: 91) }
    }

    @Test func overrideAndPaidReopenSurviveRegeneration() throws {
        let bill = Bill(id: UUID(), title: "Utility", firstDue: try date(2025, 1, 30),
                        recurrence: .monthly, amount: nil)
        let initial = try bill.occurrences(from: try date(2025, 1, 1), days: 90)
        let febDate = try date(2025, 2, 28)
        let feb = try #require(initial.first { $0.due == febDate })
        var overrides = [feb.key: OccurrenceOverride(amount: try amount("62.10"), paid: true)]
        var generated = try bill.occurrences(from: try date(2025, 1, 1), days: 90, overrides: overrides)
        #expect(try generated.first { $0.key == feb.key }?.amount == amount("62.10"))
        #expect(generated.first { $0.key == feb.key }?.paid == true)
        overrides[feb.key]?.paid = false
        generated = try bill.occurrences(from: try date(2025, 1, 1), days: 90, overrides: overrides)
        #expect(generated.first { $0.key == feb.key }?.paid == false)
        #expect(try generated.first { $0.key == feb.key }?.amount == amount("62.10"))
        let marchDate = try date(2025, 3, 30)
        #expect(generated.first { $0.due == marchDate }?.amount == nil)
    }

    @Test func confirmedCoverageUnknownsLateAndOvercommitment() throws {
        let start = try date(2025, 6, 1)
        let due = try date(2025, 6, 5)
        let payDate = try date(2025, 6, 10)
        let bill = Bill(id: UUID(), title: "Rent", firstDue: due, recurrence: .once,
                        amount: try amount("60"))
        let unknown = Bill(id: UUID(), title: "Power", firstDue: due, recurrence: .once, amount: nil)
        let known = try #require(bill.occurrences(from: start, days: 30).first)
        let mystery = try #require(unknown.occurrences(from: start, days: 30).first)
        let confirmed = Income(id: UUID(), date: payDate, amount: try amount("40"), status: .confirmed)
        let expected = Income(id: UUID(), date: due, amount: try amount("200"), status: .expected)
        let worksheet = Worksheet(currency: usd, openingCash: try amount("20"),
                                  openingDate: start, incomes: [confirmed, expected],
                                  bills: [bill, unknown], assignments: [known.key: .openingCash, mystery.key: .income(expected.id)])
        let coverage = try worksheet.coverage(from: start, days: 30)
        #expect(try coverage.confirmedFunds == amount("60"))
        #expect(try coverage.expectedFunds == amount("200"))
        #expect(coverage.items.first { $0.key == known.key }?.warnings.contains(.overcommitted) == true)
        #expect(coverage.items.first { $0.key == mystery.key }?.warnings.contains(.unknownAmount) == true)
        #expect(coverage.items.first { $0.key == mystery.key }?.warnings.contains(.expectedNotConfirmed) == true)
        #expect(coverage.complete == false)
        #expect(coverage.manualEstimateDisclaimer == PaydayBridgeKit.planningDisclaimer)
        let late = Worksheet(currency: usd, openingCash: try amount("0"), openingDate: start,
                             incomes: [confirmed], bills: [bill], assignments: [known.key: .income(confirmed.id)])
        #expect(try late.coverage(from: start, days: 30).items[0].warnings.contains(.fundingAfterDue))
    }

    @Test func openingCashOnceAndPaidNotFutureCommitment() throws {
        let start = try date(2025, 1, 1)
        let b1 = Bill(id: UUID(), title: "A", firstDue: start, recurrence: .once, amount: try amount("40"))
        let b2 = Bill(id: UUID(), title: "B", firstDue: start, recurrence: .once, amount: try amount("40"))
        let a = try #require(b1.occurrences(from: start, days: 5).first)
        let b = try #require(b2.occurrences(from: start, days: 5).first)
        let sheet = Worksheet(currency: usd, openingCash: try amount("50"), openingDate: start,
                              bills: [b1,b2], assignments: [a.key: .openingCash, b.key: .openingCash])
        let coverage = try sheet.coverage(from: start, days: 5)
        #expect(coverage.items.allSatisfy { $0.warnings.contains(.overcommitted) })
        let paid = Worksheet(currency: usd, openingCash: try amount("50"), openingDate: start,
                             bills: [b1,b2], overrides: [a.key: OccurrenceOverride(paid: true)],
                             assignments: [a.key: .openingCash, b.key: .openingCash])
        let after = try paid.coverage(from: start, days: 5)
        #expect(after.items.first { $0.key == a.key }?.paid == true)
        #expect(after.items.first { $0.key == b.key }?.warnings.contains(.overcommitted) == false)
    }

    @Test func duplicateAndForeignAssignmentRejected() throws {
        let start = try date(2025, 1, 1)
        let bill = Bill(id: UUID(), title: "A", firstDue: start, recurrence: .once, amount: try amount("1"))
        let duplicate = Worksheet(currency: usd, openingCash: try amount("0"), openingDate: start, bills: [bill,bill])
        #expect(throws: PlanningError.self) { try duplicate.coverage(from: start, days: 1) }
        let unknown = Worksheet(currency: usd, openingCash: try amount("0"), openingDate: start,
                                bills: [bill], assignments: ["missing": .openingCash])
        #expect(throws: PlanningError.self) { try unknown.coverage(from: start, days: 1) }
    }
}
