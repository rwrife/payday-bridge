import Foundation
import XCTest
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif
@testable import PaydayBridgeKit

final class StorageTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("worksheet.json")
    }
    private func sheet(_ amount: String = "100") throws -> Worksheet {
        Worksheet(currency: "USD", openingCash: try Money(amount, currency: "USD"), openingDate: try CivilDate(year: 2026, month: 10, day: 1))
    }
    private func loaded(_ store: WorksheetStore) async throws -> WorksheetSnapshot {
        guard case let .loaded(snapshot) = await store.load() else { throw StorageFailure.invalidData }
        return snapshot
    }
    private func failure(_ expected: StorageFailure, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? StorageFailure, expected); XCTAssertFalse(expected.recoveryAction.isEmpty) }
    }

    func testMissingPlanIsNotAnUnreadablePlan() async throws {
        let url = try location()
        let store = WorksheetStore(fileURL: url)
        guard case .missing = await store.load() else { return XCTFail("Absent file must allow initial save") }
        let saved = try await store.save(sheet(), expectedRevision: nil)
        XCTAssertEqual(saved.worksheet.openingCash.value, 100)
        #if os(macOS)
        // POSIX unreadability is a host check; iOS sandbox chmod behavior differs.
        // Root can read mode-000 files, so this assertion needs an unprivileged host.
        guard getuid() != 0 else { throw XCTSkip("Permission denial requires a non-root macOS host") }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        guard case .recovery(.unreadable) = await store.load() else { return XCTFail("Unreadable file is not missing") }
        await failure(.unreadable) { _ = try await store.save(self.sheet("200"), expectedRevision: nil) }
        #endif
    }

    func testFixturesAndFailedReadNeverOverwrite() async throws {
        for (name, expected) in [("truncated", StorageFailure.invalidData), ("future", .unsupportedSchema(2))] {
            let url = try location(); let bytes = try fixture(name)
            try bytes.write(to: url)
            let store = WorksheetStore(fileURL: url)
            guard case let .recovery(error) = await store.load() else { return XCTFail("Expected recovery") }
            XCTAssertEqual(error, expected)
            await failure(expected) { _ = try await store.save(self.sheet(), expectedRevision: nil) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        let url = try location()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        guard case .recovery(.unreadable) = await WorksheetStore(fileURL: url).load() else { return XCTFail("Expected unreadable") }
    }

    func testStableIDsAndAtomicReplacementAcrossRestart() async throws {
        let url = try location(); try fixture("valid").write(to: url)
        try fixture("truncated").write(to: url.deletingLastPathComponent().appendingPathComponent(".worksheet-interrupted.tmp"))
        let store = WorksheetStore(fileURL: url); let before = try await loaded(store)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(".worksheet-interrupted.tmp"))
        let saved = try await store.save(before.worksheet, expectedRevision: before.revision)
        let restarted = try await loaded(WorksheetStore(fileURL: url))
        XCTAssertNotEqual(saved.revision, before.revision)
        XCTAssertEqual(restarted.revision, saved.revision)
        XCTAssertEqual(restarted.worksheet.bills[0].id, before.worksheet.bills[0].id)
        XCTAssertEqual(restarted.worksheet.assignments, before.worksheet.assignments)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        #if os(iOS)
        let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
        #if targetEnvironment(simulator)
        // The simulator's host filesystem does not report data-protection classes
        // (attribute reads back nil, observed in CI). Writes above still request
        // .complete and must not throw; enforcement needs physical-device validation.
        XCTAssertTrue(protection == nil || protection == .complete)
        #else
        XCTAssertEqual(protection, .complete)
        #endif
        #endif
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).filter { $0.hasSuffix(".tmp") }, [])
    }

    #if os(Linux)
    // Re-exec XCTest through Process: no fork into a live Swift runtime. SIGKILL
    // prevents transaction defers, file cleanup, and lock release from running.
    func testAbruptSubprocessCrashSnapshotsAndReleasedLock() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let mode = environment["WORKSHEET_CRASH_MODE"] {
            let url = URL(fileURLWithPath: try XCTUnwrap(environment["WORKSHEET_CRASH_PATH"]))
            let expectedURL = url.appendingPathExtension("expected")
            if mode == "crash" {
                let phase = try XCTUnwrap(environment["WORKSHEET_CRASH_PHASE"])
                let current = try await loaded(WorksheetStore(fileURL: url))
                let crashing = WorksheetStore(fileURL: url) { point in
                    // Record the complete candidate before termination, including
                    // its randomly generated revision and the preserved draft.
                    if point == .staged {
                        let directory = url.deletingLastPathComponent()
                        let temporary = try XCTUnwrap(FileManager.default.contentsOfDirectory(
                            at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "tmp" })
                        try Data(contentsOf: temporary).write(to: expectedURL)
                    }
                    let reached = (phase == "staged" && point == .staged)
                        || (phase == "beforeReplace" && point == .beforeReplace)
                        || (phase == "afterRename" && point == .beforeDirectorySync)
                    if reached {
                        _ = kill(getpid(), SIGKILL)
                        _exit(99)
                    }
                }
                _ = try await crashing.save(sheet("300"), expectedRevision: current.revision)
                XCTFail("Child did not terminate at requested checkpoint")
            } else {
                XCTAssertEqual(mode, "verify")
                let expected = try Data(contentsOf: expectedURL)
                let reopened = WorksheetStore(fileURL: url)
                let snapshot = try await loaded(reopened)
                XCTAssertEqual(try Data(contentsOf: url), expected)
                XCTAssertEqual(try snapshot.encoded(), expected)
                XCTAssertEqual(snapshot.draft?.worksheet.openingCash.value, 200)
                // A fresh process must acquire the crashed writer's lock for both
                // load and mutation. The parent bounds its lifetime to catch hangs.
                let saved = try await reopened.save(sheet("400"), expectedRevision: snapshot.revision)
                XCTAssertEqual(saved.draft?.id, snapshot.draft?.id)
                XCTAssertEqual(saved.draft?.baseRevision, snapshot.draft?.baseRevision)
                let afterSave = try await loaded(WorksheetStore(fileURL: url))
                XCTAssertEqual(try afterSave.encoded(), try saved.encoded())
            }
            return
        }

        for phase in ["staged", "beforeReplace", "afterRename"] {
            let url = try location()
            let store = WorksheetStore(fileURL: url)
            let initial = try await store.save(sheet(), expectedRevision: nil)
            let draft = try await store.beginDraft(baseRevision: initial.revision)
            let old = try await store.editDraft(id: XCTUnwrap(draft.draft).id, worksheet: sheet("200"))
            let oldBytes = try old.encoded()
            let crashed = try runStorageChild(mode: "crash", phase: phase, url: url)
            XCTAssertEqual(crashed.terminationReason, .uncaughtSignal, phase)
            XCTAssertEqual(crashed.terminationStatus, SIGKILL, phase)
            let expectedURL = url.appendingPathExtension("expected")
            let candidateBytes = try Data(contentsOf: expectedURL)
            let candidate = try WorksheetSnapshot.decode(candidateBytes)
            XCTAssertEqual(candidate.worksheet.openingCash.value, 300)
            XCTAssertNotEqual(candidate.revision, old.revision)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(candidate.draft), try encoder.encode(old.draft))
            let expected = phase == "afterRename" ? candidateBytes : oldBytes
            XCTAssertEqual(try Data(contentsOf: url), expected, phase)
            let orphans = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
                .filter { $0.hasSuffix(".tmp") }
            XCTAssertEqual(orphans.count, phase == "afterRename" ? 0 : 1, phase)
            try expected.write(to: expectedURL)
            let verifier = try runStorageChild(mode: "verify", phase: phase, url: url)
            XCTAssertEqual(verifier.terminationReason, .exit, phase)
            XCTAssertEqual(verifier.terminationStatus, 0, phase)
        }
    }

    private func runStorageChild(mode: String, phase: String, url: URL) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["PaydayBridgeKitTests.StorageTests/testAbruptSubprocessCrashSnapshotsAndReleasedLock"]
        var environment = ProcessInfo.processInfo.environment
        environment["WORKSHEET_CRASH_MODE"] = mode
        environment["WORKSHEET_CRASH_PHASE"] = phase
        environment["WORKSHEET_CRASH_PATH"] = url.path
        child.environment = environment
        try child.run()
        let deadline = Date().addingTimeInterval(15)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning {
            _ = kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            XCTFail("Subprocess timed out: \(mode) at \(phase); possible unreleased lock")
        }
        child.waitUntilExit()
        return child
    }
    #endif

    func testFailedStagingAndReplacementKeepSavedBytesAndDraft() async throws {
        for stage in [WorksheetStore.WriteStage.staged, .beforeReplace] {
            let url = try location(); let store = WorksheetStore(fileURL: url)
            let initial = try await store.save(sheet(), expectedRevision: nil)
            let drafted = try await store.beginDraft(baseRevision: initial.revision)
            let bytes = try Data(contentsOf: url)
            let broken = WorksheetStore(fileURL: url) { point in
                if point == stage { throw StorageFailure.writeFailed }
            }
            await failure(.writeFailed) { _ = try await broken.save(self.sheet("200"), expectedRevision: initial.revision) }
            await failure(.writeFailed) { _ = try await broken.applyDraft(id: XCTUnwrap(drafted.draft).id) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            let restarted = try await loaded(store)
            XCTAssertEqual(restarted.revision, initial.revision)
            XCTAssertEqual(restarted.draft?.id, drafted.draft?.id)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).filter { $0.hasSuffix(".tmp") }, [])
        }
        // Exercise an actual OS rename failure, independently of the fault seam.
        let url = try location()
        let broken = WorksheetStore(fileURL: url) { point in
            if point == .beforeReplace { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        }
        await failure(.writeFailed) { _ = try await broken.save(self.sheet(), expectedRevision: nil) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
    }

    func testPostRenameSyncFailureReportsUncertainDurabilityWithCommittedSnapshot() async throws {
        let url = try location(); let store = WorksheetStore(fileURL: url)
        let initial = try await store.save(sheet(), expectedRevision: nil)
        let bytes = try Data(contentsOf: url)
        let broken = WorksheetStore(fileURL: url) { point in
            if point == .beforeDirectorySync { throw StorageFailure.writeFailed }
        }
        await failure(.durabilityUncertain) {
            _ = try await broken.save(self.sheet("200"), expectedRevision: initial.revision)
        }
        let committed = try await loaded(WorksheetStore(fileURL: url))
        XCTAssertNotEqual(try Data(contentsOf: url), bytes)
        XCTAssertNotEqual(committed.revision, initial.revision)
        XCTAssertEqual(committed.worksheet.openingCash.value, 200)
        XCTAssertEqual(StorageFailure.durabilityUncertain.recoveryAction,
                       "The new snapshot was committed, but its durability could not be confirmed. Reload it and check storage access before making further changes.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).filter { $0.hasSuffix(".tmp") }, [])
        // The caller can reload and continue using the committed revision.
        let saved = try await store.save(sheet("300"), expectedRevision: committed.revision)
        XCTAssertEqual(saved.worksheet.openingCash.value, 300)
    }

    func testDraftIsolationDiscardAndStaleApplyRequiresExplicitReview() async throws {
        let url = try location(); let store = WorksheetStore(fileURL: url)
        let initial = try await store.save(sheet(), expectedRevision: nil)
        let draft = try await store.beginDraft(baseRevision: initial.revision)
        let edited = try await store.editDraft(id: XCTUnwrap(draft.draft).id, worksheet: sheet("200"))
        XCTAssertEqual(edited.worksheet.openingCash.value, 100)
        let restarted = WorksheetStore(fileURL: url)
        let competing = try await restarted.save(sheet("300"), expectedRevision: initial.revision)
        await failure(.reviewRequired) { _ = try await store.applyDraft(id: XCTUnwrap(edited.draft).id) }
        let unchanged = try await loaded(store)
        XCTAssertEqual(unchanged.worksheet.openingCash.value, 300)
        XCTAssertEqual(unchanged.draft?.worksheet.openingCash.value, 200)
        await failure(.revisionConflict) { _ = try await store.editDraft(id: XCTUnwrap(edited.draft).id, worksheet: self.sheet("400"), reviewedRevision: initial.revision) }
        let reviewed = try await store.editDraft(id: XCTUnwrap(edited.draft).id, worksheet: sheet("400"), reviewedRevision: competing.revision)
        let applied = try await store.applyDraft(id: XCTUnwrap(reviewed.draft).id)
        XCTAssertEqual(applied.worksheet.openingCash.value, 400); XCTAssertNil(applied.draft)
        XCTAssertNotEqual(applied.revision, competing.revision)
        let again = try await store.beginDraft(baseRevision: applied.revision)
        let discarded = try await store.discardDraft(id: XCTUnwrap(again.draft).id)
        XCTAssertEqual(discarded.revision, applied.revision); XCTAssertNil(discarded.draft)
        XCTAssertEqual(discarded.worksheet.openingCash.value, 400)
    }

    func testCompetingStoresRejectStaleSavedAndDraftEdits() async throws {
        let url = try location(); let first = WorksheetStore(fileURL: url); let second = WorksheetStore(fileURL: url)
        let initial = try await first.save(sheet(), expectedRevision: nil)
        let candidateA = try sheet("200"); let candidateB = try sheet("300")
        let a = Task { try await first.save(candidateA, expectedRevision: initial.revision) }
        let b = Task { try await second.save(candidateB, expectedRevision: initial.revision) }
        var successes = 0; var conflicts = 0
        for result in await [a.result, b.result] {
            switch result { case .success: successes += 1; case .failure(let error): if error as? StorageFailure == .revisionConflict { conflicts += 1 } }
        }
        XCTAssertEqual(successes, 1); XCTAssertEqual(conflicts, 1)
        let current = try await loaded(first)
        let draft = try await first.beginDraft(baseRevision: current.revision)
        let oldID = try XCTUnwrap(draft.draft).id
        _ = try await second.editDraft(id: oldID, worksheet: sheet("400"))
        await failure(.draftConflict) { _ = try await first.discardDraft(id: oldID) }
        await failure(.draftConflict) { _ = try await first.applyDraft(id: oldID) }
    }

    func testBoundsAndDomainValidationBeforeReplacing() async throws {
        XCTAssertThrowsError(try WorksheetSnapshot.decode(Data(repeating: 32, count: WorksheetSnapshot.maximumBytes + 1))) { XCTAssertEqual($0 as? StorageFailure, .tooLarge) }
        let url = try location(); try fixture("valid").write(to: url)
        let store = WorksheetStore(fileURL: url); let current = try await loaded(store)
        let bytes = try Data(contentsOf: url)
        let invalid = Worksheet(currency: "USD", openingCash: try Money("1", currency: "EUR"), openingDate: current.worksheet.openingDate)
        await failure(.invalidData) { _ = try await store.save(invalid, expectedRevision: current.revision) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var worksheet = try XCTUnwrap(json["worksheet"] as? [String: Any])
        let bills = try XCTUnwrap(worksheet["bills"] as? [[String: Any]])
        worksheet["bills"] = bills + bills; json["worksheet"] = worksheet
        XCTAssertThrowsError(try WorksheetSnapshot.decode(JSONSerialization.data(withJSONObject: json))) { XCTAssertEqual($0 as? StorageFailure, .invalidData) }
    }
}
