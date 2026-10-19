import XCTest
@testable import LocalLingo

final class EntityIntegrityTests: XCTestCase {
    private let extractor = CriticalEntityExtractor()

    func testFindsSafetyCriticalValues() {
        let values = extractor.extract(from: "I am allergic to peanuts. The train is $24 at 18:30.")
        XCTAssertTrue(values.contains { $0.kind == .allergy })
        XCTAssertTrue(values.contains { $0.kind == .currency })
        XCTAssertTrue(values.contains { $0.kind == .time })
    }

    func testMismatchedNumberBlocksAutomaticPlayback() {
        let report = extractor.compare(source: "It costs $24", translation: "Cuesta $42")
        XCTAssertTrue(report.hasMismatch)
        XCTAssertTrue(report.requiresConfirmation)
    }

    func testPreservedNumberHasNoMismatch() {
        let report = extractor.compare(source: "Platform 12", translation: "Andén 12")
        XCTAssertFalse(report.hasMismatch)
    }

    func testSpanishAllergyAndNegationAreSafetyCritical() {
        let values = extractor.extract(from: "Tengo alergia al maní y no puedo comer lácteos.")
        XCTAssertTrue(values.contains { $0.kind == .allergy })
        XCTAssertTrue(values.contains { $0.kind == .negation })
        XCTAssertTrue(extractor.extract(from: "Soy alérgico").contains { $0.kind == .allergy })
    }

    func testJapaneseAllergyAndNegationAreSafetyCritical() {
        let values = extractor.extract(from: "ピーナッツアレルギーがあり、乳製品は食べられません。")
        XCTAssertTrue(values.contains { $0.kind == .allergy })
        XCTAssertTrue(values.contains { $0.kind == .negation })
    }

    func testAllergySubstitutionIsAMismatch() {
        let report = extractor.compare(source: "I am allergic to peanuts", translation: "Soy alérgico a los lácteos")
        XCTAssertTrue(report.hasMismatch)
        XCTAssertTrue(report.mismatchedValues.contains { $0.kind == .allergy && $0.normalizedValue == "PEANUT" })
    }

    func testProperNamePrefixDoesNotConsumeLowercaseSafetyText() {
        let values = extractor.extract(from: "I am allergic to peanuts")

        XCTAssertFalse(values.contains { $0.kind == .properName })
        XCTAssertTrue(values.contains { $0.kind == .allergy && $0.normalizedValue == "PEANUT" })
    }

    func testProperNameStillRequiresAndCapturesCapitalizedName() {
        let values = extractor.extract(from: "I am Ada Lovelace")

        XCTAssertTrue(values.contains { $0.kind == .properName && $0.normalizedValue == "adalovelace" })
    }

    func testCurrencyIdentityCannotChange() {
        let report = extractor.compare(source: "It costs $24", translation: "Cuesta 24 euros")
        XCTAssertTrue(report.hasMismatch)
    }

    func testNumberWordsAreCanonicalAcrossLanguages() {
        let report = extractor.compare(source: "Platform twelve", translation: "Andén doce")
        XCTAssertFalse(report.hasMismatch)
    }

