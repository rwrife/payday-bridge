import Foundation
import Testing
@testable import PaydayBridgeKit

@Suite("Adversarial planning validation")
struct ValidationTests {
    private let start = try! CivilDate(year: 2025, month: 1, day: 1)
    private func money(_ text: String = "0", _ currency: String = "USD") throws -> Money { try Money(text, currency: currency) }
    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONDecoder().decode(type, from: Data(text.utf8)) }
    private func roundtrip(_ sheet: Worksheet) throws -> Worksheet { try JSONDecoder().decode(Worksheet.self, from: JSONEncoder().encode(sheet)) }

    @Test func moneyGrammarAndCurrencies() throws {
        for text in ["", ".1", "1.", " 1", "+1", "1e2", "1,000", "inf", "Infinity", "-0", "١", "0.000", "999999999.999", "0000000000"] {
            #expect(throws: PlanningError.self) { try money(text) }
        }
        #expect(try money("999999999.99").value == Decimal(string: "999999999.99"))
        #expect(try money("10", "JPY").value == 10)
        #expect(throws: PlanningError.self) { try money("10.0", "JPY") }
        #expect(throws: PlanningError.self) { try money("1", "usd") }
        #expect(throws: PlanningError.self) { try money("999999999.99") + money("0.01") }
        for currency in ["EUR", "GBP", "CAD", "AUD", "CHF", "NZD"] { #expect(try money("0.10", currency) + money("0.20", currency) == money("0.30", currency)) }
        #expect(throws: PlanningError.self) { try decode(Money.self, #"{"amount":"NaN","currency":"USD"}"#) }
        #expect(throws: PlanningError.self) { try decode(Money.self, #"{"amount":"0.001","currency":"USD"}"#) }
    }

    @Test func invalidDatesAndHorizon() throws {
        for (y, m, d) in [(1899,1,1), (10000,1,1), (2025,0,1), (2025,13,1), (2025,4,31), (2025,1,0), (2025,1,32), (1900,2,29)] {
            #expect(throws: PlanningError.self) { try CivilDate(year: y, month: m, day: d) }
        }
        #expect(try CivilDate(year: 2000, month: 2, day: 29).day == 29)
        #expect(throws: PlanningError.self) { try decode(CivilDate.self, #"{"year":2025,"month":2,"day":30}"#) }
        let b = Bill(id: UUID(), title: "A", firstDue: start, recurrence: .once, amount: nil)
        for days in [-1,0,91,Int.max] { #expect(throws: PlanningError.self) { try b.occurrences(from: start, days: days) } }
        let last = try CivilDate(year: 9999, month: 12, day: 31)
        #expect(throws: PlanningError.self) { try b.occurrences(from: last, days: 2) }
        let sheet = Worksheet(currency: "USD", openingCash: try money(), openingDate: start)
        #expect(throws: PlanningError.self) { try sheet.coverage(from: CivilDate(year: 2024, month: 12, day: 31), days: 1) }
    }

    @Test func changedAnchorRetainsMonthlyIdentityAndOffHorizonReferences() throws {
        let id = UUID()
        let original = Bill(id: id, title: "A", firstDue: try CivilDate(year: 2025, month: 1, day: 31), recurrence: .monthly, amount: try money("10"))
        let initial = try original.occurrences(from: start, days: 90)
        let key = initial[1].key
        let changed = Bill(id: id, title: "A", firstDue: try CivilDate(year: 2025, month: 1, day: 29), recurrence: .monthly, amount: try money("20"))
        let override = [key: OccurrenceOverride(amount: try money("15"), paid: true)]
        let regenerated = try changed.occurrences(from: start, days: 90, overrides: override)
        #expect(regenerated[1].key == key)
        #expect(regenerated[1].paid)
        #expect(try regenerated[1].amount == money("15"))
        #expect(regenerated[2].due.day == 29)
        let sheet = Worksheet(currency: "USD", openingCash: try money(), openingDate: start, bills: [changed], overrides: override, assignments: [key: .openingCash])
        #expect(try roundtrip(sheet).coverage(from: CivilDate(year: 2025, month: 4, day: 1), days: 30).items.count == 1)
        let nonLeap = try original.occurrences(from: CivilDate(year: 2026, month: 2, day: 1), days: 89)
        #expect(nonLeap.map(\.due.day) == [28,31,30])
        #expect(try original.occurrences(from: CivilDate(year: 2024, month: 1, day: 1), days: 90).isEmpty)
    }

    @Test func decodedWorksheetRejectsInvalidInputs() throws {
        let b = Bill(id: UUID(), title: "A", firstDue: start, recurrence: .once, amount: try money("1"))
        let k = try #require(b.occurrences(from: start, days: 1).first).key
        let i = Income(id: UUID(), date: start, amount: try money("5"), status: .confirmed)
        let invalid = [
            Worksheet(currency: "USD", openingCash: try money("0", "EUR"), openingDate: start),
            Worksheet(currency: "USD", openingCash: try money(), openingDate: start, bills: [b,b]),
            Worksheet(currency: "USD", openingCash: try money(), openingDate: start, incomes: [i,i]),
            Worksheet(currency: "USD", openingCash: try money(), openingDate: start, bills: [b], assignments: [k: .income(UUID())]),
            Worksheet(currency: "USD", openingCash: try money(), openingDate: start, bills: [b], overrides: ["missing": OccurrenceOverride(paid: true)]),
            Worksheet(currency: "USD", openingCash: try money(), openingDate: start, bills: [b], overrides: [k: OccurrenceOverride(amount: try money("1", "EUR"))]),
            Worksheet(currency: "USD", openingCash: try money(), openingDate: start, bills: [Bill(id: UUID(), title: " ", firstDue: start, recurrence: .once, amount: nil)]),
            Worksheet(currency: "USD", openingCash: try money(), openingDate: start, incomes: [Income(id: UUID(), date: start, amount: try money("1", "JPY"), status: .confirmed)]),
            Worksheet(currency: "USD", openingCash: try money(), openingDate: start, bills: [Bill(id: UUID(), title: "Foreign", firstDue: start, recurrence: .once, amount: try money("1", "EUR"))]),
            Worksheet(currency: "USD", openingCash: try money(), openingDate: start, incomes: [Income(id: b.id, date: start, amount: try money(), status: .confirmed)], bills: [b]),
            Worksheet(currency: "USD", openingCash: try money(), openingDate: start, bills: (0...1000).map { _ in Bill(id: UUID(), title: "A", firstDue: start, recurrence: .once, amount: nil) })
        ]
        for sheet in invalid {
            #expect(throws: PlanningError.self) { try sheet.validate() }
            #expect(throws: PlanningError.self) { try roundtrip(sheet) }
        }
        #expect(try roundtrip(Worksheet(currency: "USD", openingCash: money(), openingDate: start, incomes: [i], bills: [b], assignments: [k: .income(i.id)])).assignments[k] == .income(i.id))
    }

    @Test func completeCoverageExclusiveReassignmentAndLateEvenWithEnough() throws {
        let b = Bill(id: UUID(), title: "A", firstDue: start, recurrence: .once, amount: try money("10"))
        let k = try #require(b.occurrences(from: start, days: 1).first).key
        let late = Income(id: UUID(), date: try start.adding(days: 1), amount: try money("100"), status: .confirmed)
        let expected = Income(id: UUID(), date: try start.adding(days: 1), amount: try money("100"), status: .expected)
        func coverage(_ assignments: [String: Envelope], overrides: [String: OccurrenceOverride] = [:]) throws -> Coverage {
            try Worksheet(currency: "USD", openingCash: money("10"), openingDate: start, incomes: [late,expected], bills: [b], overrides: overrides, assignments: assignments).coverage(from: start, days: 5)
        }
        #expect(try coverage([:]).items[0].warnings == [.unassigned])
        var assignments: [String: Envelope] = [k: .income(late.id)]
        #expect(try coverage(assignments).items[0].warnings == [.fundingAfterDue])
        #expect(try coverage(assignments).complete == false)
        assignments[k] = .openingCash
        #expect(assignments.count == 1)
        #expect(try coverage(assignments).complete)
        #expect(try coverage(assignments).confirmedFunds == money("110"))
        #expect(try coverage([k: .income(expected.id)]).items[0].warnings == [.expectedNotConfirmed, .overcommitted, .fundingAfterDue])
        #expect(try coverage([:], overrides: [k: OccurrenceOverride(paid: true)]).complete)
        #expect(try coverage(assignments).paidCashAssumption.contains("already reflects paid"))
    }

    @Test func sharedIncomeOvercommitmentAndUnknownPreventConclusion() throws {
        let income = Income(id: UUID(), date: try start.adding(days: 1), amount: try money("50"), status: .confirmed)
        let bills = try ["30", "30"].map { Bill(id: UUID(), title: "A", firstDue: try start.adding(days: 1), recurrence: .once, amount: try money($0)) }
        let keys = try bills.map { try #require($0.occurrences(from: start, days: 1).first).key }
        let assignments = Dictionary(uniqueKeysWithValues: keys.map { ($0, Envelope.income(income.id)) })
        let sheet = Worksheet(currency: "USD", openingCash: try money("100"), openingDate: start, incomes: [income], bills: bills, assignments: assignments)
        #expect(try sheet.coverage(from: start, days: 1).items.allSatisfy { $0.warnings == [.overcommitted] })
        let unknown = Bill(id: UUID(), title: "Unknown", firstDue: try start.adding(days: 1), recurrence: .once, amount: nil)
        let uk = try #require(unknown.occurrences(from: start, days: 1).first).key
        var mixed = [keys[0]: Envelope.income(income.id)]; mixed[uk] = .income(income.id)
        let uncertain = Worksheet(currency: "USD", openingCash: try money(), openingDate: start, incomes: [income], bills: [bills[0],unknown], assignments: mixed)
        #expect(try uncertain.coverage(from: start, days: 1).items.allSatisfy { $0.warnings.contains(.unknownAmount) })
        #expect(try uncertain.coverage(from: start, days: 1).complete == false)
    }
    @Test func collectionCapsAndCanonicalReferences() throws {
        let bill = Bill(id: UUID(), title: "A", firstDue: start, recurrence: .monthly, amount: nil)
        let badKey = "\(bill.id.uuidString)/2025-01"
        #expect(throws: PlanningError.self) { try bill.occurrences(from: start, days: 1, overrides: [badKey: OccurrenceOverride()]) }
        let longTitle = Bill(id: UUID(), title: String(repeating: "a", count: 201), firstDue: start, recurrence: .once, amount: nil)
        #expect(throws: PlanningError.self) { try JSONDecoder().decode(Bill.self, from: JSONEncoder().encode(longTitle)) }
        let incomes = try (0...1000).map { _ in Income(id: UUID(), date: start, amount: try money(), status: .confirmed) }
        #expect(throws: PlanningError.self) { try roundtrip(Worksheet(currency: "USD", openingCash: money(), openingDate: start, incomes: incomes)) }
        // All references are individually valid; only the count makes these invalid.
        let keys = (0...10_000).map { n in "\(bill.id.uuidString)/\(2025 + n / 12)-\(n % 12 + 1)" }
        let overrides = Dictionary(uniqueKeysWithValues: keys.map { ($0, OccurrenceOverride(paid: true)) })
        let assignments = Dictionary(uniqueKeysWithValues: keys.map { ($0, Envelope.openingCash) })
        #expect(throws: PlanningError.self) { try roundtrip(Worksheet(currency: "USD", openingCash: money(), openingDate: start, bills: [bill], overrides: overrides)) }
        #expect(throws: PlanningError.self) { try roundtrip(Worksheet(currency: "USD", openingCash: money(), openingDate: start, bills: [bill], assignments: assignments)) }
    }

    @Test func horizonIsInclusiveAndIncomeIsDated() throws {
        let last = try start.adding(days: 90)
        let outside = try start.adding(days: 91)
        let bills = [Bill(id: UUID(), title: "Last", firstDue: last, recurrence: .once, amount: nil), Bill(id: UUID(), title: "Outside", firstDue: outside, recurrence: .once, amount: nil)]
        let incomes = [Income(id: UUID(), date: outside, amount: try money("100"), status: .confirmed), Income(id: UUID(), date: try start.adding(days: -1), amount: try money("100"), status: .confirmed)]
        let sheet = Worksheet(currency: "USD", openingCash: try money("1"), openingDate: start, incomes: incomes, bills: bills)
        let coverage = try sheet.coverage(from: start, days: 90)
        #expect(coverage.items.count == 1)
        #expect(try coverage.confirmedFunds == money("1"))
    }

}
