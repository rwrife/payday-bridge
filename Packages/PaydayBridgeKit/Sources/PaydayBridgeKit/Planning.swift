import Foundation

public enum PlanningError: Error { case invalid }
private func require(_ condition: Bool) throws { if !condition { throw PlanningError.invalid } }

public struct Money: Codable, Sendable, Equatable {
    public let value: Decimal
    public let currency: String
    // Deliberate ceiling: nine integer digits; a small explicit ISO currency allowlist.
    public static let precisions = ["USD": 2, "EUR": 2, "GBP": 2, "CAD": 2, "AUD": 2, "CHF": 2, "NZD": 2, "JPY": 0]
    public init(_ text: String, currency: String) throws {
        guard let precision = Self.precisions[currency] else { throw PlanningError.invalid }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        try require(parts.count == 1 || parts.count == 2)
        try require(parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
        try require(parts[0].count <= 9 && (parts.count == 1 || parts[1].count <= precision))
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { throw PlanningError.invalid }
        self.value = value; self.currency = currency
    }
    public static func + (lhs: Self, rhs: Self) throws -> Self {
        try require(lhs.currency == rhs.currency)
        return try Self(NSDecimalNumber(decimal: lhs.value + rhs.value).stringValue, currency: lhs.currency)
    }
    private enum CodingKeys: String, CodingKey { case amount, currency }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(c.decode(String.self, forKey: .amount), currency: c.decode(String.self, forKey: .currency))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(NSDecimalNumber(decimal: value).stringValue, forKey: .amount)
        try c.encode(currency, forKey: .currency)
    }
}

