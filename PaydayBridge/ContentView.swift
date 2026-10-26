import SwiftUI
import Foundation
import PaydayBridgeKit

struct ContentView: View {
    @State private var store: WorksheetStore?
    @State private var snapshot: WorksheetSnapshot?
    @State private var selection = PaydayWorkspaceSelection()
    @State private var editor: Editor?
    @State private var error: String?
    @State private var deleteID: UUID?
    @State private var export: ExportPreview?
    @State private var sharing: BackupFile?
    @State private var preview: WorksheetBackupPreview?
    @State private var previewData: Data?
    @State private var importing = false
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Generated artifact staged in app container for the explicit share action.
    struct BackupFile: Identifiable { let id = UUID(); let url: URL; let label: String }
    /// Sensitive-data preview shown before any share action (issue #6).
    struct ExportPreview: Identifiable { let id = UUID(); let file: BackupFile; let summary: String }

    private var spacing: CGFloat { typeSize.isAccessibilitySize ? 12 : 8 }
    private var warningDescriptions: [String: String] {
        ["unknownAmount": "Amount unknown; coverage cannot be confirmed",
         "unassigned": "No funding assigned",
         "expectedNotConfirmed": "Expected income does not count as confirmed coverage",
         "fundingAfterDue": "Funding arrives after due date",
         "overcommitted": "Assigned bills exceed confirmed funds",
         "snapshotAlreadyIncluded": "Income already included in opening cash; cannot count twice"]
    }

    private func warningText(_ warnings: [String]) -> String {
        warnings.isEmpty ? "No coverage warnings" : warnings.map { warningDescriptions[$0] ?? $0 }.joined(separator: ". ")
    }

    private func rowLabel(_ row: BillRow) -> String {
        "\(row.bill.title), due \(dateText(row.occurrence.due)), "
        + (row.occurrence.amount.map(moneyText) ?? "amount unknown")
        + ", \(row.occurrence.paid ? "paid" : "unpaid"). \(warningText(row.warnings))"
    }

    private var plan: Worksheet? {
        guard let snapshot else { return nil }
        return selection.draftMode ? snapshot.draft?.worksheet : snapshot.worksheet
    }

    var body: some View {
        NavigationStack { deletionDialog(restoreAlert(exportAlert(workspace))) }
    }

    private var workspace: some View {
        List {
            if let plan {
                PaydayWorkspaceLayout(timeline: { timeline(plan) }, controls: { controls(plan) })
            } else {
                Section {
                    Text("Manual estimates only. No bank access, network calls or financial advice.")
                    Button("Create worksheet") { create() }.accessibilityIdentifier("plan.create")
                }
            }
        }
        .navigationTitle("Payday Bridge")
        .task { if store == nil { await load() } }
        .sheet(item: $editor) { choice in
            PlanEditor(choice: choice, plan: plan) { candidate in change { _ in candidate } }
        }
        .sheet(item: $sharing) { file in
            ShareSheet(items: [file.url]).accessibilityIdentifier("share.sheet")
        }
    }