    func testRelativeDatesAreCanonicalAcrossLanguages() {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let report = extractor.compare(source: "Come tomorrow", translation: "Ven mañana", sourceLocale: Locale(identifier: "en-US"), targetLocale: Locale(identifier: "es-ES"), referenceDate: fixed, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertFalse(report.hasMismatch)
    }

    func testFrenchBilingualSafetyProfile() {
        assertBilingualSafetyProfile(
            target: "Je m'appelle Mina. Je ne suis pas allergique aux arachides. Je prends de l'insuline. Appelez une ambulance demain.",
            substitutedTarget: "Je m'appelle Mina. Je ne suis pas allergique aux arachides. Je prends de l'ibuprofène. Appelez une ambulance demain.",
            localeIdentifier: "fr-FR",
            localizedNumericDate: "07/08/2026"
        )
    }

    func testGermanBilingualSafetyProfile() {
        assertBilingualSafetyProfile(
            target: "Ich heiße Mina. Ich bin nicht allergisch gegen Erdnüsse. Ich nehme Insulin. Rufen Sie morgen einen Krankenwagen.",
            substitutedTarget: "Ich heiße Mina. Ich bin nicht allergisch gegen Erdnüsse. Ich nehme Ibuprofen. Rufen Sie morgen einen Krankenwagen.",
            localeIdentifier: "de-DE",
            localizedNumericDate: "07.08.2026"
        )
    }

    func testItalianBilingualSafetyProfile() {
        assertBilingualSafetyProfile(
            target: "Mi chiamo Mina. Non sono allergica alle arachidi. Prendo insulina. Chiami un'ambulanza domani.",
            substitutedTarget: "Mi chiamo Mina. Non sono allergica alle arachidi. Prendo ibuprofene. Chiami un'ambulanza domani.",
            localeIdentifier: "it-IT",
            localizedNumericDate: "07/08/2026"
        )
    }

    func testBrazilianPortugueseBilingualSafetyProfile() {
        assertBilingualSafetyProfile(
            target: "Me chamo Mina. Não sou alérgica a amendoim. Tomo insulina. Chame uma ambulância amanhã.",
            substitutedTarget: "Me chamo Mina. Não sou alérgica a amendoim. Tomo ibuprofeno. Chame uma ambulância amanhã.",
            localeIdentifier: "pt-BR",
            localizedNumericDate: "07/08/2026"
        )
    }

    func testKoreanBilingualSafetyProfile() {
        assertBilingualSafetyProfile(
            target: "제 이름은 Mina입니다. 저는 땅콩 알레르기가 없고 인슐린을 복용합니다. 내일 구급차를 불러 주세요.",
            substitutedTarget: "제 이름은 Mina입니다. 저는 땅콩 알레르기가 없고 이부프로펜을 복용합니다. 내일 구급차를 불러 주세요.",
            localeIdentifier: "ko-KR",
            localizedNumericDate: "2026.08.07"
        )
    }

    func testHindiSafetyProfilePreservesCriticalEntitiesInBothDirections() {
        let english = "I am not allergic to peanuts. I take insulin. Call an ambulance Monday."
        let hindi = "मुझे मूंगफली से एलर्जी नहीं है। मैं इंसुलिन लेता हूँ। सोमवार को एम्बुलेंस बुलाएँ।"
        let sourceLocale = Locale(identifier: "en-US")
        let hindiLocale = Locale(identifier: "hi-IN")
        let requiredKinds: Set<CriticalEntityKind> = [
            .negation, .allergy, .medication, .emergency, .date,
        ]

        let forward = extractor.compare(
            source: english,
            translation: hindi,
            sourceLocale: sourceLocale,
            targetLocale: hindiLocale
        )
        let reverse = extractor.compare(
            source: hindi,
            translation: english,
            sourceLocale: hindiLocale,
            targetLocale: sourceLocale
        )

        for report in [forward, reverse] {
            XCTAssertFalse(report.hasMismatch, "Unexpected Hindi integrity mismatch: \(report)")
            XCTAssertTrue(report.requiresConfirmation)
            XCTAssertTrue(requiredKinds.isSubset(of: Set(report.source.map(\.kind))))
            XCTAssertTrue(requiredKinds.isSubset(of: Set(report.translation.map(\.kind))))
        }
    }

    func testHindiMedicationAndEmergencySubstitutionsFailInBothDirections() {
        let english = "I take insulin. Call an ambulance."
        let substitutedHindi = "मैं इबुप्रोफेन लेता हूँ। पुलिस को बुलाएँ।"
        let sourceLocale = Locale(identifier: "en-US")
        let hindiLocale = Locale(identifier: "hi-IN")

        let forward = extractor.compare(
            source: english,
            translation: substitutedHindi,
            sourceLocale: sourceLocale,
            targetLocale: hindiLocale
        )
        let reverse = extractor.compare(
            source: substitutedHindi,
            translation: english,
            sourceLocale: hindiLocale,
            targetLocale: sourceLocale
        )

        XCTAssertTrue(forward.hasMismatch)
        XCTAssertTrue(forward.mismatchedValues.contains {
            $0.kind == .medication && $0.normalizedValue == "INSULIN"
        })
        XCTAssertTrue(forward.mismatchedValues.contains {
            $0.kind == .emergency && $0.normalizedValue == "AMBULANCE"
        })
        XCTAssertTrue(reverse.hasMismatch)
        XCTAssertTrue(reverse.mismatchedValues.contains {
            $0.kind == .medication && $0.normalizedValue == "IBUPROFEN"
        })
        XCTAssertTrue(reverse.mismatchedValues.contains {
            $0.kind == .emergency && $0.normalizedValue == "POLICE"
        })
    }

    func testHindiAndHinglishNegationVariantsPreserveBothDirections() {
        let englishLocale = Locale(identifier: "en-US")
        let hindiLocale = Locale(identifier: "hi-IN")
        let fixtures: [(String, String)] = [
            ("Do not go", "न जाएँ"),
            ("Do not go", "ना जाएँ"),
            ("Do not go", "nahi jaiye"),
            ("Do not go", "nahin jaiye"),
            ("Do not go", "mat jaiye"),
            ("Go without shoes", "bina jute jaiye"),
        ]

        for (english, hindi) in fixtures {
            let forward = extractor.compare(
                source: english,
                translation: hindi,
                sourceLocale: englishLocale,
                targetLocale: hindiLocale
            )
            let reverse = extractor.compare(
                source: hindi,
                translation: english,
                sourceLocale: hindiLocale,
                targetLocale: englishLocale
            )

            XCTAssertFalse(forward.hasMismatch, "Forward negation mismatch for \(hindi): \(forward)")
            XCTAssertFalse(reverse.hasMismatch, "Reverse negation mismatch for \(hindi): \(reverse)")
            XCTAssertTrue(forward.translation.contains {
                $0.kind == .negation && $0.normalizedValue == "NEGATION"
            })
        }
    }

    func testHindiMilkAllergyAliasPreservesDairyInBothDirections() {
        let english = "I am allergic to dairy"
        let hindi = "मुझे दूध से एलर्जी है"
        let englishLocale = Locale(identifier: "en-US")
        let hindiLocale = Locale(identifier: "hi-IN")
        let forward = extractor.compare(
            source: english,
            translation: hindi,
            sourceLocale: englishLocale,
            targetLocale: hindiLocale
        )
        let reverse = extractor.compare(
            source: hindi,
            translation: english,
            sourceLocale: hindiLocale,
            targetLocale: englishLocale
        )

        XCTAssertFalse(forward.hasMismatch, "Forward dairy mismatch: \(forward)")
        XCTAssertFalse(reverse.hasMismatch, "Reverse dairy mismatch: \(reverse)")
        XCTAssertTrue(forward.translation.contains {
            $0.kind == .allergy && $0.normalizedValue == "DAIRY"
        })
    }

    func testHindiAndHinglishBreathingDifficultyPreservesEmergencyInBothDirections() {
        let englishLocale = Locale(identifier: "en-US")
        let hindiLocale = Locale(identifier: "hi-IN")
        let fixtures: [(String, String)] = [
            ("I have difficulty breathing", "मुझे सांस लेने में दिक्कत है"),
            ("I have difficulty breathing", "मुझे साँस लेने में परेशानी है"),
            ("I have difficulty breathing", "mujhe saans lene mein dikkat hai"),
            ("I cannot breathe", "mujhe saans nahi aa rahi hai"),
        ]

        for (english, hindi) in fixtures {
            let forward = extractor.compare(
                source: english,
                translation: hindi,
                sourceLocale: englishLocale,
                targetLocale: hindiLocale
            )
            let reverse = extractor.compare(
                source: hindi,
                translation: english,
                sourceLocale: hindiLocale,
                targetLocale: englishLocale
            )

            XCTAssertFalse(forward.hasMismatch, "Forward breathing mismatch for \(hindi): \(forward)")
            XCTAssertFalse(reverse.hasMismatch, "Reverse breathing mismatch for \(hindi): \(reverse)")
            XCTAssertTrue(forward.translation.contains {
                $0.kind == .emergency && $0.normalizedValue == "BREATHING_DIFFICULTY"
            })
        }
    }

    func testHindiAndHinglishBleedingPreservesEmergencyInBothDirections() {
        let english = "I have severe bleeding"
        let englishLocale = Locale(identifier: "en-US")
        let hindiLocale = Locale(identifier: "hi-IN")
        let fixtures = [
            "मेरा बहुत खून बह रहा है",
            "मेरा खून निकल रहा है",
            "mera bahut khoon bah raha hai",
        ]

        for hindi in fixtures {
            let forward = extractor.compare(
                source: english,
                translation: hindi,
                sourceLocale: englishLocale,
                targetLocale: hindiLocale
            )
            let reverse = extractor.compare(
                source: hindi,
                translation: english,
                sourceLocale: hindiLocale,
                targetLocale: englishLocale
            )

            XCTAssertFalse(forward.hasMismatch, "Forward bleeding mismatch for \(hindi): \(forward)")
            XCTAssertFalse(reverse.hasMismatch, "Reverse bleeding mismatch for \(hindi): \(reverse)")
            XCTAssertTrue(forward.translation.contains {
                $0.kind == .emergency && $0.normalizedValue == "SEVERE_BLEEDING"
            })
        }
    }

    func testHindiBreathingAndBleedingSubstitutionFailsClosed() {
        let forward = extractor.compare(
            source: "I have difficulty breathing",
            translation: "मेरा बहुत खून बह रहा है",
            sourceLocale: Locale(identifier: "en-US"),
            targetLocale: Locale(identifier: "hi-IN")
        )
        let reverse = extractor.compare(
            source: "मेरा बहुत खून बह रहा है",
            translation: "I have difficulty breathing",
            sourceLocale: Locale(identifier: "hi-IN"),
            targetLocale: Locale(identifier: "en-US")
        )

        XCTAssertTrue(forward.hasMismatch)
        XCTAssertTrue(reverse.hasMismatch)
        XCTAssertTrue(forward.mismatchedValues.contains {
            $0.kind == .emergency && $0.normalizedValue == "BREATHING_DIFFICULTY"
        })
        XCTAssertTrue(reverse.mismatchedValues.contains {
            $0.kind == .emergency && $0.normalizedValue == "SEVERE_BLEEDING"
        })
    }

    func testHindiNumbersCurrencyUnitsTimesAndDatesCanonicalizeInBothDirections() {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let utc = TimeZone(secondsFromGMT: 0)!
        let englishLocale = Locale(identifier: "en-US")
        let hindiLocale = Locale(identifier: "hi-IN")
        let fixtures: [(String, String)] = [
            ("Take five", "पाँच लें"),
            ("It costs INR 1,500", "इसकी कीमत ₹१,५०० है"),
            ("Walk 5 km", "५ किलोमीटर चलें"),
            ("Meet at 6:30 PM", "शाम ६:३० बजे मिलें"),
            ("Meet on 08/07/2026", "०७/०८/२०२६ को मिलें"),
        ]

        for (english, hindi) in fixtures {
            let forward = extractor.compare(
                source: english,
                translation: hindi,
                sourceLocale: englishLocale,
                targetLocale: hindiLocale,
                referenceDate: fixed,
                timeZone: utc
            )
            let reverse = extractor.compare(
                source: hindi,
                translation: english,
                sourceLocale: hindiLocale,
                targetLocale: englishLocale,
                referenceDate: fixed,
                timeZone: utc
            )
            XCTAssertFalse(forward.hasMismatch, "Forward mismatch for \(english) / \(hindi): \(forward)")
            XCTAssertFalse(reverse.hasMismatch, "Reverse mismatch for \(hindi) / \(english): \(reverse)")
        }
    }

    func testHindiRelativeDatesAndWeekdaysAreCanonicalWhenUnambiguous() {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let utc = TimeZone(secondsFromGMT: 0)!
        let today = extractor.compare(
            source: "Come today",
            translation: "आज आएँ",
            sourceLocale: Locale(identifier: "en-US"),
            targetLocale: Locale(identifier: "hi-IN"),
            referenceDate: fixed,
            timeZone: utc
        )
        let weekday = extractor.compare(
            source: "Come Friday",
            translation: "शुक्रवार को आएँ",
            sourceLocale: Locale(identifier: "en-US"),
            targetLocale: Locale(identifier: "hi-IN"),
            referenceDate: fixed,
            timeZone: utc
        )

        XCTAssertFalse(today.hasMismatch)
        XCTAssertFalse(weekday.hasMismatch)
    }

    func testNewLanguageProfilesRetainGenericEntityKinds() {
        let fixtures: [(String, String)] = [
            ("fr-FR", "sept, 24 euros, 5 km, 18 h 30, 12 rue Victor Hugo, +33 1 23 45 67 89, 07/08/2026"),
            ("de-DE", "sieben, 24 Euro, 5 Kilometer, 18 Uhr 30, 12 Berliner Straße, +49 30 1234567, 07.08.2026"),
            ("it-IT", "sette, 24 euro, 5 chilometri, 18h30, 12 Via Roma, +39 06 1234567, 07/08/2026"),
            ("pt-BR", "sete, R$ 24, 5 quilômetros, 18h30, 12 Rua Augusta, +55 11 1234 5678, 07/08/2026"),
            ("ko-KR", "일곱, ₩24000, 5킬로미터, 오후 6시 30분, 서울특별시 중구 세종대로 110, +82 2 1234 5678, 2026.08.07")
        ]
        let expectedKinds: Set<CriticalEntityKind> = [.number, .currency, .unit, .time, .date, .address, .phone]

        for (localeIdentifier, text) in fixtures {
            let entities = extractor.extract(from: text, locale: Locale(identifier: localeIdentifier))
            let actualKinds = Set(entities.map(\.kind))
            XCTAssertTrue(
                expectedKinds.isSubset(of: actualKinds),
                "\(localeIdentifier) missed \(expectedKinds.subtracting(actualKinds)); extracted \(entities)"
            )
        }
    }

    func testDifferentWeekdaysDoNotNormalizeToEmpty() {
        let report = extractor.compare(source: "Come Monday", translation: "Ven el martes")
        XCTAssertTrue(report.hasMismatch)
    }

    func testNegationCountAndScopeProxyAreConservative() {
        let report = extractor.compare(source: "Do not cook it without gloves", translation: "No lo cocine")
        XCTAssertTrue(report.hasMismatch)
        XCTAssertTrue(report.missingKinds.contains(.negation))
    }

    func testJapaneseNumeralMatchesArabicNumber() {
        let report = extractor.compare(source: "三", translation: "3")
        XCTAssertFalse(report.hasMismatch)
    }

    func testUnitChangesAreBlocked() {
        let report = extractor.compare(source: "It is 5 km away", translation: "Está a 5 millas")
        XCTAssertTrue(report.hasMismatch)
    }

    func testInventedNumberInTargetIsBlocked() {
        let report = extractor.compare(source: "The station is nearby", translation: "La estación está a 12 kilómetros")
        XCTAssertTrue(report.hasMismatch)
        XCTAssertTrue(report.inventedValues.contains { $0.kind == .unit || $0.kind == .number })
    }

    func testInventedAllergyInTargetIsBlocked() {
        let report = extractor.compare(source: "I would like soup", translation: "Quiero sopa sin lácteos")
        XCTAssertTrue(report.hasMismatch)
        XCTAssertTrue(report.inventedValues.contains { $0.kind == .allergy })
    }

    func testMedicationConceptsAreRecognizedAcrossLanguages() {
        XCTAssertTrue(extractor.extract(from: "I need insulin").contains { $0.kind == .medication && $0.normalizedValue == "INSULIN" })
        XCTAssertTrue(extractor.extract(from: "Necesito insulina").contains { $0.kind == .medication && $0.normalizedValue == "INSULIN" })
        XCTAssertTrue(extractor.extract(from: "インスリンが必要です").contains { $0.kind == .medication && $0.normalizedValue == "INSULIN" })
    }

    func testTravelerMedicationLexiconIsCanonicalAcrossEnglishSpanishAndJapanese() {
        let fixtures: [(String, String, String, String)] = [
            ("aspirin", "aspirina", "アスピリン", "ASPIRIN"),
            ("acetaminophen", "paracetamol", "アセトアミノフェン", "ACETAMINOPHEN"),
            ("ibuprofen", "ibuprofeno", "イブプロフェン", "IBUPROFEN"),
            ("penicillin", "penicilina", "ペニシリン", "PENICILLIN"),
            ("antihistamine", "antihistamínico", "抗ヒスタミン薬", "ANTIHISTAMINE"),
            ("metformin", "metformina", "メトホルミン", "METFORMIN")
        ]

        for (english, spanish, japanese, concept) in fixtures {
            XCTAssertTrue(extractor.extract(from: "I take \(english)").contains { $0.kind == .medication && $0.normalizedValue == concept })
            XCTAssertTrue(extractor.extract(from: "Tomo \(spanish)").contains { $0.kind == .medication && $0.normalizedValue == concept })
            XCTAssertTrue(extractor.extract(from: "\(japanese)を服用しています").contains { $0.kind == .medication && $0.normalizedValue == concept })
        }
    }

    func testPreservedMedicationNameRequiresReviewButHasNoMismatch() {
        let report = extractor.compare(source: "I take aspirin", translation: "Tomo aspirina")

        XCTAssertFalse(report.hasMismatch)
        XCTAssertTrue(report.requiresConfirmation)
    }

    func testMedicationSubstitutionIsBlocked() {
        let report = extractor.compare(source: "I take aspirin", translation: "Tomo ibuprofeno")

        XCTAssertTrue(report.hasMismatch)
        XCTAssertTrue(report.mismatchedValues.contains { $0.kind == .medication && $0.normalizedValue == "ASPIRIN" })
    }

    func testMedicationOmissionIsBlocked() {
        let report = extractor.compare(source: "I take metformin", translation: "Tomo una tableta")

        XCTAssertTrue(report.hasMismatch)
        XCTAssertTrue(report.missingKinds.contains(.medication))
    }

    func testExplicitUnknownMedicineIntentStillForcesCarefulMode() {
        let english = extractor.extract(from: "My medicine called Travexil is in my bag")
        let japanese = extractor.extract(from: "トラベキシルという薬を服用しています")

        XCTAssertTrue(english.contains { $0.kind == .medication && $0.normalizedValue == "NAMED_MEDICATION:TRAVEXIL" })
        XCTAssertTrue(japanese.contains { $0.kind == .medication && $0.normalizedValue == "NAMED_MEDICATION:トラベキシル" })
    }

    func testUnknownNamedMedicationSubstitutionIsBlocked() {
        let report = extractor.compare(
            source: "My medicine called Travexil is in my bag",
            translation: "Mi medicina llamada Zorpex está en mi bolsa"
        )

        XCTAssertTrue(report.hasMismatch)
        XCTAssertTrue(report.requiresConfirmation)
        XCTAssertTrue(report.mismatchedValues.contains {
            $0.kind == .medication && $0.normalizedValue == "NAMED_MEDICATION:TRAVEXIL"
        })
        XCTAssertTrue(report.translation.contains {
            $0.kind == .medication && $0.normalizedValue == "NAMED_MEDICATION:ZORPEX"
        })
    }

    func testPreservedUnknownNamedMedicationHasNoMismatch() {
        let report = extractor.compare(
            source: "My medicine called Travexil is in my bag",
            translation: "Mi medicina llamada TRAVEXIL está en mi bolsa"
        )

        XCTAssertFalse(report.hasMismatch)
        XCTAssertTrue(report.requiresConfirmation)
    }

    func testDifferentNamedMedicinesCannotCollapseThroughAKnownDrugSubstring() {
        let report = extractor.compare(
            source: "My medicine called Aspirinex is in my bag",
            translation: "Mi medicina llamada Aspirinor está en mi bolsa"
        )

        XCTAssertTrue(report.hasMismatch)
        XCTAssertTrue(report.mismatchedValues.contains {
            $0.normalizedValue == "NAMED_MEDICATION:ASPIRINEX"
        })
    }

    func testExplicitKnownMedicationNamesRemainCanonicalAcrossLanguages() {
        let report = extractor.compare(
            source: "My medicine called aspirin is in my bag",
            translation: "Mi medicina llamada aspirina está en mi bolsa"
        )

        XCTAssertFalse(report.hasMismatch)
        XCTAssertTrue(report.source.contains { $0.normalizedValue == "ASPIRIN" })
        XCTAssertTrue(report.translation.contains { $0.normalizedValue == "ASPIRIN" })
    }

    func testHighRiskMedicationNamesAreCanonicalAcrossLanguages() {
        let fixtures: [(String, String, String, String)] = [
            ("warfarin", "warfarina", "ワルファリン", "WARFARIN"),
            ("amoxicillin", "amoxicilina", "アモキシシリン", "AMOXICILLIN"),
            ("apixaban", "apixabán", "アピキサバン", "APIXABAN"),
            ("rivaroxaban", "rivaroxabán", "リバーロキサバン", "RIVAROXABAN")
        ]

        for (english, spanish, japanese, concept) in fixtures {
            XCTAssertTrue(extractor.extract(from: "I take \(english)").contains { $0.kind == .medication && $0.normalizedValue == concept })
            XCTAssertTrue(extractor.extract(from: "Tomo \(spanish)").contains { $0.kind == .medication && $0.normalizedValue == concept })
            XCTAssertTrue(extractor.extract(from: "\(japanese)を服用しています").contains { $0.kind == .medication && $0.normalizedValue == concept })
        }
    }

    func testHighRiskMedicationSubstitutionAndOmissionFailClosed() {
        let substituted = extractor.compare(source: "I take warfarin", translation: "Tomo amoxicilina")
        let omitted = extractor.compare(source: "I take warfarin", translation: "Tomo una tableta")

        XCTAssertTrue(substituted.hasMismatch)
        XCTAssertTrue(substituted.mismatchedValues.contains { $0.normalizedValue == "WARFARIN" })
        XCTAssertTrue(omitted.hasMismatch)
        XCTAssertTrue(omitted.missingKinds.contains(.medication))
    }

    func testExplicitMultiTokenMedicationPreservesFormulationIdentity() {
        let preserved = extractor.compare(
            source: "My medicine called Travexil XR is in my bag",
            translation: "Mi medicamento llamado Travexil XR está en mi bolso"
        )
        let substituted = extractor.compare(
            source: "My medicine called Travexil XR is in my bag",
            translation: "Mi medicamento llamado Travexil XL está en mi bolso"
        )

        XCTAssertFalse(preserved.hasMismatch)
        XCTAssertTrue(preserved.requiresConfirmation)
        XCTAssertTrue(substituted.hasMismatch)
        XCTAssertTrue(substituted.mismatchedValues.contains {
            $0.kind == .medication && $0.normalizedValue == "NAMED_MEDICATION:TRAVEXIL XR"
        })
    }

    func testLowercaseUnknownMedicationNamesCannotCollapseToGenericIntent() {
        let report = extractor.compare(
            source: "My medicine called travexil is in my bag",
            translation: "Mi medicina llamada zorpex está en mi bolsa"
        )

        XCTAssertTrue(report.hasMismatch)
        XCTAssertTrue(report.mismatchedValues.contains {
            $0.kind == .medication && $0.normalizedValue == "NAMED_MEDICATION:TRAVEXIL"
        })
        XCTAssertTrue(report.translation.contains {
            $0.kind == .medication && $0.normalizedValue == "NAMED_MEDICATION:ZORPEX"
        })
    }

    func testSpelledOutReleaseFormulationsRemainDistinct() {
        let report = extractor.compare(
            source: "My medicine called Travexil extended release is in my bag",
            translation: "Mi medicina llamada Travexil immediate release está en mi bolsa"
        )

        XCTAssertTrue(report.hasMismatch)
        XCTAssertTrue(report.mismatchedValues.contains {
            $0.kind == .medication
                && $0.normalizedValue == "NAMED_MEDICATION:TRAVEXIL EXTENDED RELEASE"
        })
    }

    func testExplicitMedicationNameDoesNotAbsorbTrailingProse() throws {
        let medication = extractor.extract(from: "My medicine called Travexil XR helps me while traveling")
            .filter { $0.kind == .medication }

        XCTAssertEqual(medication.count, 1)
        XCTAssertEqual(try XCTUnwrap(medication.first).value, "medicine called Travexil XR")
        XCTAssertEqual(medication.first?.normalizedValue, "NAMED_MEDICATION:TRAVEXIL XR")
    }

    func testArbitraryUncuedProductLikeTextIsNotPretendedToBeMedication() {
        XCTAssertFalse(extractor.extract(from: "Travexil XR is in my bag").contains { $0.kind == .medication })
    }

    func testEmergencyConceptsAreRecognizedAcrossLanguages() {
        XCTAssertTrue(extractor.extract(from: "Call an ambulance").contains { $0.kind == .emergency && $0.normalizedValue == "AMBULANCE" })
        XCTAssertTrue(extractor.extract(from: "Llame a una ambulancia").contains { $0.kind == .emergency && $0.normalizedValue == "AMBULANCE" })
        XCTAssertTrue(extractor.extract(from: "救急車を呼んでください").contains { $0.kind == .emergency && $0.normalizedValue == "AMBULANCE" })
    }

    func testPreservedMedicationStillRequiresConfirmationWithoutMismatch() {
        let report = extractor.compare(source: "I need insulin", translation: "Necesito insulina")

        XCTAssertFalse(report.hasMismatch)
        XCTAssertTrue(report.requiresConfirmation)
    }

    func testEmergencySubstitutionIsBlocked() {
        let report = extractor.compare(source: "Call an ambulance", translation: "Llame a la policía")

        XCTAssertTrue(report.hasMismatch)
        XCTAssertTrue(report.mismatchedValues.contains { $0.kind == .emergency && $0.normalizedValue == "AMBULANCE" })
    }

    func testEntityOverflowFailsClosedAtSharedLimit() {
        let text = Array(repeating: "help", count: ConversationContentPolicy.maximumSafetyEntities + 1).joined(separator: " ")
        let report = extractor.compare(source: text, translation: text)

        XCTAssertEqual(report.source.count, ConversationContentPolicy.maximumSafetyEntities)
        XCTAssertTrue(report.extractionLimitExceeded)
        XCTAssertTrue(report.requiresConfirmation)
    }

    private func assertBilingualSafetyProfile(
        target: String,
        substitutedTarget: String,
        localeIdentifier: String,
        localizedNumericDate: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let source = "My name is Mina. I am not allergic to peanuts. I take insulin. Call an ambulance tomorrow."
        let sourceLocale = Locale(identifier: "en-US")
        let targetLocale = Locale(identifier: localeIdentifier)
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let utc = TimeZone(secondsFromGMT: 0)!
        let requiredKinds: Set<CriticalEntityKind> = [.properName, .negation, .allergy, .medication, .emergency, .date]

        let preserved = extractor.compare(
            source: source,
            translation: target,
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            referenceDate: fixed,
            timeZone: utc
        )
        XCTAssertFalse(preserved.hasMismatch, "\(localeIdentifier): \(preserved)", file: file, line: line)
        XCTAssertTrue(preserved.requiresConfirmation, file: file, line: line)
        XCTAssertTrue(requiredKinds.isSubset(of: Set(preserved.source.map(\.kind))), file: file, line: line)
        XCTAssertTrue(requiredKinds.isSubset(of: Set(preserved.translation.map(\.kind))), file: file, line: line)

        let substituted = extractor.compare(
            source: source,
            translation: substitutedTarget,
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            referenceDate: fixed,
            timeZone: utc
        )
        XCTAssertTrue(substituted.hasMismatch, file: file, line: line)
        XCTAssertTrue(
            substituted.mismatchedValues.contains {
                $0.kind == .medication && $0.normalizedValue == "INSULIN"
            },
            file: file,
            line: line
        )

        let date = extractor.compare(
            source: "Meet me on 08/07/2026.",
            translation: "Rendezvous \(localizedNumericDate).",
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            referenceDate: fixed,
            timeZone: utc
        )
        XCTAssertFalse(date.hasMismatch, "\(localeIdentifier) date mismatch: \(date)", file: file, line: line)
    }
}
