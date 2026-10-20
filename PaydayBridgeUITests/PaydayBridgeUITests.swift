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
        app.textFields["editor.amount"].waitAndTap()
        app.keyboards.textFields.firstMatch.typeText("500.00")
        app.buttons["editor.save"].tap()

        // 3. Add a monthly bill with an unknown amount.
        app.buttons["plan.addBill"].tap()
        app.textFields["editor.title"].waitAndTap()
        app.keyboards.textFields.firstMatch.typeText("Rent")
        app.switches["editor.unknown"].switches.firstMatch.tap()
        app.switches["editor.monthly"].switches.firstMatch.tap()
        app.buttons["editor.save"].tap()
        let warning = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.warning.")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        XCTAssertTrue(warning.label.contains("unknownAmount"))
        XCTAssertTrue(warning.label.contains("unassigned"))

        // 4. Assign the bill to the confirmed income (late/expected explanation appears).
        let funding = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.funding.")).firstMatch
        XCTAssertTrue(funding.waitForExistence(timeout: 10))
        funding.tap()
        let confirmed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "confirmed")).firstMatch
        XCTAssertTrue(confirmed.waitForExistence(timeout: 10))
        confirmed.tap()

        // 5. Mark paid, then undo. Query the merged row switch, not the row.
        let paidButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Mark paid")).firstMatch
        XCTAssertTrue(paidButton.waitForExistence(timeout: 10))
        paidButton.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Undo paid")).firstMatch.waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Undo paid")).firstMatch.tap()

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
}

private extension XCUIElement {
    func waitAndTap(timeout: TimeInterval = 10) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "missing \(identifier)")
        tap()
    }
}
