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

    private func createWorksheetWithConfirmedIncomeAndUnknownRent() {
        let create = app.buttons["plan.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        XCTAssertTrue(app.buttons["plan.addIncome"].waitForExistence(timeout: 10))

        // Confirmed income dated today.
        app.buttons["plan.addIncome"].tap()
        app.buttons["editor.status"].tap()
        app.buttons["Confirmed estimate"].tap()
        let incomeAmount = app.textFields["editor.amount"]
        incomeAmount.waitAndTap()
        incomeAmount.typeText("500.00")
        app.buttons["editor.save"].tap()

        // Monthly bill with an unknown amount.
        let addBill = app.buttons["plan.addBill"]
        for _ in 0..<10 where !addBill.isHittable { app.swipeUp() }
        XCTAssertTrue(addBill.isHittable)
        XCTAssertGreaterThanOrEqual(addBill.frame.height, 44)
        addBill.tap()
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
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        XCTAssertTrue(selected.label.contains("Amount unknown"))

        // 6. Assign the bill to the confirmed income.
        let funding = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.funding.")).firstMatch
        XCTAssertTrue(funding.waitForExistence(timeout: 10))
        funding.tap()
        let confirmed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Confirmed estimate")).firstMatch
        XCTAssertTrue(confirmed.waitForExistence(timeout: 10))
        confirmed.tap()

        // 7. Mark paid, then undo — proven through the selection summary label.
        let paidButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.paid.")).firstMatch
        XCTAssertTrue(paidButton.waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.staticTexts["plan.mode"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["plan.mode"].label, "What-if draft — saved plan unchanged")
        let toggleDraft = app.buttons["plan.toggleDraft"]
        for _ in 0..<8 where !toggleDraft.exists { app.swipeUp() }
        XCTAssertTrue(toggleDraft.waitForExistence(timeout: 10))
        toggleDraft.tap()
        let savedMode = app.staticTexts["plan.mode"]
        for _ in 0..<8 where !savedMode.exists { app.swipeDown() }
        XCTAssertTrue(savedMode.waitForExistence(timeout: 10))
        XCTAssertEqual(savedMode.label, "Saved plan — draft available")

        // 9. Orientation reflows, selected bill and draft mode survive.
        let rowAgain = firstBillRow()
        rowAgain.tap()
        XCTAssertTrue(app.staticTexts["plan.selectedBill"].waitForExistence(timeout: 10))
        let selectedLabel = app.staticTexts["plan.selectedBill"].label
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["plan.selectedBill"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["plan.selectedBill"].label, selectedLabel)
        XCTAssertEqual(app.staticTexts["plan.mode"].label, "Saved plan — draft available")
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
        XCTAssertTrue(app.buttons["plan.addBill"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Draft:")).firstMatch.exists)
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
