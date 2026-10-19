import Foundation
import CoreFoundation

struct AppCapabilities: Equatable, Sendable {
    static let allDisabled = AppCapabilities(
        onlineFeaturesEnabled: false,
        faceToFaceEnabled: false
    )
    static let allEnabled = AppCapabilities(
        onlineFeaturesEnabled: true,
        faceToFaceEnabled: true
    )

    let onlineFeaturesEnabled: Bool
    let faceToFaceEnabled: Bool

    init(onlineFeaturesEnabled: Bool, faceToFaceEnabled: Bool) {
        self.onlineFeaturesEnabled = onlineFeaturesEnabled
        self.faceToFaceEnabled = faceToFaceEnabled
    }

    init(bundle: Bundle = .main) {
        self.init(
            onlineFeaturesEnabled: Self.flag(named: "ONLINE_FEATURES_ENABLED", in: bundle),
            faceToFaceEnabled: Self.flag(named: "FACE_TO_FACE_ENABLED", in: bundle)
        )
    }

    private static func flag(named name: String, in bundle: Bundle) -> Bool {
        guard let value = bundle.object(forInfoDictionaryKey: name) else { return false }
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        guard let string = value as? String else { return false }

        return switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true", "1": true
        case "no", "false", "0": false
        default: false
        }
    }
}