    private func exportAlert<Content: View>(_ content: Content) -> some View {
        content.alert("Sensitive planning data preview", isPresented: Binding(
            get: { export != nil }, set: { if !$0 { export = nil } }
        )) {
            Button("Share…") {
                if let file = export?.file { sharing = file }
                export = nil
            }.accessibilityIdentifier("plan.confirmShare")
            Button("Cancel", role: .cancel) { export = nil }
        } message: {
            if let export {
                Text("\(export.summary)\n\nThis contains your financial estimates. No cloud account or tracking is used; you control where you send it.")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): stageImport(url)
            case .failure: error = "Import was cancelled. Current data is unchanged."
            }
        }
    }

    private func restoreAlert<Content: View>(_ content: Content) -> some View {
        content.alert("Preview restore", isPresented: Binding(
            get: { preview != nil }, set: { if !$0 { preview = nil; previewData = nil } }
        )) {
            Button("Replace current plan", role: .destructive) { confirmRestore() }
            Button("Cancel", role: .cancel) { preview = nil; previewData = nil }
        } message: {
            if let preview {
                Text("Sensitive planning data. Restore \(preview.billCount) bills, \(preview.incomeCount) incomes"
                     + "\(preview.hasDraft ? " and a what-if draft" : "") from \(preview.currency) backup dated \(preview.openingDate.description). Current plan will be kept in a recovery file.")
            }
        }
        .alert("Worksheet unavailable", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "Unknown error") }
    }

    private func deletionDialog<Content: View>(_ content: Content) -> some View {
        content.confirmationDialog("Delete bill and funding assignments?", isPresented: Binding(
            get: { deleteID != nil }, set: { if !$0 { deleteID = nil } }
        ), titleVisibility: .visible) {
            Button("Delete bill", role: .destructive) {
                guard let id = deleteID else { return }
                let prefix = "\(id.uuidString)/"
                change { current in copy(current, bills: current.bills.filter { $0.id != id },
                                         overrides: current.overrides.filter { !$0.key.hasPrefix(prefix) },
                                         assignments: current.assignments.filter { !$0.key.hasPrefix(prefix) }) }
                deleteID = nil
            }
        }
    }

    @ViewBuilder
    private func timeline(_ plan: Worksheet) -> some View {
        Section {
            Text(PaydayBridgeKit.planningDisclaimer).font(.footnote)
            if snapshot?.draft != nil {
                Text(selection.draftMode ? "What-if draft — saved plan unchanged" : "Saved plan — draft available")
                    .accessibilityIdentifier("plan.mode")
            }
        }
        Section("Opening cash") {
            LabeledContent("As of \(dateText(plan.openingDate))", value: moneyText(plan.openingCash))
            Button("Edit opening cash") { editor = .cash }.accessibilityIdentifier("plan.editCash")
        }
        Section("Income — expected is not confirmed") {
            ForEach(plan.incomes, id: \.id) { income in
                Text("\(dateText(income.date)) · \(moneyText(income.amount)) · \(income.status == .confirmed ? "Confirmed estimate" : "Expected only")")
            }
            Button("Add income") { editor = .income }.accessibilityIdentifier("plan.addIncome")
        }
        Section("Bills · next 30 days") {
            ForEach(rows(plan), id: \.occurrence.key) { row in
                Button {
                    selection.selectedOccurrenceKey = row.occurrence.key
                } label: {
                    VStack(alignment: .leading, spacing: spacing) {
                        Text("\(row.bill.title) · \(dateText(row.occurrence.due))").font(.headline)
                        Text(row.occurrence.amount.map(moneyText) ?? "Unknown amount")
                        Text(warningText(row.warnings)).font(.body)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(rowLabel(row))
                .accessibilityHint("Show funding and paid controls")
                .accessibilityIdentifier("plan.bill.\(row.occurrence.key)")
                .paydayTouchTarget()
            }
            Button("Add bill") { editor = .bill(nil) }
                .accessibilityIdentifier("plan.addBill")
                .paydayTouchTarget()
        }
    }

    @ViewBuilder
    private func controls(_ plan: Worksheet) -> some View {
        if let row = rows(plan).first(where: { $0.occurrence.key == selection.selectedOccurrenceKey }) {
            Section("Funding · \(row.bill.title)") {
                Text(rowLabel(row)).accessibilityIdentifier("plan.selectedBill")
                Picker("Funding for \(row.bill.title)", selection: Binding(
                    get: { envelopeID(plan.assignments[row.occurrence.key]) },
                    set: { choice in change { current in
                        var assignments = current.assignments
                        assignments[row.occurrence.key] = envelope(choice)
                        return copy(current, assignments: assignments)
                    } }
                )) {
                    Text("Unassigned").tag("none")
                    Text("Opening cash").tag("cash")
                    ForEach(plan.incomes, id: \.id) { income in
                        Text("\(dateText(income.date)) · \(income.status == .confirmed ? "Confirmed estimate" : "Expected only") · \(moneyText(income.amount))")
                            .tag(income.id.uuidString)
                    }
                }
                .accessibilityIdentifier("plan.funding.\(row.occurrence.key)")
                .paydayTouchTarget()
                Button(row.occurrence.paid ? "Undo paid" : "Mark paid") {
                    change { current in
                        var overrides = current.overrides
                        var value = overrides[row.occurrence.key] ?? OccurrenceOverride()
                        value.paid = !row.occurrence.paid
                        overrides[row.occurrence.key] = value
                        return copy(current, overrides: overrides)
                    }
                }
                .accessibilityIdentifier("plan.paid.\(row.occurrence.key)")
                .paydayTouchTarget()
                Button("Edit \(row.bill.title)") { editor = .bill(row.bill.id) }
                    .paydayTouchTarget()
                Button("Delete \(row.bill.title)", role: .destructive) { deleteID = row.bill.id }
                    .paydayTouchTarget()
            }
        }
        Section("What-if comparison") {
            if let draft = snapshot?.draft {
                Text("Saved: \(snapshot!.worksheet.bills.count) bills, \(snapshot!.worksheet.incomes.count) incomes")
                Text("Draft: \(draft.worksheet.bills.count) bills, \(draft.worksheet.incomes.count) incomes")
                Button(selection.draftMode ? "View saved plan" : "Edit what-if draft") { selection.draftMode.toggle() }
                    .accessibilityIdentifier("plan.toggleDraft")
                Button("Apply draft") { action { store, _ in try await store.applyDraft(id: draft.id) }; selection.draftMode = false }
                    .accessibilityIdentifier("plan.applyDraft")
                Button("Discard draft", role: .destructive) { action { store, _ in try await store.discardDraft(id: draft.id) }; selection.draftMode = false }
                    .accessibilityIdentifier("plan.discardDraft")
            } else {
                Button("Start what-if draft") {
                    action { store, current in try await store.beginDraft(baseRevision: current!.revision) }
                    selection.draftMode = true
                }.accessibilityIdentifier("plan.beginDraft")
            }
        }
        Section("Backup & export") {
            Button("Export JSON backup") { exportBackup() }
                .accessibilityIdentifier("plan.exportBackup")
                .paydayTouchTarget()
            Button("Export worksheet CSV") { exportCSV() }
                .accessibilityIdentifier("plan.exportCSV")
                .paydayTouchTarget()
            Button("Restore backup…") { importing = true }
                .accessibilityIdentifier("plan.restoreBackup")
                .paydayTouchTarget()
        }
    }

    private func load() async {
        do {
            let store = try WorksheetStore.applicationSupport()
            self.store = store
            switch await store.load() {
            case .missing: break
            case .loaded(let loaded): snapshot = loaded
            case .recovery(let failure): error = failure.recoveryAction
            }
        } catch { self.error = "Storage unavailable. Keep existing data and retry after unlocking device." }
    }

    private func action(_ operation: @escaping @Sendable (WorksheetStore, WorksheetSnapshot?) async throws -> WorksheetSnapshot) {
        guard let store else { return }
        Task {
            do { snapshot = try await operation(store, snapshot) }
            catch let failure as StorageFailure { self.error = failure.recoveryAction }
            catch { self.error = "Save failed. Existing data remains on device." }
        }
    }

    private func create() {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        guard let day = try? CivilDate(year: c.year!, month: c.month!, day: c.day!),
              let zero = try? Money("0", currency: "USD") else { return }
        let plan = Worksheet(currency: "USD", openingCash: zero, openingDate: day)
        action { store, _ in try await store.save(plan, expectedRevision: nil) }
    }

    private func change(_ transform: @escaping @Sendable (Worksheet) -> Worksheet) {
        let editing = selection.draftMode
        action { store, current in
            guard let current else { throw StorageFailure.unreadable }
            if editing, let draft = current.draft {
                return try await store.editDraft(id: draft.id, worksheet: transform(draft.worksheet))
            }
            return try await store.save(transform(current.worksheet), expectedRevision: current.revision)
        }
    }

    private func rows(_ plan: Worksheet) -> [BillRow] {
        let coverage = try? plan.coverage(from: plan.openingDate, days: 30)
        return plan.bills.flatMap { bill in
            let related = plan.overrides.filter { $0.key.hasPrefix("\(bill.id.uuidString)/") }
            return ((try? bill.occurrences(from: plan.openingDate, days: 30, overrides: related)) ?? []).map { occurrence in
                BillRow(bill: bill, occurrence: occurrence,
                        warnings: coverage?.items.first(where: { $0.key == occurrence.key })?.warnings.map(\.rawValue).sorted() ?? [])
            }
        }.sorted { $0.occurrence.due < $1.occurrence.due }
    }

    private func stageFile(_ name: String, _ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaydayBridgeExport", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        return destination
    }

    private func exportBackup() {
        guard let snapshot else { return }
        do {
            let data = try snapshot.backupData()
            let url = try stageFile("payday-bridge-backup-\(dateText(snapshot.worksheet.openingDate)).json", data)
            let file = BackupFile(url: url, label: "Payday Bridge JSON backup")
            let summary = "JSON backup: \(snapshot.worksheet.bills.count) bills, \(snapshot.worksheet.incomes.count) incomes, opening cash \(moneyText(snapshot.worksheet.openingCash))"
                + (snapshot.draft != nil ? ", plus one what-if draft." : ".")
            export = ExportPreview(file: file, summary: summary)
        } catch { self.error = "Could not create backup. Existing data remains saved." }
    }

    private func exportCSV() {
        guard let plan else { return }
        do {
            let data = try plan.csvData(days: 90)
            let url = try stageFile("payday-bridge-\(dateText(plan.openingDate)).csv", data)
            let file = BackupFile(url: url, label: "Payday Bridge CSV")
            let summary = "90-day CSV export: \(plan.bills.count) bills, \(plan.incomes.count) incomes, opening cash \(moneyText(plan.openingCash))."
            export = ExportPreview(file: file, summary: summary)
        } catch { self.error = "Could not export CSV. Existing data remains saved." }
    }

    private func stageImport(_ url: URL) {
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let parsed = try WorksheetBackupPreview(data: data)
            self.previewData = data
            self.preview = parsed
        } catch let failure as StorageFailure {
            self.error = failure.recoveryAction
        } catch {
            self.error = "Unreadable backup file. Current data remains unchanged."
        }
    }

    private func confirmRestore() {
        guard let store, let preview, let data = previewData, let current = snapshot else { return }
        Task {
            do {
                let restored = try await store.restore(data, preview: preview, expectedRevision: current.revision)
                self.snapshot = restored
                self.selection = PaydayWorkspaceSelection()
                self.preview = nil
                self.previewData = nil
            } catch let failure as StorageFailure {
                self.error = failure.recoveryAction
            } catch {
                self.error = "Restore failed. Previous plan remains in recovery file."
            }
        }
    }
}

