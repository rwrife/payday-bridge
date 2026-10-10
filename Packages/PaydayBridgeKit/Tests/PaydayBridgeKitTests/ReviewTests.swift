import Foundation
import Testing
@testable import PaydayBridgeKit

struct ReviewTests {
    func d(_ day: Int, _ month: Int = 1) throws -> CivilDate { try CivilDate(year: 2025, month: month, day: day) }
    func m(_ value: String) throws -> Money { try Money(value, currency: "USD") }

    @Test func offWindowReservations() throws {
        let monthly = Bill(id: UUID(), title: "Recurring", firstDue: try d(5), recurrence: .monthly, amount: try m("60"))
        let once = Bill(id: UUID(), title: "Once", firstDue: try d(20), recurrence: .once, amount: try m("60"))
        let keys = [monthly.key(try d(5)), monthly.key(try d(5, 2)), once.key(try d(20))]
        let assignments = Dictionary(uniqueKeysWithValues: keys.map { ($0, Envelope.openingCash) })
        func coverage(_ start: CivilDate, _ days: Int) throws -> Coverage {
            try Worksheet(currency: "USD", openingCash: m("100"), openingDate: d(1), bills: [monthly, once], assignments: assignments).coverage(from: start, days: days)
        }
        for (start, days) in [(try d(1), 30), (try d(1), 10), (try d(15), 10)] {
            #expect(try coverage(start, days).items.allSatisfy { $0.warnings.contains(.overcommitted) })
        }
        let unknown = Bill(id: UUID(), title: "Unknown", firstDue: try d(5, 3), recurrence: .monthly, amount: nil)
        let sheet = Worksheet(currency: "USD", openingCash: try m("100"), openingDate: try d(1), bills: [once, unknown], assignments: [keys[2]: .openingCash, unknown.key(try d(5, 3)): .openingCash])
        #expect(try sheet.coverage(from: d(15), days: 10).items[0].warnings.contains(.unknownAmount))
    }
    @Test func paidIncomeStillReservesButSnapshotCashDoesNot() throws {
        let income = Income(id: UUID(), date: try d(2), amount: try m("100"), status: .confirmed)
        let bills = try [3, 20].map { Bill(id: UUID(), title: "Bill", firstDue: try d($0), recurrence: .once, amount: try m("60")) }
        let keys = bills.map { $0.key($0.firstDue) }
        for envelope in [Envelope.openingCash, .income(income.id)] {
            let sheet = Worksheet(currency: "USD", openingCash: try m("100"), openingDate: try d(1), incomes: [income], bills: bills, overrides: [keys[0]: OccurrenceOverride(paid: true)], assignments: Dictionary(uniqueKeysWithValues: keys.map { ($0, envelope) }))
            for start in [try d(1), try d(15)] {
                let result = try sheet.coverage(from: start, days: 25)
                #expect(result.items.first { $0.key == keys[1] }?.warnings.contains(.overcommitted) == (envelope == .income(income.id)))
            }
        }
    }
    @Test func offWindowPaidUnknownReservesOnlyLaterIncome() throws {
        let income = Income(id: UUID(), date: try d(2), amount: try m("100"), status: .confirmed)
        let bills = try [3, 20].map { Bill(id: UUID(), title: "Bill", firstDue: try d($0), recurrence: .once, amount: try m("10")) }
        let keys = bills.map { $0.key($0.firstDue) }
        for envelope in [Envelope.openingCash, .income(income.id)] {
            let sheet = Worksheet(currency: "USD", openingCash: try m("100"), openingDate: try d(1), incomes: [income], bills: bills, overrides: [keys[0]: OccurrenceOverride(amountOverride: .unknown, paid: true)], assignments: Dictionary(uniqueKeysWithValues: keys.map { ($0, envelope) }))
            let result = try sheet.coverage(from: d(15), days: 10)
            #expect(result.items[0].warnings.contains(.unknownAmount) == (envelope == .income(income.id)))
        }
    }

