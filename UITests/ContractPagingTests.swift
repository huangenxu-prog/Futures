import XCTest

final class ContractPagingTests: XCTestCase {
    func testEntryAndTwentyPageTransitions() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["全部品种"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "contract.row."))
        let ids = rows.allElementsBoundByIndex.filter { $0.isHittable }.prefix(4)
            .map { String($0.identifier.dropFirst("contract.row.".count)) }
        XCTAssertGreaterThanOrEqual(ids.count, 3)
        guard ids.count >= 3 else { return }

        func checkPage(_ id: String) {
            let page = app.descendants(matching: .any)["contract.page." + id].firstMatch
            let viewport = app.scrollViews["contract.viewport"].firstMatch
            let aligned = NSPredicate { _, _ in
                guard page.exists, viewport.exists, viewport.frame.height > 0 else { return false }
                return abs(page.frame.minY - viewport.frame.minY) <= 1 &&
                    abs(page.frame.maxY - viewport.frame.maxY) <= 1 &&
                    app.buttons["contract.back"].firstMatch.isHittable
            }
            let ready = XCTNSPredicateExpectation(predicate: aligned, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, id)
        }
        for id in ids {
            app.buttons["contract.row." + id].tap()
            checkPage(id)
            app.buttons["contract.back"].firstMatch.tap()
        }
        app.buttons["contract.row." + ids[1]].tap()
        checkPage(ids[1])
        let viewport = app.scrollViews["contract.viewport"].firstMatch
        for step in 0..<20 {
            let forward = step.isMultiple(of: 2)
            let top = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.20))
            let bottom = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.80))
            (forward ? bottom : top).press(forDuration: 0.05, thenDragTo: forward ? top : bottom)
            checkPage(ids[forward ? 2 : 1])
        }
    }
}