#if canImport(UIKit)
import UIKit
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
struct ShareSheet: View {
    let items: [Any]
    var body: some View { Text("Share preview") }
}
#endif

private struct BillRow {
    let bill: Bill
    let occurrence: Occurrence
    let warnings: [String]
}

private enum Editor: Identifiable {
    case cash, income, bill(UUID?)
    var id: String {
        switch self { case .cash: "cash"; case .income: "income"; case .bill(let id): "bill-\(id?.uuidString ?? "new")" }
    }
}

private func dateText(_ d: CivilDate) -> String { String(format: "%04d-%02d-%02d", d.year, d.month, d.day) }
private func moneyText(_ m: Money) -> String { "\(m.currency) \(NSDecimalNumber(decimal: m.value).stringValue)" }
private func envelopeID(_ e: Envelope?) -> String {
    switch e { case nil: "none"; case .openingCash: "cash"; case .income(let id): id.uuidString }
}
private func envelope(_ value: String) -> Envelope? {
    if value == "cash" { return .openingCash }
    return UUID(uuidString: value).map { Envelope.income($0) }
}
private func copy(_ w: Worksheet, cash: Money? = nil, day: CivilDate? = nil,
                  incomes: [Income]? = nil, bills: [Bill]? = nil,
                  overrides: [String: OccurrenceOverride]? = nil,
                  assignments: [String: Envelope]? = nil) -> Worksheet {
    Worksheet(currency: w.currency, openingCash: cash ?? w.openingCash, openingDate: day ?? w.openingDate,
              incomes: incomes ?? w.incomes, bills: bills ?? w.bills,
              overrides: overrides ?? w.overrides, assignments: assignments ?? w.assignments)
}

