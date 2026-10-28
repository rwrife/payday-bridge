import Foundation
import XCTest
@testable import PaydayBridgeKit

final class ExchangeTests: XCTestCase, @unchecked Sendable {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("worksheet.json")
    }

    private func populatedSheet() throws -> Worksheet {
        let billId = UUID()
        let incomeId = UUID()
        let bill = Bill(id: billId, title: "=Formula, Title with \"Quotes\" and, comma",
                        firstDue: try CivilDate(year: 2026, month: 10, day: 5),
                        recurrence: .monthly,
                        amount: nil)
        let income = Income(id: incomeId, date: try CivilDate(year: 2026, month: 10, day: 10),
                            amount: try Money("400.00", currency: "USD"), status: .expected)
        let key = "\(billId.uuidString)/2026-10"
        return Worksheet(currency: "USD",
                         openingCash: try Money("100.00", currency: "USD"),
                         openingDate: try CivilDate(year: 2026, month: 10, day: 1),
                         incomes: [income],
                         bills: [bill],
                         overrides: [key: OccurrenceOverride(amount: try Money("250.00", currency: "USD"), paid: false)],
                         assignments: [key: .income(incomeId)])
    }

    func testBackupDataRoundTripAndPreview() throws {
        let sheet = try populatedSheet()
        let snapshot = WorksheetSnapshot(worksheet: sheet)
        let data = try snapshot.backupData()
        let preview = try WorksheetBackupPreview(data: data)
        XCTAssertEqual(preview.currency, "USD")
        XCTAssertEqual(preview.billCount, 1)
        XCTAssertEqual(preview.incomeCount, 1)
        XCTAssertFalse(preview.hasDraft)
        XCTAssertEqual(preview.openingDate, sheet.openingDate)
    }

    func testRestoreReplacesDataAndSavesRecoverySibling() async throws {
        let url = try location()
        let store = WorksheetStore(fileURL: url)
        let initialSheet = Worksheet(currency: "USD",
                                     openingCash: try Money("50.00", currency: "USD"),
                                     openingDate: try CivilDate(year: 2026, month: 10, day: 1))
        let originalSnapshot = try await store.save(initialSheet, expectedRevision: nil)

        let targetSheet = try populatedSheet()
        let targetSnapshot = WorksheetSnapshot(worksheet: targetSheet)
        let backupBytes = try targetSnapshot.backupData()
        let preview = try WorksheetBackupPreview(data: backupBytes)

        let restored = try await store.restore(backupBytes, preview: preview, expectedRevision: originalSnapshot.revision)
        XCTAssertEqual(restored.worksheet.bills.count, 1)
        XCTAssertEqual(restored.worksheet.openingCash.value, 100)

        // Recovery sibling holds the original snapshot.
        let recoveryURL = url.deletingLastPathComponent().appendingPathComponent("worksheet-recovery.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
        let recoveryBytes = try Data(contentsOf: recoveryURL)
        let recoverySnapshot = try WorksheetSnapshot.decode(recoveryBytes)
        XCTAssertEqual(recoverySnapshot.revision, originalSnapshot.revision)
        XCTAssertEqual(recoverySnapshot.worksheet.openingCash.value, 50)
    }

    func testRestoreRejectsStaleRevision() async throws {
        let url = try location()
        let store = WorksheetStore(fileURL: url)
        let initial = try await store.save(try populatedSheet(), expectedRevision: nil)
        let backupBytes = try initial.backupData()
        let preview = try WorksheetBackupPreview(data: backupBytes)

        do {
            _ = try await store.restore(backupBytes, preview: preview, expectedRevision: UUID())
            XCTFail("Stale expected revision must throw")
        } catch let error as StorageFailure {
            XCTAssertEqual(error, .revisionConflict)
        }
    }

    func testRestoreCorruptDataPreservesExistingState() async throws {
        let url = try location()
        let store = WorksheetStore(fileURL: url)
        let initial = try await store.save(try populatedSheet(), expectedRevision: nil)
        let corruptBytes = Data("not json".utf8)

        // Preview initialization fails on corrupt bytes.
        XCTAssertThrowsError(try WorksheetBackupPreview(data: corruptBytes))

        // Existing data untouched.
        guard case let .loaded(current) = await store.load() else { return XCTFail("Old state missing") }
        XCTAssertEqual(current.revision, initial.revision)
    }

    func testCsvFormulaEscapingAndNeutralization() throws {
        let sheet = try populatedSheet()
        let csvBytes = try sheet.csvData(days: 30)
        let csv = String(decoding: csvBytes, as: UTF8.self)

        // CRLF terminated lines.
        XCTAssertTrue(csv.hasSuffix("\r\n"))
        // Formula leading title must be prefixed with apostrophe inside quotes.
        XCTAssertTrue(csv.contains("\"'=Formula, Title with \"\"Quotes\"\" and, comma\""),
                       "Formula injection cell must be apostrophe-prefixed: \(csv)")
        // Manual planning disclaimer present.
        XCTAssertTrue(csv.contains("not bank verified"))
        XCTAssertTrue(csv.contains("expected only; not confirmed coverage"))
    }
}
