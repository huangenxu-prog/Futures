import XCTest

final class ContractPagingTests: XCTestCase {
    func testEntryAndTwentyPageTransitions() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments.append("-contract-paging-test")
        app.launch()
        app.buttons["全部品种"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "contract.row."))
        let ids = rows.allElementsBoundByIndex.filter { $0.isHittable }.prefix(4)
            .map { String($0.identifier.dropFirst("contract.row.".count)) }
        XCTAssertGreaterThanOrEqual(ids.count, 3)
        guard ids.count >= 3 else { return }

        func checkPage(_ id: String) {
            let back = app.buttons["contract.back." + id]
            XCTAssertTrue(back.waitForExistence(timeout: 20), id)
            var evidence = ""
            let aligned = NSPredicate { _, _ in
                guard let root = try? app.snapshot() else { return false }
                var frames: [String: CGRect] = [:]
                func visit(_ node: XCUIElementSnapshot) {
                    if node.identifier.hasPrefix("contract.") { frames[node.identifier] = node.frame }
                    for child in node.children { visit(child) }
                }
                visit(root)
                evidence = String(describing: frames)
                guard let page = frames["contract.page." + id],
                      let viewport = frames["contract.viewport"],
                      let header = frames["contract.back." + id],
                      viewport.height > 0, viewport.contains(header) else { return false }
                return abs(page.minY - viewport.minY) <= 1 && abs(page.maxY - viewport.maxY) <= 1
            }
            let ready = XCTNSPredicateExpectation(predicate: aligned, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, id + " " + evidence)

        }
        for id in ids {
            app.buttons["contract.row." + id].tap()
            checkPage(id)
            app.buttons["contract.back." + id].firstMatch.tap()
        }
        app.buttons["contract.row." + ids[1]].tap()
        checkPage(ids[1])
        let viewport = app
        for step in 0..<20 {
            let forward = step.isMultiple(of: 2)
            let top = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.20))
            let bottom = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.80))
            (forward ? bottom : top).press(forDuration: 0.05, thenDragTo: forward ? top : bottom)
            checkPage(ids[forward ? 2 : 1])
        }
    }
}
