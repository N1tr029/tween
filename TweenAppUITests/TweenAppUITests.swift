//
//  TweenAppUITests.swift
//  TweenAppUITests
//

import XCTest

final class TweenAppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchSuggestionsRenderWhileTyping() {
        let app = launchApp("-TweenUITestSearch")

        XCTAssertTrue(app.textFields["Search coffee, lunch, parks..."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Search for “h”"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPlaceResultsAndDetailRender() {
        let app = launchApp("-TweenUITestResults")

        XCTAssertTrue(app.staticTexts["Places"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Starbucks Coffee"].waitForExistence(timeout: 5))

        let row = app.buttons["place-row-Starbucks Coffee"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(app.buttons["Open in Apple Maps"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy link"].exists)
    }

    @MainActor
    func testCloseDetailReturnsToPlaceResults() {
        let app = launchApp("-TweenUITestResults")

        let row = app.buttons["place-row-Starbucks Coffee"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(app.buttons["Open in Apple Maps"].waitForExistence(timeout: 5))
        app.buttons["Close detail"].tap()

        XCTAssertTrue(app.staticTexts["Places"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Open in Apple Maps"].waitForExistence(timeout: 1))
    }

    @MainActor
    func testCollapseButtonEscapesFullDetail() {
        let app = launchApp("-TweenUITestResults")

        let row = app.buttons["place-row-Starbucks Coffee"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["Open in Apple Maps"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["Expand sheet"].waitForExistence(timeout: 5))
        app.buttons["Expand sheet"].tap()
        XCTAssertTrue(app.buttons["Collapse sheet"].waitForExistence(timeout: 5))
        app.buttons["Collapse sheet"].tap()

        XCTAssertTrue(app.buttons["Expand sheet"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Open in Apple Maps"].waitForExistence(timeout: 1))
    }

    @MainActor
    func testWaitingTabShowsFriendControls() {
        let app = launchApp("-TweenUITestWaiting")

        XCTAssertTrue(app.staticTexts["Waiting"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Maya Ahmed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["No longer in"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Invite friends to Tween"].exists)
    }

    @MainActor
    func testMapPinTapOpensPlaceDetail() {
        let app = launchApp("-TweenUITestMapPin")

        let pin = app.buttons["map-place-Starbucks Coffee"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()

        XCTAssertTrue(app.buttons["Open in Apple Maps"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open in Google Maps"].exists)
    }

    @MainActor
    private func launchApp(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-TweenUITestState", state]
        app.launch()
        return app
    }
}
