import Foundation
import XCTest
@testable import LocalLingo

final class AppleSpeechModulePlanTests: XCTestCase {
    func testHindiAlwaysSelectsDictationModules() {
        let hindiLocales = [
            Locale(identifier: "hi"),
            Locale(identifier: "hi-IN"),
            Locale(identifier: "hi-Latn-IN")
        ]

        for locale in hindiLocales {
            XCTAssertTrue(AppleSpeechModulePlan.usesDictation(for: locale))
            XCTAssertEqual(
                AppleSpeechModulePlan.implementation(for: locale, role: .manual),
                .progressiveLongDictation
            )
            XCTAssertEqual(
                AppleSpeechModulePlan.implementation(for: locale, role: .continuousLive),
                .progressiveLongDictation
            )
            XCTAssertEqual(
                AppleSpeechModulePlan.implementation(for: locale, role: .continuousFinal),
                .longDictation
            )
        }
    }

    func testExistingLanguagesPreserveSpeechTranscriberForEveryRole() {
        let locales = [
            Locale(identifier: "en-US"),
            Locale(identifier: "es-ES"),
            Locale(identifier: "fr-FR"),
            Locale(identifier: "de-DE"),
            Locale(identifier: "it-IT"),
            Locale(identifier: "pt-BR"),
            Locale(identifier: "ja-JP"),
            Locale(identifier: "ko-KR")
        ]
        let roles: [AppleSpeechModuleRole] = [
            .manual,
            .continuousLive,
            .continuousFinal
        ]

        for locale in locales {
            XCTAssertFalse(AppleSpeechModulePlan.usesDictation(for: locale))
            for role in roles {
                XCTAssertEqual(
                    AppleSpeechModulePlan.implementation(for: locale, role: role),
                    .speechTranscriber
                )
            }
        }
    }

    func testHindiAssetPlanCoversLiveAndFinalDictationConfigurations() {
        XCTAssertEqual(
            AppleSpeechModulePlan.assetRoles(for: Locale(identifier: "hi-IN")),
            [.continuousLive, .continuousFinal]
        )
        XCTAssertEqual(
            AppleSpeechModulePlan.assetRoles(for: Locale(identifier: "en-US")),
            [.manual]
        )
    }
}