    @Test func snapshotIncludesIncomeOnOrBeforeCivilDate() throws {
        let bill = Bill(id: UUID(), title: "Bill", firstDue: try d(5), recurrence: .once, amount: try m("60"))
        let cashBill = Bill(id: UUID(), title: "Cash bill", firstDue: try d(6), recurrence: .once, amount: try m("60"))
        for day in [1, 2, 3] {
            let income = Income(id: UUID(), date: try d(day), amount: try m("100"), status: .confirmed)
            let sheet = Worksheet(currency: "USD", openingCash: try m("100"), openingDate: try d(2), incomes: [income], bills: [bill, cashBill], assignments: [bill.key(bill.firstDue): .income(income.id), cashBill.key(cashBill.firstDue): .openingCash])
            let result = try sheet.coverage(from: d(2), days: 5)
            #expect(try result.confirmedFunds == m(day <= 2 ? "100" : "200"))
            #expect(result.complete == (day > 2))
            #expect(result.snapshotAssumption.contains("on or before openingDate"))
            #expect(result.items[0].warnings.contains(.snapshotAlreadyIncluded) == (day <= 2))
        }
    }
    @Test func explicitUnknownOverrideVersusInheritance() throws {
        for base in ["0", "60"] {
            let bill = Bill(id: UUID(), title: "Bill", firstDue: try d(5), recurrence: .monthly, amount: try m(base))
            let key = bill.key(bill.firstDue)
            // Decode the proposed input shape to reproduce the old decoder silently inheriting.
            let unknown = try JSONDecoder().decode(OccurrenceOverride.self, from: Data(#"{"amountOverride":{"unknown":{}},"paid":false}"#.utf8))
            let sheet = Worksheet(currency: "USD", openingCash: try m("100"), openingDate: try d(1), bills: [bill], overrides: [key: unknown], assignments: [key: .openingCash])
            #expect(try bill.occurrences(from: d(1), days: 10, overrides: [key: unknown])[0].amount == nil)
            #expect(try sheet.coverage(from: d(1), days: 10).items[0].warnings == [.unknownAmount])
            #expect(try bill.occurrences(from: d(1), days: 10, overrides: [key: OccurrenceOverride()])[0].amount == m(base))
            #expect(unknown.amountOverride == .unknown)
            #expect(OccurrenceOverride(amountOverride: .unknown).amountOverride == .unknown)
            let value = OccurrenceOverride(amountOverride: .value(try m("25")))
            #expect(try bill.occurrences(from: d(1), days: 10, overrides: [key: value])[0].amount == m("25"))
            let restored = try JSONDecoder().decode(Worksheet.self, from: JSONEncoder().encode(sheet))
            #expect(try restored.coverage(from: d(1), days: 10).complete == false)
        }
    }
    @Test func movedStartPreservesEarlierMonthlyHistory() throws {
        let id = UUID()
        let old = Bill(id: id, title: "Bill", firstDue: try d(31), recurrence: .monthly, amount: try m("60"))
        let key = old.key(try d(28, 2))
        let moved = Bill(id: id, title: "Bill", firstDue: try d(31, 5), recurrence: .monthly, amount: try m("90"))
        for paid in [true, false] {
            let overrides = [key: OccurrenceOverride(amount: try m("25"), paid: paid)]
            let occurrences = try moved.occurrences(from: d(1, 2), days: 60, overrides: overrides)
            #expect(occurrences.count == 1)
            #expect(occurrences.first?.key == key)
            #expect(occurrences.first?.due == (try d(28, 2)))
            #expect(occurrences.first?.paid == paid)
            #expect(try occurrences.first?.amount == m("25"))
            let sheet = Worksheet(currency: "USD", openingCash: try m("30"), openingDate: try d(1), bills: [moved], overrides: overrides, assignments: [key: .openingCash])
            let restored = try JSONDecoder().decode(Worksheet.self, from: JSONEncoder().encode(sheet))
            #expect(try restored.coverage(from: d(1, 2), days: 60).items.count == 1)
        }
        #expect(try moved.occurrences(from: d(1, 2), days: 60).isEmpty)
        #expect(moved.accepts("\(id.uuidString)/2025-02") == false)
    }
    @Test func derivedResultsCannotBeImported() {
        func decodable(_ type: Any.Type) -> Bool { type is any Decodable.Type }
        func sendable<T: Sendable>(_ type: T.Type) {}
        #expect(!decodable(Coverage.self))
        #expect(!decodable(CoverageItem.self))
        sendable(Coverage.self)
        sendable(CoverageItem.self)
    }
}
