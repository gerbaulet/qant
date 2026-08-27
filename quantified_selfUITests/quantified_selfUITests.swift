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

        let addFoodButton = app.buttons["today.addFood"]
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
    func testQuickCaptureLaunchesDirectlyIntoCapture() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["--ui-testing", "--ui-testing-quick-capture"])
        app.launch()

        XCTAssertTrue(app.navigationBars["Schnellaufnahme"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["meal.comment"].exists)
        XCTAssertFalse(app.buttons["meal.save"].exists)
        XCTAssertEqual(app.descendants(matching: .any)["meal.captureForm"].value as? String, "Kamera")

        if app.alerts.buttons["OK"].waitForExistence(timeout: 1) {
            app.alerts.buttons["OK"].tap()
        }

        app.buttons["Abbrechen"].tap()
        XCTAssertTrue(app.buttons["today.addFood"].waitForExistence(timeout: 2))
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
        XCTAssertTrue(app.buttons["settings.createWeeklySummaryTestReminder"].waitForExistence(timeout: 2))
        app.swipeUp()
        XCTAssertTrue(app.secureTextFields["settings.openRouterAPIKey"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["settings.openRouterModelPicker"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["settings.loadOpenRouterModels"].waitForExistence(timeout: 2))
        let testConnectionButton = app.buttons["settings.testOpenRouter"]
        for _ in 0..<3 where !testConnectionButton.exists {
            app.swipeUp()
        }
        XCTAssertTrue(testConnectionButton.waitForExistence(timeout: 2))

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "OpenRouter settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testOpenRouterLogFinishesLoadingAndKeepsTabsResponsive() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launchArguments.append("--ui-testing-openrouter-log-entry")
        app.launch()

        let settingsTab = app.tabBars.buttons["Einstellungen"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 3))
        settingsTab.tap()

        let logLink = app.buttons["settings.openRouterTrafficLog"]
        for _ in 0..<8 where !logLink.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(logLink.waitForExistence(timeout: 2))
        logLink.tap()

        XCTAssertTrue(app.navigationBars["OpenRouter-Log"].waitForExistence(timeout: 2))
        let closeButton = app.buttons["settings.closeOpenRouterTrafficLog"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 2))
        let entry = app.buttons["settings.openRouterTrafficLogEntry.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"]
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.tap()

        XCTAssertTrue(app.navigationBars["Request-Details"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Request"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Response"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Bitte analysieren'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Testantwort'")).firstMatch.exists)

        for _ in 0..<6 {
            app.swipeUp()
        }

        let backButton = app.navigationBars["Request-Details"].buttons["OpenRouter-Log"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 2))
        backButton.tap()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 2))
        closeButton.tap()
        XCTAssertTrue(app.navigationBars["Einstellungen"].waitForExistence(timeout: 2))

        let todayTab = app.tabBars.buttons["Heute"]
        XCTAssertTrue(todayTab.isHittable)
        todayTab.tap()
        XCTAssertTrue(app.buttons["today.addFood"].waitForExistence(timeout: 2))
    }

    func testStorageSectionUsesCompactHeight() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let settingsTab = app.tabBars.buttons["Einstellungen"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 3))
        settingsTab.tap()

        let storageSection = app.otherElements["settings.storageSection"]
        for _ in 0..<5 where !storageSection.isHittable {
            app.swipeUp()
        }

        XCTAssertTrue(storageSection.waitForExistence(timeout: 2))
        XCTAssertLessThan(storageSection.frame.height, app.frame.height * 0.5)
    }

    @MainActor
    func testMealsTitleStaysAboveGroupingControl() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let mealsTab = app.tabBars.buttons["Mahlzeiten"]
        XCTAssertTrue(mealsTab.waitForExistence(timeout: 3))
        mealsTab.tap()

        let navigationBar = app.navigationBars["Mahlzeiten"]
        let daySegment = app.buttons["Tag"]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 2))
        XCTAssertTrue(daySegment.waitForExistence(timeout: 2))
        XCTAssertLessThanOrEqual(navigationBar.frame.maxY, daySegment.frame.minY)
    }

    @MainActor
    func testReviewsAndConfirmsNutritionEstimate() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-testing",
            "--ui-testing-review-confirmation",
        ])
        app.launch()

        let mealName = app.staticTexts["Chicken Curry mit Reis"]
        XCTAssertTrue(mealName.waitForExistence(timeout: 3))
        mealName.tap()

        XCTAssertTrue(app.navigationBars["Analyse prüfen"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["~785 kcal"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["meal.confirm"].waitForExistence(timeout: 2))

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Nutrition analysis review"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["meal.confirm"].tap()
        XCTAssertTrue(app.staticTexts["Bestätigt"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testShowsFiberOnTodayAndMealDetails() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-testing",
            "--ui-testing-review-confirmation",
        ])
        app.launch()

        let dailyFiber = app.descendants(matching: .any)["today.nutrient.fiber"]
        XCTAssertTrue(dailyFiber.waitForExistence(timeout: 3))

        let mealName = app.staticTexts["Chicken Curry mit Reis"]
        XCTAssertTrue(mealName.waitForExistence(timeout: 3))
        mealName.tap()

        let mealFiber = app.descendants(matching: .any)["meal.nutrient.fiber"]
        XCTAssertTrue(mealFiber.waitForExistence(timeout: 2))
    }

    @MainActor
    func testDeletesMealFromReview() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-testing",
            "--ui-testing-review-confirmation",
        ])
        app.launch()

        let mealName = app.staticTexts["Chicken Curry mit Reis"]
        XCTAssertTrue(mealName.waitForExistence(timeout: 3))
        mealName.tap()

        XCTAssertTrue(app.buttons["meal.delete"].waitForExistence(timeout: 2))
        app.buttons["meal.delete"].tap()
        XCTAssertTrue(app.buttons["Mahlzeit löschen"].waitForExistence(timeout: 2))
        app.buttons["Mahlzeit löschen"].tap()

        XCTAssertTrue(app.navigationBars["Analyse prüfen"].waitForNonExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Chicken Curry mit Reis"].exists)
    }

    @MainActor
    func testQuickCaptureDismissesMealReviewAndOpensCamera() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-testing",
            "--ui-testing-review-confirmation",
            "--ui-testing-quick-capture-from-review",
        ])
        app.launch()

        let mealName = app.staticTexts["Chicken Curry mit Reis"]
        XCTAssertTrue(mealName.waitForExistence(timeout: 3))
        mealName.tap()
        XCTAssertTrue(app.navigationBars["Analyse prüfen"].waitForExistence(timeout: 2))

        let captureForm = app.descendants(matching: .any)["meal.captureForm"]
        XCTAssertTrue(captureForm.waitForExistence(timeout: 4))
        XCTAssertEqual(captureForm.value as? String, "Kamera")
        XCTAssertFalse(app.navigationBars["Analyse prüfen"].exists)
    }

    @MainActor
    func testPresentsClarificationChoices() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-testing",
            "--ui-testing-review-clarification",
        ])
        app.launch()

        let mealName = app.staticTexts["Chicken Curry mit Reis"]
        XCTAssertTrue(mealName.waitForExistence(timeout: 3))
        mealName.tap()

        XCTAssertTrue(app.textFields["meal.clarificationAnswer"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["meal.bestEstimate"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["meal.submitClarification"].isEnabled)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Nutrition clarification"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testShowsAnalysisFailureReasonInMealDetails() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-testing",
            "--ui-testing-review-failure",
        ])
        app.launch()

        let mealButton = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "meal.open."))
            .firstMatch
        XCTAssertTrue(mealButton.waitForExistence(timeout: 3))
        mealButton.tap()

        XCTAssertTrue(app.navigationBars["Analyse prüfen"].waitForExistence(timeout: 2))
        let reason = app.descendants(matching: .any)["meal.analysisFailureReason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Grund des Fehlers"].exists)
        XCTAssertTrue(app.staticTexts["OpenRouter-Fehler 400: Kein Anbieter unterstützt strukturierte Ausgaben."].exists)
    }

}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
