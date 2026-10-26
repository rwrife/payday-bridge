import XCTest

/// Journeys for issues #4 and #5. XCUITest cannot read Application Support on
/// the simulator, so persistence is proven by relaunch (same installed app
/// data), not by inspecting files from the test process.
///
/// Manual VoiceOver gaps disclosed honestly: these tests assert the
/// accessibility tree (merged row labels, human warning phrases, 44pt targets,
/// Dynamic Type reflow, orientation continuity) but cannot verify spoken
/// output, rotor behavior, or real VoiceOver gesture order. A physical-device
/// VoiceOver pass remains a manual acceptance gap.
@MainActor
final class PaydayBridgeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // App starts with Accessibility Extra Extra Extra Large font scale;
        // asserts Dynamic Type reflow throughout the entire journey.
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch() // CI simulator starts with a fresh app container.
    }

    private func hittable(_ id: String) -> XCUIElement {
        let element = app.buttons[id]
        for _ in 0..<10 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, "\(id) unreachable in scroll view")
        XCTAssertGreaterThanOrEqual(element.frame.height, 44)
        return element
    }

    private func createWorksheetWithConfirmedIncomeAndUnknownRent() {
        hittable("plan.create").tap()
        hittable("plan.addIncome").tap()
        app.buttons["editor.status"].tap()
        app.buttons["Confirmed estimate"].tap()
        let incomeAmount = app.textFields["editor.amount"]
        incomeAmount.waitAndTap()
        incomeAmount.typeText("500.00")
        app.buttons["editor.save"].tap()

        // Monthly bill with an unknown amount.
        hittable("plan.addBill").tap()
        app.switches["editor.unknown"].switches.firstMatch.tap()
        app.switches["editor.monthly"].switches.firstMatch.tap()
        let billTitle = app.textFields["editor.title"]
        billTitle.waitAndTap()
        billTitle.typeText("Rent")
        app.buttons["editor.save"].tap()
        dismissKeyboard()
    }

    private func firstBillRow() -> XCUIElement {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.bill.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        return row
    }

    func testWorksheetDraftAndPaidFlow() throws {
        // 1-3. Worksheet, confirmed income, unknown-amount monthly bill.
        createWorksheetWithConfirmedIncomeAndUnknownRent()

        // 4. Timeline row label states uncertainty in words, never color-only.
        let row = firstBillRow()
        XCTAssertTrue(row.label.contains("Rent"))
        XCTAssertTrue(row.label.contains("Amount unknown"))
        XCTAssertTrue(row.label.contains("No funding assigned"))
        XCTAssertTrue(row.label.contains("unpaid"))
        // AX5 reflow keeps rows operable with >=44pt touch targets.
        XCTAssertGreaterThanOrEqual(row.frame.height, 44)

        // 5. Selecting the row moves funding/draft controls (workspace seam).
        row.tap()
        let selected = app.staticTexts["plan.selectedBill"]
        for _ in 0..<10 where !selected.isHittable { app.swipeUp() }
        XCTAssertTrue(selected.isHittable, "selected bill controls unreachable at AX5")
        XCTAssertTrue(selected.label.contains("Amount unknown"))

        // 6. Assign the bill to the confirmed income.
        let funding = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.funding.")).firstMatch
        for _ in 0..<10 where !funding.isHittable { app.swipeUp() }
        XCTAssertTrue(funding.isHittable)
        funding.tap()
        let confirmed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Confirmed estimate")).firstMatch
        XCTAssertTrue(confirmed.waitForExistence(timeout: 10))
        confirmed.tap()

        // 7. Mark paid, then undo — proven through the selection summary label.
        let paidButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.paid.")).firstMatch
        for _ in 0..<10 where !paidButton.isHittable { app.swipeUp() }
        XCTAssertTrue(paidButton.isHittable, "paid control unreachable after funding choice")
        paidButton.tap()
        let paid = NSPredicate(format: "label CONTAINS %@", ", paid.")
        expectation(for: paid, evaluatedWith: selected)
        waitForExpectations(timeout: 10)
        paidButton.tap()
        let unpaid = NSPredicate(format: "label CONTAINS %@", ", unpaid.")
        expectation(for: unpaid, evaluatedWith: selected)
        waitForExpectations(timeout: 10)

        // 8. Draft comparison: a what-if draft cannot mutate the saved plan.
        let beginDraft = app.buttons["plan.beginDraft"]
        for _ in 0..<8 where !beginDraft.exists { app.swipeUp() }
        XCTAssertTrue(beginDraft.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(beginDraft.frame.height, 44)
        beginDraft.tap()
        let draftMode = app.staticTexts["plan.mode"]
        for _ in 0..<10 where !draftMode.isHittable { app.swipeDown() }
        XCTAssertTrue(draftMode.isHittable)
        XCTAssertEqual(draftMode.label, "What-if draft — saved plan unchanged")
        let toggleDraft = app.buttons["plan.toggleDraft"]
        for _ in 0..<8 where !toggleDraft.exists { app.swipeUp() }
        XCTAssertTrue(toggleDraft.waitForExistence(timeout: 10))
        toggleDraft.tap()
        let savedMode = app.staticTexts["plan.mode"]
        for _ in 0..<8 where !savedMode.exists { app.swipeDown() }
        XCTAssertTrue(savedMode.waitForExistence(timeout: 10))
        XCTAssertEqual(savedMode.label, "Saved plan — draft available")

        // 9. Orientation reflows, selected bill and draft mode survive.
        for _ in 0..<10 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        row.tap()
        for _ in 0..<10 where !selected.isHittable { app.swipeUp() }
        XCTAssertTrue(selected.isHittable)
        let selectedLabel = selected.label
        XCUIDevice.shared.orientation = .landscapeLeft
        for _ in 0..<10 where !selected.isHittable { app.swipeUp() }
        XCTAssertTrue(selected.isHittable)
        XCTAssertEqual(selected.label, selectedLabel)
        for _ in 0..<10 where !savedMode.isHittable { app.swipeDown() }
        XCTAssertTrue(savedMode.isHittable)
        XCTAssertEqual(savedMode.label, "Saved plan — draft available")
        XCUIDevice.shared.orientation = .portrait

        // 10. Destructive delete asks for confirmation first.
        let deleteRent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Delete Rent")).firstMatch
        for _ in 0..<8 where !deleteRent.exists { app.swipeUp() }
        XCTAssertTrue(deleteRent.waitForExistence(timeout: 10))
        deleteRent.tap()
        let confirmDelete = app.buttons.matching(NSPredicate(format: "label == %@", "Delete bill")).firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 10))
        confirmDelete.tap()
        let editRent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Edit Rent")).firstMatch
        let deleted = NSPredicate(format: "exists == false")
        expectation(for: deleted, evaluatedWith: editRent)
        waitForExpectations(timeout: 10)

        // 11. Restart: data reloads from the device container.
        app.terminate()
        app.launch()
        XCTAssertTrue(hittable("plan.addBill").exists)
        let draftSummary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Draft:")).firstMatch
        for _ in 0..<10 where !draftSummary.isHittable { app.swipeUp() }
        XCTAssertTrue(draftSummary.isHittable)

        // 12. Backup/CSV export previews sensitive data before any share action.
        let exportBackup = app.buttons["plan.exportBackup"]
        for _ in 0..<10 where !exportBackup.isHittable { app.swipeUp() }
        XCTAssertTrue(exportBackup.isHittable)
        XCTAssertGreaterThanOrEqual(exportBackup.frame.height, 44)
        exportBackup.tap()
        let exportAlert = app.alerts["Sensitive planning data preview"]
        XCTAssertTrue(exportAlert.waitForExistence(timeout: 10))
        XCTAssertTrue(exportAlert.staticTexts.firstMatch.label.contains("bills"))
        exportAlert.buttons["Cancel"].tap()

        let exportCSV = app.buttons["plan.exportCSV"]
        for _ in 0..<10 where !exportCSV.isHittable { app.swipeUp() }
        XCTAssertTrue(exportCSV.isHittable)
        XCTAssertGreaterThanOrEqual(exportCSV.frame.height, 44)
        exportCSV.tap()
        let csvAlert = app.alerts["Sensitive planning data preview"]
        XCTAssertTrue(csvAlert.waitForExistence(timeout: 10))
        XCTAssertTrue(csvAlert.staticTexts.firstMatch.label.contains("90-day CSV"))
        csvAlert.buttons["Cancel"].tap()

        let restoreBackup = app.buttons["plan.restoreBackup"]
        for _ in 0..<10 where !restoreBackup.isHittable { app.swipeUp() }
        XCTAssertTrue(restoreBackup.isHittable)
        XCTAssertGreaterThanOrEqual(restoreBackup.frame.height, 44)
    }

    private func dismissKeyboard() {
        if app.keyboards.firstMatch.exists {
            app.navigationBars.firstMatch.tap()
        }
    }
}

private extension XCUIElement {
    func waitAndTap(timeout: TimeInterval = 10) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "missing \(identifier)")
        tap()
    }
}
