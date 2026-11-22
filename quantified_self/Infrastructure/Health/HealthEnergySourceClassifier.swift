import Foundation

enum HealthEnergySourceClassifier {
    static func isIPhone(
        productType: String?,
        deviceName: String?,
        deviceModel: String?,
        manufacturer: String?,
        sourceName: String? = nil,
        sourceBundleIdentifier: String? = nil
    ) -> Bool {
        if productType?.lowercased().hasPrefix("iphone") == true {
            return true
        }

        let isAppleDevice = manufacturer?.lowercased().contains("apple") == true
        let identifiesIPhone = deviceModel?.lowercased().contains("iphone") == true ||
            deviceName?.lowercased().contains("iphone") == true
        if isAppleDevice && identifiesIPhone {
            return true
        }

        let isAppleSource = sourceBundleIdentifier?.lowercased().hasPrefix("com.apple.") == true
        let sourceIdentifiesIPhone = sourceName?.lowercased().contains("iphone") == true
        return isAppleSource && sourceIdentifiesIPhone
    }
}
