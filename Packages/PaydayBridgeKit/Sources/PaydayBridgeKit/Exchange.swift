import Foundation

/// Portable, bounded backup/restore and worksheet CSV. No network or account.
public struct WorksheetBackupPreview: Sendable {
    public let snapshot: WorksheetSnapshot
    public var currency: String { snapshot.worksheet.currency }
    public var openingDate: CivilDate { snapshot.worksheet.openingDate }
    public var billCount: Int { snapshot.worksheet.bills.count }
    public var incomeCount: Int { snapshot.worksheet.incomes.count }
    public var hasDraft: Bool { snapshot.draft != nil }

    public init(data: Data) throws { snapshot = try WorksheetSnapshot.decode(data) }
}

extension WorksheetSnapshot {
    /// Encodes the exact saved plan + optional draft; revision is for preview,
    /// not a way to override newer local revisions on restore.
    public func backupData() throws -> Data { try encoded() }
}

/// RFC 4180 quoted cells plus spreadsheet formula neutralization. Always quote
/// cells to preserve commas/newlines and embedded quotes; prefix a leading
/// formula introducer (after whitespace/control padding) with an apostrophe.
private func csvCell(_ value: String) -> String {
    let first = value.drop(while: { $0.isWhitespace || $0.isNewline }).first
    let safe = first.map({ "=+-@".contains($0) }) == true ? "'" + value : value
    return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

private func civil(_ date: CivilDate) -> String {
    String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
}

extension Worksheet {
    /// 90-day bounded view, not an all-time financial ledger. Unknown bill
    /// amounts remain explicit and expected incomes never claim coverage.
    public func csvData(days: Int = 90) throws -> Data {
        try validate()
        guard (1...90).contains(days) else { throw StorageFailure.invalidData }
        let coverage = try coverage(from: openingDate, days: days)
        var lines = [["type", "date", "title", "amount", "currency", "status", "funding", "warnings"]]
        lines.append(["opening cash", civil(openingDate), "Manual opening cash", NSDecimalNumber(decimal: openingCash.value).stringValue, currency, "entered estimate", "counted once", "not bank verified"])
        for income in incomes {
            lines.append(["income", civil(income.date), "Manual income", NSDecimalNumber(decimal: income.amount.value).stringValue,
                          currency, income.status == .confirmed ? "confirmed estimate" : "expected only; not confirmed coverage", "", "not bank verified"])
        }
        for bill in bills {
            let related = overrides.filter { $0.key.hasPrefix("\(bill.id.uuidString)/") }
            for item in try bill.occurrences(from: openingDate, days: days, overrides: related) {
                let funding: String
                switch assignments[item.key] {
                case .openingCash: funding = "opening cash"
                case let .income(id):
                    if let income = incomes.first(where: { $0.id == id }) {
                        funding = income.status == .confirmed ? "confirmed estimate" : "expected only; not confirmed coverage"
                    } else { funding = "unknown" }
                case nil: funding = "unassigned"
                }
                let warnings = coverage.items.first(where: { $0.key == item.key })?.warnings.map(\.rawValue).sorted().joined(separator: "; ") ?? ""
                lines.append(["bill", civil(item.due), bill.title, item.amount.map { NSDecimalNumber(decimal: $0.value).stringValue } ?? "unknown amount",
                              currency, item.paid ? "paid (manual)" : "unpaid (manual)", funding, warnings])
            }
        }
        // CRLF remains inside quoted user cells; Excel/Numbers import safely.
        return Data((lines.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
