import Foundation
#if canImport(Darwin)
import Darwin
private let posixRead = Darwin.read
#else
import Glibc
private let posixRead = Glibc.read
#endif

public enum StorageFailure: Error, Sendable, Equatable {
    case unreadable, invalidData, unsupportedSchema(Int), tooLarge, writeFailed
    case durabilityUncertain
    case revisionConflict, draftConflict, reviewRequired

    public var recoveryAction: String {
        switch self {
        case .unreadable: "Unlock the device and retry loading. Check storage access; keep the existing file."
        case .invalidData: "Keep the damaged file for recovery and restore a validated backup explicitly."
        case .unsupportedSchema: "Open this file with a newer app version; keep it unchanged."
        case .tooLarge: "Keep the file and use a backup within the 8 MiB storage limit."
        case .writeFailed: "Free device storage or unlock the device, then retry. The previous snapshot remains saved."
        case .durabilityUncertain: "The new snapshot was committed, but its durability could not be confirmed. Reload it and check storage access before making further changes."
        case .revisionConflict: "Reload the current worksheet and review your changes before saving."
        case .draftConflict: "Reload the current draft before editing or discarding it."
        case .reviewRequired: "Compare the current worksheet with the draft, then explicitly review against the current revision."
        }
    }
}

public struct WhatIfDraft: Codable, Sendable {
    public let id: UUID
    public let baseRevision: UUID
    public let worksheet: Worksheet
}

public struct WorksheetSnapshot: Codable, Sendable {
    public static let schemaVersion = 1
    public static let maximumBytes = 8 * 1024 * 1024
    public let schemaVersion: Int
    /// Changes only when the saved worksheet changes.
    public let revision: UUID
    public let worksheet: Worksheet
    public let draft: WhatIfDraft?

    init(revision: UUID = UUID(), worksheet: Worksheet, draft: WhatIfDraft? = nil) {
        schemaVersion = Self.schemaVersion
        self.revision = revision; self.worksheet = worksheet; self.draft = draft
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, worksheet, draft }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else { throw StorageFailure.unsupportedSchema(version) }
        schemaVersion = version
        revision = try container.decode(UUID.self, forKey: .revision)
        worksheet = try container.decode(Worksheet.self, forKey: .worksheet)
        draft = try container.decodeIfPresent(WhatIfDraft.self, forKey: .draft)
        try worksheet.validate(); try draft?.worksheet.validate()
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw StorageFailure.tooLarge }
        struct Header: Decodable { let schemaVersion: Int }
        do {
            let decoder = JSONDecoder()
            let version = try decoder.decode(Header.self, from: data).schemaVersion
            guard version == schemaVersion else { throw StorageFailure.unsupportedSchema(version) }
            let snapshot = try decoder.decode(Self.self, from: data)
            try snapshot.worksheet.validate()
            try snapshot.draft?.worksheet.validate()
            return snapshot
        } catch let error as StorageFailure { throw error }
        catch { throw StorageFailure.invalidData }
    }

    func encoded() throws -> Data {
        do {
            try worksheet.validate(); try draft?.worksheet.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(self)
            guard data.count <= Self.maximumBytes else { throw StorageFailure.tooLarge }
            return data
        } catch let error as StorageFailure { throw error }
        catch { throw StorageFailure.invalidData }
    }
}

public enum StorageLoad: Sendable {
    case missing
    case loaded(WorksheetSnapshot)
    case recovery(StorageFailure)
}

