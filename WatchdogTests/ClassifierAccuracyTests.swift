import XCTest
@testable import Watchdog

final class ClassifierAccuracyTests: XCTestCase {
    func testFixtureLoads() throws {
        let (fixture, labels) = try loadAccuracyInputs()
        XCTAssertEqual(fixture.rows.count, 1_151)
        XCTAssertEqual(labels.labels.count, 166)
    }

    func testClassifierMatchesLabels() throws {
        let (fixture, labels) = try loadAccuracyInputs()
        let report = ClassifierAudit.audit(fixture: fixture, labels: labels.labels)
        let interesting = report.mismatches.filter { !$0.tolerated }
        let preview = interesting.prefix(10).map {
            "pid \($0.pid) \($0.field) expected=\($0.expected) actual=\($0.actual)"
        }.joined(separator: "\n")
        let message = """
        허용되지 않은 불일치 \(report.untoleratedMismatchCount)건 (허용 \(report.toleratedMismatchCount)건)
        \(preview)
        """

        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        XCTExpectFailure("A2 before service/orphan rules", options: options) {
            XCTAssertEqual(report.untoleratedMismatchCount, 0, message)
        }
    }

    func testAuditReportIsStable() throws {
        let (fixture, labels) = try loadAccuracyInputs()
        let first = ClassifierAudit.audit(fixture: fixture, labels: labels.labels)
        let second = ClassifierAudit.audit(fixture: fixture, labels: labels.labels)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.render(), second.render())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let firstJSON = try encoder.encode(first)
        let secondJSON = try encoder.encode(second)
        XCTAssertEqual(firstJSON, secondJSON)
    }

    private func loadAccuracyInputs() throws -> (ProcessFixture, ProcessLabelFile) {
        let fixture = try JSONDecoder().decode(ProcessFixture.self, from: Data(contentsOf: fixtureURL("mac-20261030")))
        let labels = try JSONDecoder().decode(
            ProcessLabelFile.self,
            from: Data(contentsOf: fixtureURL("mac-20261030.labels"))
        )
        return (fixture, labels)
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: ClassifierAccuracyTests.self)
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") {
            return url
        }
        return try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "json"),
            "테스트 번들에 \(name).json 이 없습니다 (\(bundle.bundlePath))"
        )
    }
}
