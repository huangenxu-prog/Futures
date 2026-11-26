import XCTest

final class DetailPagerUITests: XCTestCase {
    private let app = XCUIApplication()
    private let ids = ["DCE.m", "CZCE.SR", "SHFE.au"]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(light: Bool) {
        app.launchArguments = ["-detail-pager-ui-test"] + (light ? ["-test-light"] : [])
        app.launch()
        app.buttons["全部品种"].tap()
    }

    private func enter(_ index: Int) {
        let cell = app.cells.element(boundBy: index)
        XCTAssertTrue(cell.waitForExistence(timeout: 8))
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.19, dy: 0.5)).tap()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func verify(_ index: Int, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.buttons["detail.contract." + ids[index]]
        XCTAssertTrue(title.exists || title.waitForExistence(timeout: 5), "Wrong contract", file: file, line: line)
        XCTAssertTrue(title.isHittable, file: file, line: line)
        let viewport = element("detail.viewport").frame
        let footer = app.buttons["指标参数设置"]
        XCTAssertTrue(footer.exists || footer.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(footer.isHittable, file: file, line: line)
        XCTAssertGreaterThan(viewport.height, app.frame.height * 0.80, file: file, line: line)
        XCTAssertEqual(footer.frame.maxY, viewport.maxY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(title.frame.minY, viewport.minY, accuracy: 2, file: file, line: line)
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func drag(_ x: CGFloat, _ y: CGFloat, to endX: CGFloat, _ endY: CGFloat) {
        point(x, y).press(forDuration: 0.02, thenDragTo: point(endX, endY), withVelocity: .fast, thenHoldForDuration: 0)
    }

    func testHomeEntriesAndImmediateSheet() {
        for light in [false, true] {
            launch(light: light)
            for entry in 0..<15 {
                let index = entry % 3
                enter(index)
                if entry < 3 {
                    app.buttons["下单"].tap()
                    XCTAssertTrue(app.navigationBars["快捷开仓"].waitForExistence(timeout: 5))
                    XCTAssertTrue(app.buttons["关闭"].isHittable)
                    app.buttons["关闭"].tap()
                }
                verify(index)
                app.buttons["detail.back"].tap()
            }
            app.terminate()
        }
    }

    func testChartInputAndPaging() {
        launch(light: false)
        enter(0)
        verify(0)
        XCTAssertEqual(element("detail.viewport").value as? String, "pages=3")
        drag(0.50, 0.41, to: 0.50, 0.79)
        verify(0)
        for step in 0..<32 {
            let index = [1, 2, 1, 0][step % 4]
            if step % 4 < 2 { drag(0.50, 0.79, to: 0.50, step % 2 == 0 ? 0.40 : 0.19) }
            else { drag(0.50, 0.30, to: 0.50, 0.92) }
            if !app.buttons["detail.contract." + ids[index]].exists {
                print("PAGER TRACE", element("detail.viewport").value ?? "")
            }
            verify(index)
            if step == 1 {
                drag(0.50, 0.82, to: 0.50, 0.19)
                verify(2)
            }
        }
        drag(0.22, 0.49, to: 0.77, 0.49)
        XCTAssertTrue(app.buttons["回到最新K线"].waitForExistence(timeout: 5))
        verify(0)
        element("detail.viewport").pinch(withScale: 1.7, velocity: 1)
        verify(0)
        XCUIDevice.shared.press(.home)
        app.activate()
        verify(0)
    }
}
