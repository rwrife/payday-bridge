import XCTest

/// Journey for issue #4. XCUITest cannot read Application Support on the
/// simulator, so persistence is proven by relaunch (same installed app data),
/// not by inspecting files from the test process.
final class PaydayBridgeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch() // CI simulator starts with a fresh app container.
    }

    func testWorksheetDraftAndPaidFlow() throws {
        // 1. Create the worksheet.
        let create = app.buttons["plan.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        XCTAssertTrue(app.buttons["plan.addIncome"].waitForExistence(timeout: 10))

        // 2. Add confirmed income dated today.
        app.buttons["plan.addIncome"].tap()
        app.buttons["editor.status"].tap()
        app.buttons["Confirmed estimate"].tap()
        let incomeAmount = app.textFields["editor.amount"]
        incomeAmount.waitAndTap()
        incomeAmount.typeText("500.00")
        app.buttons["editor.save"].tap()

        // 3. Add a monthly bill with an unknown amount.
        app.buttons["plan.addBill"].tap()
        app.switches["editor.unknown"].switches.firstMatch.tap()
        app.switches["editor.monthly"].switches.firstMatch.tap()
        let billTitle = app.textFields["editor.title"]
        billTitle.waitAndTap()
        billTitle.typeText("Rent")
        app.buttons["editor.save"].tap()
        let warning = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.warning.")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        XCTAssertTrue(warning.label.contains("unknownAmount"))
        XCTAssertTrue(warning.label.contains("unassigned"))

        // 4. Assign the bill to the confirmed income (late/expected explanation appears).
        dismissKeyboard()
        let funding = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.funding.")).firstMatch
        XCTAssertTrue(funding.waitForExistence(timeout: 10))
        funding.tap()
        let confirmed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "confirmed")).firstMatch
        XCTAssertTrue(confirmed.waitForExistence(timeout: 10))
        confirmed.tap()

        // 5. Mark paid, then undo.
        dismissKeyboard()
        let paidButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.paid.")).firstMatch
        XCTAssertTrue(paidButton.waitForExistence(timeout: 10))
        paidButton.tap()
        let undo = NSPredicate(format: "label == %@", "Undo paid")
        expectation(for: undo, evaluatedWith: paidButton)
        waitForExpectations(timeout: 10)
        paidButton.tap()
        let unpaid = NSPredicate(format: "label == %@", "Mark paid")
        expectation(for: unpaid, evaluatedWith: paidButton)
        waitForExpectations(timeout: 10)

        // 6. Draft comparison: a what-if draft cannot mutate the saved plan.
        app.buttons["plan.beginDraft"].tap()
        XCTAssertTrue(app.staticTexts["plan.mode"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["plan.mode"].label, "What-if draft — saved plan unchanged")
        app.buttons["plan.toggleDraft"].tap()
        XCTAssertEqual(app.staticTexts["plan.mode"].label, "Saved plan — draft available")

        // 7. Destructive delete asks for confirmation first.
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Delete Rent")).firstMatch.tap()
        app.buttons["Delete bill"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Edit Rent")).firstMatch.exists)

        // 8. Restart: data reloads from the device container.
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
