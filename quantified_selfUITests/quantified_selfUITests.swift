//
//  QuantUITests.swift
//  QuantUITests
//
//  Created by Clemens Gerbaulet on 23.08.26.
//

import XCTest

final class QuantUITests: XCTestCase {

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
        XCTAssertTrue(app.descendants(matching: .any)["meal.detailsDisclosure"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["meal.timestamp"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["meal.categoryDisclosure"].exists)
        XCTAssertFalse(app.staticTexts["Art der Mahlzeit"].exists)

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
                ["Ausstehend", "Wird analysiert", "Fehlgeschlagen", "Rückfrage"]
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
    func testConfirmsInteractiveDismissForUnsavedMealCapture() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let addFoodButton = app.buttons["today.addFood"]
        XCTAssertTrue(addFoodButton.waitForExistence(timeout: 3))
        addFoodButton.tap()

        let captureNavigationBar = app.navigationBars["Neue Mahlzeit"]
        XCTAssertTrue(captureNavigationBar.waitForExistence(timeout: 2))
        let commentField = app.textFields["meal.comment"]
        for _ in 0..<3 where !commentField.isHittable { app.swipeUp() }
        XCTAssertTrue(commentField.isHittable)
        commentField.tap()
        commentField.typeText("Nicht gespeicherte Mahlzeit")
        app.buttons["Fertig"].tap()

        let discardButton = app.buttons["Verwerfen"]
        let dismissHandle = app.descendants(matching: .any)["meal.dismissHandle"]
        XCTAssertTrue(dismissHandle.waitForExistence(timeout: 2))
        let sheetHandle = dismissHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dismissTarget = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        sheetHandle.press(forDuration: 0.1, thenDragTo: dismissTarget)
        XCTAssertTrue(discardButton.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Änderungen verwerfen?"].exists)

        app.buttons["Weiter bearbeiten"].tap()
        XCTAssertTrue(captureNavigationBar.exists)
        app.buttons["Abbrechen"].tap()
        XCTAssertTrue(discardButton.waitForExistence(timeout: 2))
        discardButton.tap()
        XCTAssertTrue(captureNavigationBar.waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testTrendsUsesSharedCardLayout() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let trendsTab = app.tabBars.buttons["Trends"]
        XCTAssertTrue(trendsTab.waitForExistence(timeout: 3))
        trendsTab.tap()

        XCTAssertTrue(app.navigationBars["Trends"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["trends.chartCard"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["trends.comparisonCard"].exists)
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
        let advancedModelOptions = app.buttons["settings.openRouterAdvancedModelOptions"]
        XCTAssertTrue(advancedModelOptions.waitForExistence(timeout: 2))
        advancedModelOptions.tap()
        XCTAssertTrue(app.textFields["settings.openRouterManualModelIdentifier"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["settings.openRouterProviderPreference"].waitForExistence(timeout: 2))
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
    func testTodayKeepsScrollPositionAcrossTabSwitches() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-testing",
            "--ui-testing-review-confirmation",
        ])
        app.launch()

        let mealName = app.staticTexts["Chicken Curry mit Reis"]
        for _ in 0..<5 where !mealName.isHittable || mealName.frame.midY > app.frame.height * 0.7 {
            app.swipeUp()
        }
        XCTAssertTrue(mealName.waitForExistence(timeout: 3))
        XCTAssertTrue(mealName.isHittable)
        let positionBeforeSwitch = mealName.frame.midY

        let mealsTab = app.tabBars.buttons["Mahlzeiten"]
        XCTAssertTrue(mealsTab.isHittable)
        mealsTab.tap()
        XCTAssertTrue(app.navigationBars["Mahlzeiten"].waitForExistence(timeout: 2))

        let todayTab = app.tabBars.buttons["Heute"]
        XCTAssertTrue(todayTab.isHittable)
        todayTab.tap()
        XCTAssertTrue(mealName.waitForExistence(timeout: 2))
        XCTAssertTrue(mealName.isHittable)
        XCTAssertEqual(mealName.frame.midY, positionBeforeSwitch, accuracy: 20)
    }

    @MainActor
    func testSearchesMealsByCurrentAnalysisContent() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-testing",
            "--ui-testing-review-confirmed",
        ])
        app.launch()

        let mealsTab = app.tabBars.buttons["Mahlzeiten"]
        XCTAssertTrue(mealsTab.waitForExistence(timeout: 3))
        mealsTab.tap()

        let searchField = app.searchFields["Mahlzeiten durchsuchen"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.tap()
        searchField.typeText("Reis")
        XCTAssertTrue(app.staticTexts["Chicken Curry mit Reis"].waitForExistence(timeout: 2))

        let clearSearch = searchField.buttons
            .matching(NSPredicate(format: "label IN %@", ["Clear text", "Text löschen"]))
            .firstMatch
        XCTAssertTrue(clearSearch.waitForExistence(timeout: 2))
        clearSearch.tap()
        searchField.typeText("Kartoffelsalat")
        XCTAssertTrue(app.staticTexts["Keine Mahlzeiten gefunden"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Versuche einen anderen Suchbegriff."].exists)
    }

    @MainActor
    func testShowsLiveAnalysisRequestsAndPartialResults() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ui-testing-review-progress"]
        app.launch()
        let activity = app.buttons["analysis.activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 3))
        XCTAssertEqual(activity.label, "Laufende OpenRouter-Analysen: 1")
        activity.tap()
        XCTAssertTrue(app.navigationBars["Mahlzeit"].waitForExistence(timeout: 3))
        let counts = app.staticTexts["meal.analysisProgress.counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 3))
        XCTAssertEqual(counts.label, "3 Anfragen gestartet · 1 laufen · 1 erfolgreich · 1 fehlgeschlagen")
        XCTAssertTrue(app.staticTexts["Anfrage 1 · Erfolgreich"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Anfrage 2 · Fehlgeschlagen"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Fehler: Die Ernährungsanalyse konnte nicht gelesen werden."].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Anfrage 3 · Antwort steht aus")).firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["meal.analysisProgress.status.3"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["meal.analysisProgress.status.3"].label.contains("JSON wird empfangen"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Antwort begonnen:")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Erstes JSON:")).firstMatch.exists)
        XCTAssertTrue(app.scrollViews["meal.analysisProgress.stream.3"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "estimatedTotalWeightGrams")).firstMatch.exists)
    }

    @MainActor
    func testReviewsAutomaticallyConfirmedNutritionEstimate() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-testing",
            "--ui-testing-review-confirmation",
        ])
        app.launch()

        let mealName = app.staticTexts["Chicken Curry mit Reis"]
        XCTAssertTrue(mealName.waitForExistence(timeout: 3))
        mealName.tap()

        XCTAssertTrue(app.navigationBars["Mahlzeit"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.tabBars.buttons["Heute"].exists)
        XCTAssertTrue(app.staticTexts["~785 kcal"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Bestätigt"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["meal.confirm"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["meal.actionBar"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Nutrition analysis review"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
    func testShowsNutritionValuesForEachMealComponent() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-testing",
            "--ui-testing-review-confirmation",
        ])
        app.launch()

        let mealName = app.staticTexts["Chicken Curry mit Reis"]
        XCTAssertTrue(mealName.waitForExistence(timeout: 3))
        mealName.tap()

        let rice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reis,")).firstMatch
        for _ in 0..<4 where !rice.isHittable || rice.frame.maxY > app.frame.height * 0.65 {
            app.swipeUp()
        }
        XCTAssertTrue(rice.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["~160 g"].exists)
        XCTAssertFalse(app.sliders["meal.componentMultiplier.1"].exists)
        rice.tap()
        XCTAssertTrue(app.sliders["meal.componentMultiplier.1"].waitForExistence(timeout: 2))

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "~285 kcal")).firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "~6,0 g")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "~72 g")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "~0,0 g")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "~5,0 g")).firstMatch.exists)
    }

    @MainActor
    func testPersistsIndividualComponentPortion() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ui-testing-review-confirmation"]
        app.launch()
        let mealName = app.staticTexts["Chicken Curry mit Reis"]
        XCTAssertTrue(mealName.waitForExistence(timeout: 3))
        mealName.tap()
        let rice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reis,")).firstMatch
        for _ in 0..<4 where !rice.isHittable || rice.frame.maxY > app.frame.height * 0.65 { app.swipeUp() }
        rice.tap()
        let slider = app.sliders["meal.componentMultiplier.1"]
        for _ in 0..<3 where !slider.isHittable || slider.frame.maxY > app.frame.height * 0.65 { app.swipeUp() }
        XCTAssertTrue(slider.waitForExistence(timeout: 2))
        slider.adjust(toNormalizedSliderPosition: 0.5)
        let adjustedValue = try XCTUnwrap(slider.value as? String)
        let multiplier = try XCTUnwrap(Double(adjustedValue.replacingOccurrences(of: "-fach", with: "").replacingOccurrences(of: ",", with: ".")))
        XCTAssertGreaterThan(multiplier, 1)
        let energy = "~\(Int((285 * multiplier).rounded())) kcal"
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", energy)).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["~280 g"].exists)
        app.navigationBars["Mahlzeit"].buttons["Heute"].tap()
        mealName.tap()
        for _ in 0..<4 where !rice.isHittable || rice.frame.maxY > app.frame.height * 0.65 { app.swipeUp() }
        rice.tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 2))
        XCTAssertEqual(slider.value as? String, adjustedValue)
        XCTAssertTrue(app.staticTexts["~\(Int((160 * multiplier).rounded())) g"].exists)
    }

    @MainActor
    func testPersistsAdjustedPortionAfterSliderInteraction() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-testing",
            "--ui-testing-review-confirmation",
        ])
        app.launch()

        let mealName = app.staticTexts["Chicken Curry mit Reis"]
        XCTAssertTrue(mealName.waitForExistence(timeout: 3))
        mealName.tap()

        let slider = app.sliders["meal.portionMultiplier"]
        XCTAssertTrue(slider.waitForExistence(timeout: 2))
        slider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue((slider.value as? String)?.contains("2") == true)

        app.navigationBars["Mahlzeit"].buttons["Heute"].tap()
        XCTAssertTrue(app.navigationBars["Mahlzeit"].waitForNonExistence(timeout: 2))
        mealName.tap()

        let reopenedSlider = app.sliders["meal.portionMultiplier"]
        XCTAssertTrue(reopenedSlider.waitForExistence(timeout: 2))
        XCTAssertTrue((reopenedSlider.value as? String)?.contains("2") == true)
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

        XCTAssertTrue(app.buttons["meal.actions"].waitForExistence(timeout: 2))
        app.buttons["meal.actions"].tap()
        XCTAssertTrue(app.buttons["meal.delete"].waitForExistence(timeout: 2))
        app.buttons["meal.delete"].tap()
        XCTAssertTrue(app.buttons["Mahlzeit löschen"].waitForExistence(timeout: 2))
        app.buttons["Mahlzeit löschen"].tap()

        XCTAssertTrue(app.navigationBars["Mahlzeit"].waitForNonExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Chicken Curry mit Reis"].exists)
    }

    @MainActor
    func testDuplicatesConfirmedMealFromReview() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-testing",
            "--ui-testing-review-confirmed",
        ])
        app.launch()

        let mealName = app.staticTexts["Chicken Curry mit Reis"]
        XCTAssertTrue(mealName.waitForExistence(timeout: 3))
        mealName.tap()

        XCTAssertTrue(app.buttons["meal.actions"].waitForExistence(timeout: 2))
        app.buttons["meal.actions"].tap()
        let duplicateButton = app.buttons["meal.duplicate"]
        XCTAssertTrue(duplicateButton.waitForExistence(timeout: 2))
        duplicateButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["meal.duplicateSuccess"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Mahlzeit"].exists)

        app.navigationBars["Mahlzeit"].buttons["Heute"].tap()
        XCTAssertTrue(app.navigationBars["Mahlzeit"].waitForNonExistence(timeout: 2))
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "Chicken Curry mit Reis")).count,
            2
        )
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

        let mealButton = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "meal.open."))
            .firstMatch
        XCTAssertTrue(mealButton.waitForExistence(timeout: 5))
        mealButton.tap()

        let captureForm = app.descendants(matching: .any)["meal.captureForm"]
        XCTAssertTrue(captureForm.waitForExistence(timeout: 4))
        XCTAssertEqual(captureForm.value as? String, "Kamera")
        XCTAssertFalse(app.navigationBars["Mahlzeit"].exists)
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

        let answerField = app.textFields["meal.clarificationAnswer"]
        let submitButton = app.buttons["meal.submitClarification"]
        XCTAssertTrue(answerField.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["meal.bestEstimate"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["meal.actionBar"].exists)
        XCTAssertFalse(submitButton.isEnabled)

        answerField.tap()
        answerField.typeText("Etwa 250 Gramm")
        XCTAssertTrue(answerField.isHittable)
        XCTAssertTrue(submitButton.isHittable)
        XCTAssertLessThanOrEqual(answerField.frame.maxY, submitButton.frame.minY)

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

        XCTAssertTrue(app.navigationBars["Mahlzeit"].waitForExistence(timeout: 2))
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