private struct PlanEditor: View {
    let choice: Editor
    let plan: Worksheet?
    let save: @MainActor @Sendable (Worksheet) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var title = ""
    @State private var date = Date.now
    @State private var status: IncomeStatus = .expected
    @State private var monthly = false
    @State private var unknown = false
    @State private var validation: String?

    private var prior: Bill? {
        guard case .bill(let id) = choice else { return nil }
        return plan?.bills.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Form {
                if case .bill = choice {
                    TextField("Bill name", text: $title).accessibilityIdentifier("editor.title")
                    Toggle("Amount unknown", isOn: $unknown).accessibilityIdentifier("editor.unknown")
                    Toggle("Repeats monthly", isOn: $monthly).accessibilityIdentifier("editor.monthly")
                    if let prior {
                        Text("Preview (next 30 days): \(preview(for: prior))")
                            .font(.footnote)
                            .accessibilityIdentifier("editor.recurrencePreview")
                        Text("Paid overrides stay attached to their original month when a monthly anchor moves.")
                            .font(.footnote)
                    }
                }
                if !unknown {
                    TextField("Amount in \(plan?.currency ?? "USD")", text: $amount)
                        .keyboardType(.decimalPad).accessibilityIdentifier("editor.amount")
                }
                DatePicker("Civil date", selection: $date, displayedComponents: .date).accessibilityIdentifier("editor.date")
                if case .income = choice {
                    Picker("Income status", selection: $status) {
                        Text("Expected — not confirmed").tag(IncomeStatus.expected)
                        Text("Confirmed estimate").tag(IncomeStatus.confirmed)
                    }.accessibilityIdentifier("editor.status")
                }
                if let validation { Text(validation).foregroundStyle(.red).accessibilityIdentifier("editor.validation") }
            }
            .navigationTitle(prior == nil ? "Worksheet editor" : "Edit bill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { submit() }.accessibilityIdentifier("editor.save") }
            }
            .onAppear {
                guard let plan else { return }
                if let prior {
                    title = prior.title; unknown = prior.amount == nil; monthly = prior.recurrence == .monthly
                    amount = prior.amount.map { NSDecimalNumber(decimal: $0.value).stringValue } ?? ""
                    date = dayToDate(prior.firstDue)
                } else if case .cash = choice {
                    amount = NSDecimalNumber(decimal: plan.openingCash.value).stringValue
                    date = dayToDate(plan.openingDate)
                }
            }
        }
    }

    private func dayToDate(_ d: CivilDate) -> Date {
        Calendar.current.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) ?? .now
    }

    private func preview(for prior: Bill) -> String {
        guard let plan else { return "No worksheet" }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let due = try? CivilDate(year: c.year!, month: c.month!, day: c.day!) else { return "Choose a valid date" }
        let candidate = Bill(id: prior.id, title: title, firstDue: due,
                             recurrence: monthly ? .monthly : .once, amount: prior.amount)
        let related = plan.overrides.filter { $0.key.hasPrefix("\(prior.id.uuidString)/") }
        guard let occurrences = try? candidate.occurrences(from: plan.openingDate, days: 30, overrides: related) else {
            return "Cannot change recurrence while old paid overrides exist; keep monthly or review the saved months first."
        }
        if occurrences.isEmpty { return "No bills in next 30 days" }
        return occurrences.map { "\(dateText($0.due))\($0.paid ? " (paid)" : "")" }.joined(separator: ", ")
    }

    private func submit() {
        guard let plan else { return }
        do {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
            let day = try CivilDate(year: c.year!, month: c.month!, day: c.day!)
            let value = unknown ? nil : try Money(amount, currency: plan.currency)
            let candidate: Worksheet
            switch choice {
            case .cash:
                guard let value else { throw PlanningError.invalid }
                candidate = copy(plan, cash: value, day: day)
            case .income:
                guard let value else { throw PlanningError.invalid }
                candidate = copy(plan, incomes: plan.incomes + [Income(id: UUID(), date: day, amount: value, status: status)])
            case .bill:
                guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlanningError.invalid }
                let bill = Bill(id: prior?.id ?? UUID(), title: title, firstDue: day,
                                recurrence: monthly ? .monthly : .once, amount: value)
                candidate = copy(plan, bills: prior == nil ? plan.bills + [bill] : plan.bills.map { $0.id == bill.id ? bill : $0 })
            }
            try candidate.validate()
            save(candidate)
            dismiss()
        } catch {
            validation = "Check title, date and amount; use digits with at most \(Money.precisions[plan.currency] ?? 2) decimal places."
        }
    }
}
