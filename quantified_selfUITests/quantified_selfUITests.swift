//
//  quantified_selfUITests.swift
//  quantified_selfUITests
//
//  Created by Clemens Gerbaulet on 23.08.26.
//

import XCTest

final class quantified_selfUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCapturesMealLocally() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let addFoodButton = app.buttons["Essen hinzufügen"]
        XCTAssertTrue(addFoodButton.waitForExistence(timeout: 3))
        addFoodButton.tap()

        let captureNavigationBar = app.navigationBars["Neue Mahlzeit"]
        XCTAssertTrue(captureNavigationBar.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["meal.photoLibrary"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["meal.camera"].waitForExistence(timeout: 2))

        let captureScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        captureScreenshot.name = "Meal capture"
        captureScreenshot.lifetime = .keepAlways
        add(captureScreenshot)

        let commentField = app.textFields["meal.comment"]
        XCTAssertTrue(commentField.waitForExistence(timeout: 2))
        app.swipeUp()
        commentField.tap()
        commentField.typeText("UI-Test Mahlzeit")

        app.buttons["meal.save"].tap()
        XCTAssertTrue(captureNavigationBar.waitForNonExistence(timeout: 2))

        app.swipeUp()
        let savedMealState = app.staticTexts
            .matching(NSPredicate(
                format: "label IN %@",
                ["Ausstehend", "Wird analysiert", "Fehlgeschlagen", "Zu bestätigen", "Rückfrage"]
            ))
            .firstMatch
        XCTAssertTrue(savedMealState.waitForExistence(timeout: 2))

        let retryButton = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "meal.retry."))
            .firstMatch
        XCTAssertTrue(retryButton.waitForExistence(timeout: 2))

        let savedMealScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        savedMealScreenshot.name = "Saved meal analysis failure and retry"
        savedMealScreenshot.lifetime = .keepAlways
        add(savedMealScreenshot)
    }

    @MainActor
    func testPresentsSecureOpenRouterSettings() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let settingsTab = app.tabBars.buttons["Einstellungen"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 3))
        settingsTab.tap()

        XCTAssertTrue(app.navigationBars["Einstellungen"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.secureTextFields["settings.openRouterAPIKey"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["settings.openRouterModel"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["settings.testOpenRouter"].waitForExistence(timeout: 2))

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "OpenRouter settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