/// Offline Application Support seam. All instances coordinate with a sibling advisory
/// lock; a validated, protected, synchronized sibling replaces the file in one rename.
/// Drafts survive restart but never change the saved worksheet until explicit apply.
public actor WorksheetStore {
    public let fileURL: URL
    // Internal fault seam exercises the actual staged-write transaction in XCTest.
    enum WriteStage { case staged, beforeReplace, beforeDirectorySync }
    private let checkpoint: (@Sendable (WriteStage) throws -> Void)?

    public init(fileURL: URL) { self.fileURL = fileURL; checkpoint = nil }
    init(fileURL: URL, checkpoint: @escaping @Sendable (WriteStage) throws -> Void) {
        self.fileURL = fileURL; self.checkpoint = checkpoint
    }

    public static func applicationSupport() throws -> WorksheetStore {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return WorksheetStore(fileURL: root.appendingPathComponent("PaydayBridge", isDirectory: true).appendingPathComponent("worksheet.json"))
    }

    public func load() -> StorageLoad {
        do { return try transaction { try read().map(StorageLoad.loaded) ?? .missing } }
        catch { return .recovery(error as? StorageFailure ?? .unreadable) }
    }

    @discardableResult
    public func save(_ worksheet: Worksheet, expectedRevision: UUID?) throws -> WorksheetSnapshot {
        try transaction {
            let current = try read()
            guard current?.revision == expectedRevision else { throw StorageFailure.revisionConflict }
            let next = WorksheetSnapshot(worksheet: worksheet, draft: current?.draft)
            try write(next); return next
        }
    }

    @discardableResult
    public func beginDraft(baseRevision: UUID) throws -> WorksheetSnapshot {
        try transaction {
            let current = try existing()
            guard current.revision == baseRevision else { throw StorageFailure.revisionConflict }
            guard current.draft == nil else { throw StorageFailure.draftConflict }
            let draft = WhatIfDraft(id: UUID(), baseRevision: baseRevision, worksheet: current.worksheet)
            let next = WorksheetSnapshot(revision: current.revision, worksheet: current.worksheet, draft: draft)
            try write(next); return next
        }
    }

    /// Review supplies an explicitly reconciled candidate and the revision just reviewed.
    /// Rotating the draft ID also rejects edits from an older draft view.
    @discardableResult
    public func editDraft(id: UUID, worksheet: Worksheet, reviewedRevision: UUID? = nil) throws -> WorksheetSnapshot {
        try transaction {
            let current = try existing()
            guard let draft = current.draft, draft.id == id else { throw StorageFailure.draftConflict }
            if let reviewedRevision, reviewedRevision != current.revision { throw StorageFailure.revisionConflict }
            let updated = WhatIfDraft(id: UUID(), baseRevision: reviewedRevision ?? draft.baseRevision, worksheet: worksheet)
            let next = WorksheetSnapshot(revision: current.revision, worksheet: current.worksheet, draft: updated)
            try write(next); return next
        }
    }

    @discardableResult
    public func applyDraft(id: UUID) throws -> WorksheetSnapshot {
        try transaction {
            let current = try existing()
            guard let draft = current.draft, draft.id == id else { throw StorageFailure.draftConflict }
            guard draft.baseRevision == current.revision else { throw StorageFailure.reviewRequired }
            let next = WorksheetSnapshot(worksheet: draft.worksheet)
            try write(next); return next
        }
    }

    @discardableResult
    public func discardDraft(id: UUID) throws -> WorksheetSnapshot {
        try transaction {
            let current = try existing()
            guard current.draft?.id == id else { throw StorageFailure.draftConflict }
            let next = WorksheetSnapshot(revision: current.revision, worksheet: current.worksheet)
            try write(next); return next
        }
    }

    private func existing() throws -> WorksheetSnapshot {
        guard let snapshot = try read() else { throw StorageFailure.revisionConflict }
        return snapshot
    }

    private func read() throws -> WorksheetSnapshot? {
        // POSIX errno distinguishes a missing plan from any unreadable existing path
        // on both Darwin and Linux; never treat a permission error as a fresh plan.
        let fd = open(fileURL.path, O_RDONLY | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw StorageFailure.unreadable
        }
        defer { _ = close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0 && (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw StorageFailure.unreadable
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= WorksheetSnapshot.maximumBytes {
            let count = buffer.withUnsafeMutableBytes { posixRead(fd, $0.baseAddress!, min($0.count, WorksheetSnapshot.maximumBytes + 1 - data.count)) }
            if count < 0 {
                if errno == EINTR { continue }
                throw StorageFailure.unreadable
            }
            if count == 0 { return try WorksheetSnapshot.decode(data) }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw StorageFailure.tooLarge
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            #endif
        } catch { throw StorageFailure.unreadable }
        let fd = open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { throw StorageFailure.unreadable }
        defer { _ = close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw StorageFailure.unreadable }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
    }

    private func write(_ snapshot: WorksheetSnapshot) throws {
        let data = try snapshot.encoded()
        let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".worksheet-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            #if os(iOS)
            try data.write(to: temporary, options: [.withoutOverwriting, .completeFileProtection])
            #else
            try data.write(to: temporary, options: .withoutOverwriting)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
            #endif
            try checkpoint?(.staged)
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.synchronize()
            try checkpoint?(.beforeReplace)
            guard rename(temporary.path, fileURL.path) == 0 else { throw StorageFailure.writeFailed }
        } catch { throw StorageFailure.writeFailed }
        // Rename commits the snapshot. A later failure cannot claim the old snapshot
        // remains saved, but must report that crash durability is unconfirmed.
        do {
            try checkpoint?(.beforeDirectorySync)
            let directory = open(fileURL.deletingLastPathComponent().path, O_RDONLY)
            guard directory >= 0 else { throw StorageFailure.durabilityUncertain }
            defer { _ = close(directory) }
            guard fsync(directory) == 0 else { throw StorageFailure.durabilityUncertain }
        } catch { throw StorageFailure.durabilityUncertain }
    }
}
