import XCTest
@testable import LocalLingo

final class CarefulModePresentationTests: XCTestCase {
    func testSourceAndTranslationCriticalDetailsRemainSeparateAndLabeled() {
        let source = CriticalEntity(kind: .medication, value: "warfarin", normalizedValue: "WARFARIN")
        let translation = CriticalEntity(kind: .medication, value: "warfarina", normalizedValue: "WARFARIN")
        let presentation = CarefulModePresentation(report: report(source: [source], translation: [translation]))

        XCTAssertEqual(CarefulModePresentation.sourceLabel, "Source critical details")
        XCTAssertEqual(CarefulModePresentation.translationLabel, "Translation critical details")
        XCTAssertNotEqual(CarefulModePresentation.sourceLabel, CarefulModePresentation.translationLabel)
        XCTAssertEqual(presentation.sourceEntities, [source])
        XCTAssertEqual(presentation.translationEntities, [translation])
        XCTAssertTrue(presentation.showsEntitySections)
    }

    func testTargetOnlyMedicationOrEmergencyStillShowsMedicalWarning() {
        let inventedMedication = CriticalEntity(kind: .medication, value: "amoxicilina", normalizedValue: "AMOXICILLIN")
        let presentation = CarefulModePresentation(report: report(source: [], translation: [inventedMedication]))

        XCTAssertTrue(presentation.sourceEntities.isEmpty)
        XCTAssertEqual(presentation.translationEntities, [inventedMedication])
        XCTAssertTrue(presentation.requiresMedicalOrEmergencyWarning)
        XCTAssertTrue(presentation.showsEntitySections)
    }

    func testRenderedEntitiesAreBoundedIndependentlyOnBothSides() {
        let count = ConversationContentPolicy.maximumRenderedSafetyEntities + 7
        let source = (0..<count).map { CriticalEntity(kind: .number, value: "\($0)", normalizedValue: "\($0)") }
        let translation = (0..<count).map { CriticalEntity(kind: .number, value: "\($0)", normalizedValue: "\($0)") }
        let presentation = CarefulModePresentation(report: report(source: source, translation: translation))

        XCTAssertEqual(presentation.sourceEntities.count, ConversationContentPolicy.maximumRenderedSafetyEntities)
        XCTAssertEqual(presentation.translationEntities.count, ConversationContentPolicy.maximumRenderedSafetyEntities)
        XCTAssertEqual(presentation.sourceOmittedCount, 7)
        XCTAssertEqual(presentation.translationOmittedCount, 7)
    }

    private func report(source: [CriticalEntity], translation: [CriticalEntity]) -> EntityIntegrityReport {
        EntityIntegrityReport(
            source: source,
            translation: translation,
            missingKinds: [],
            mismatchedValues: [],
            inventedValues: [],
            extractionLimitExceeded: false
        )
    }
}