public struct CivilDate: Codable, Sendable, Hashable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int
    private static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    public init(year: Int, month: Int, day: Int) throws {
        try require((1900...9999).contains(year) && (1...12).contains(month) && (1...31).contains(day))
        let components = DateComponents(year: year, month: month, day: day)
        guard let d = Self.calendar.date(from: components) else { throw PlanningError.invalid }
        try require(Self.calendar.dateComponents([.year, .month, .day], from: d) == components)
        self.year = year; self.month = month; self.day = day
    }
    private var date: Date { Self.calendar.date(from: DateComponents(year: year, month: month, day: day))! }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.date < rhs.date }
    func adding(days: Int) throws -> Self {
        let c = Self.calendar.dateComponents([.year, .month, .day], from: Self.calendar.date(byAdding: .day, value: days, to: date)!)
        return try Self(year: c.year!, month: c.month!, day: c.day!)
    }
    static func clamped(year: Int, month: Int, day: Int) throws -> Self {
        let first = try Self(year: year, month: month, day: 1)
        return try Self(year: year, month: month, day: min(day, calendar.range(of: .day, in: .month, for: first.date)!.count))
    }
    private enum CodingKeys: String, CodingKey { case year, month, day }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(year: c.decode(Int.self, forKey: .year), month: c.decode(Int.self, forKey: .month), day: c.decode(Int.self, forKey: .day))
    }
}
public enum Recurrence: String, Codable, Sendable { case once, monthly }
public enum AmountOverride: Codable, Sendable, Equatable { case unknown, value(Money) }
public struct OccurrenceOverride: Codable, Sendable {
    public var amountOverride: AmountOverride?
    public var paid: Bool
    // nil in the convenience API means inherit; use .unknown to clear a known amount.
    public init(amount: Money? = nil, paid: Bool = false) {
        self.amountOverride = amount.map(AmountOverride.value); self.paid = paid
    }
    public init(amountOverride: AmountOverride?, paid: Bool = false) {
        self.amountOverride = amountOverride; self.paid = paid
    }
    public var amount: Money? {
        get { if case let .value(value) = amountOverride { return value }; return nil }
        set { amountOverride = newValue.map(AmountOverride.value) }
    }
    func resolved(_ base: Money?) -> Money? {
        switch amountOverride { case nil: return base; case .unknown: return nil; case let .value(value): return value }
    }
}
public struct Occurrence: Codable, Sendable {
    public let key: String
    public let due: CivilDate
    public let amount: Money?
    public let paid: Bool
    init(key: String, due: CivilDate, amount: Money?, paid: Bool) {
        self.key = key; self.due = due; self.amount = amount; self.paid = paid
    }
    private enum CodingKeys: String, CodingKey { case key, due, amount, paid }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try c.decode(String.self, forKey: .key), due: try c.decode(CivilDate.self, forKey: .due), amount: try c.decodeIfPresent(Money.self, forKey: .amount), paid: try c.decode(Bool.self, forKey: .paid))
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        try require(parts.count == 2)
        guard let id = UUID(uuidString: String(parts[0])) else { throw PlanningError.invalid }
        try require(String(parts[0]) == id.uuidString && (parts[1] == "once" || parts[1] == "\(due.year)-\(due.month)"))
    }
}
public struct Bill: Codable, Sendable {
    public let id: UUID
    public let title: String
    public let firstDue: CivilDate
    public let recurrence: Recurrence
    public let amount: Money?
    public init(id: UUID, title: String, firstDue: CivilDate, recurrence: Recurrence, amount: Money?) {
        self.id = id; self.title = title; self.firstDue = firstDue; self.recurrence = recurrence; self.amount = amount
    }
    func validate() throws { try require(!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 200) }
    func key(_ due: CivilDate) -> String { "\(id.uuidString)/" + (recurrence == .monthly ? "\(due.year)-\(due.month)" : "once") }
    func canonicalDate(_ key: String) -> CivilDate? {
        if recurrence == .once { return key == self.key(firstDue) ? firstDue : nil }
        let prefix = "\(id.uuidString)/"
        guard key.hasPrefix(prefix) else { return nil }
        let parts = key.dropFirst(prefix.count).split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]),
              let d = try? CivilDate.clamped(year: y, month: m, day: firstDue.day),
              key == self.key(d) else { return nil }
        return d
    }
    func accepts(_ key: String) -> Bool { canonicalDate(key) != nil }
    func occurrence(on due: CivilDate, override: OccurrenceOverride?) -> Occurrence {
        Occurrence(key: key(due), due: due, amount: (override ?? OccurrenceOverride()).resolved(amount), paid: override?.paid ?? false)
    }
    public func occurrences(from start: CivilDate, days: Int, overrides: [String: OccurrenceOverride] = [:]) throws -> [Occurrence] {
        try validate(); try require((1...90).contains(days) && overrides.count <= 10_000)
        let end = try start.adding(days: days)
        var result: [Occurrence] = []
        func append(_ due: CivilDate) {
            if due >= start && due <= end && (due >= firstDue || overrides[key(due)] != nil) {
                result.append(occurrence(on: due, override: overrides[key(due)]))
            }
        }
        if recurrence == .once { append(firstDue) } else {
            var y = start.year; var m = start.month
            while y < end.year || (y == end.year && m <= end.month) {
                append(try CivilDate.clamped(year: y, month: m, day: firstDue.day))
                m += 1; if m == 13 { y += 1; m = 1 }
            }
        }
        for (k, o) in overrides { try require(accepts(k)); if let a = o.amount, let base = amount { try require(a.currency == base.currency) } }
        return result
    }
    private enum CodingKeys: String, CodingKey { case id, title, firstDue, recurrence, amount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), title: try c.decode(String.self, forKey: .title), firstDue: try c.decode(CivilDate.self, forKey: .firstDue), recurrence: try c.decode(Recurrence.self, forKey: .recurrence), amount: try c.decodeIfPresent(Money.self, forKey: .amount))
        try validate()
    }
}
public enum IncomeStatus: String, Codable, Sendable { case expected, confirmed }
public struct Income: Codable, Sendable {
    public let id: UUID
    public let date: CivilDate
    public let amount: Money
    public let status: IncomeStatus
    public init(id: UUID, date: CivilDate, amount: Money, status: IncomeStatus) { self.id = id; self.date = date; self.amount = amount; self.status = status }
}
public enum Envelope: Codable, Sendable, Hashable { case openingCash, income(UUID) }
public enum CoverageWarning: String, Codable, Sendable { case unknownAmount, unassigned, expectedNotConfirmed, fundingAfterDue, overcommitted, snapshotAlreadyIncluded }
public struct CoverageItem: Sendable {
    public let key: String
    public let paid: Bool
    public let warnings: Set<CoverageWarning>
}
public struct Coverage: Sendable {
    public let confirmedFunds: Money
    public let expectedFunds: Money
    public let items: [CoverageItem]
    public var complete: Bool { items.allSatisfy { $0.warnings.isEmpty } }
    public var manualEstimateDisclaimer: String { PaydayBridgeKit.planningDisclaimer }
    public var snapshotAssumption: String { "Opening cash includes all cash received on or before openingDate; income on those civil dates cannot fund a separate envelope." }
    public var paidCashAssumption: String { "Opening cash already reflects paid bills assigned to it; paid bills assigned to income after the snapshot still reserve that income." }
}
public struct Worksheet: Codable, Sendable {
    public let currency: String
    public let openingCash: Money
    public let openingDate: CivilDate
    public let incomes: [Income]
    public let bills: [Bill]
    public let overrides: [String: OccurrenceOverride]
    public let assignments: [String: Envelope]
    public init(currency: String, openingCash: Money, openingDate: CivilDate, incomes: [Income] = [], bills: [Bill] = [], overrides: [String: OccurrenceOverride] = [:], assignments: [String: Envelope] = [:]) {
        self.currency = currency; self.openingCash = openingCash; self.openingDate = openingDate; self.incomes = incomes; self.bills = bills; self.overrides = overrides; self.assignments = assignments
    }
    public func validate() throws {
        try require(Money.precisions[currency] != nil && openingCash.currency == currency)
        // Deliberate input ceilings, not long-term forecasting or storage/import limits.
        try require(bills.count <= 1_000 && incomes.count <= 1_000 && overrides.count <= 10_000 && assignments.count <= 10_000)
        let ids = bills.map(\.id) + incomes.map(\.id)
        try require(Set(ids).count == ids.count)
        for b in bills { try b.validate(); try require(b.amount == nil || b.amount?.currency == currency) }
        for i in incomes { try require(i.amount.currency == currency) }
        for (k, o) in overrides { try require(bills.contains { $0.accepts(k) }); try require(o.amount == nil || o.amount?.currency == currency) }
        for (k, e) in assignments {
            try require(bills.contains { $0.accepts(k) })
            if case let .income(id) = e { try require(incomes.contains { $0.id == id }) }
        }
    }
    public func coverage(from start: CivilDate, days: Int) throws -> Coverage {
        try validate(); try require((1...90).contains(days) && start >= openingDate)
        let end = try start.adding(days: days)
        let active = incomes.filter { $0.date > openingDate && $0.date <= end }
        var confirmed = openingCash; var expected = try Money("0", currency: currency)
        for i in active { if i.status == .confirmed { confirmed = try confirmed + i.amount } else { expected = try expected + i.amount } }
        var occurrences: [Occurrence] = []
        for bill in bills {
            let matching = overrides.filter { bill.accepts($0.key) }
            occurrences += try bill.occurrences(from: start, days: days, overrides: matching)
        }
        occurrences.sort { lhs, rhs in
            if lhs.due == rhs.due { return lhs.key < rhs.key }
            return lhs.due < rhs.due
        }
        var commitments: [Envelope: Decimal] = [:]
        var uncertain: Set<Envelope> = []
        var reserved = Dictionary(uniqueKeysWithValues: occurrences.map { ($0.key, $0) })
        for key in assignments.keys where reserved[key] == nil {
            let bill = bills.first { $0.accepts(key) }!
            reserved[key] = bill.occurrence(on: bill.canonicalDate(key)!, override: overrides[key])
        }
        for o in reserved.values {
            if o.paid {
                guard case let .income(id) = assignments[o.key],
                      incomes.first(where: { $0.id == id })!.date > openingDate else { continue }
            }
            if let e = assignments[o.key] { if let a = o.amount { commitments[e, default: 0] += a.value } else { uncertain.insert(e) } }
        }
        let items = occurrences.map { o -> CoverageItem in
            var warnings: Set<CoverageWarning> = []
            if !o.paid {
                if o.amount == nil { warnings.insert(.unknownAmount) }
                if let e = assignments[o.key] {
                    let fundingDate: CivilDate; let funds: Decimal
                    switch e {
                    case .openingCash: fundingDate = openingDate; funds = openingCash.value
                    case let .income(id):
                        let i = incomes.first { $0.id == id }!
                        fundingDate = i.date
                        funds = i.status == .confirmed && i.date > openingDate && i.date <= end ? i.amount.value : 0
                        if i.status == .expected { warnings.insert(.expectedNotConfirmed) }
                        if i.date <= openingDate { warnings.insert(.snapshotAlreadyIncluded) }
                    }
                    if fundingDate > o.due { warnings.insert(.fundingAfterDue) }
                    if commitments[e, default: 0] > funds { warnings.insert(.overcommitted) }
                    if uncertain.contains(e) { warnings.insert(.unknownAmount) }
                } else { warnings.insert(.unassigned) }
            }
            return CoverageItem(key: o.key, paid: o.paid, warnings: warnings)
        }
        return Coverage(confirmedFunds: confirmed, expectedFunds: expected, items: items)
    }
    private enum CodingKeys: String, CodingKey { case currency, openingCash, openingDate, incomes, bills, overrides, assignments }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(currency: try c.decode(String.self, forKey: .currency), openingCash: try c.decode(Money.self, forKey: .openingCash), openingDate: try c.decode(CivilDate.self, forKey: .openingDate), incomes: try c.decode([Income].self, forKey: .incomes), bills: try c.decode([Bill].self, forKey: .bills), overrides: try c.decode([String: OccurrenceOverride].self, forKey: .overrides), assignments: try c.decode([String: Envelope].self, forKey: .assignments))
        try validate()
    }
}
