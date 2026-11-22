import Foundation

enum HealthEnergySourceClassifier {
    static func isIPhone(
        productType: String?,
        deviceName: String?,
        deviceModel: String?,
        manufacturer: String?
    ) -> Bool {
        if productType?.lowercased().hasPrefix("iphone") == true {
            return true
        }

        let isAppleDevice = manufacturer?.lowercased().contains("apple") == true
        let identifiesIPhone = deviceModel?.lowercased().contains("iphone") == true ||
            deviceName?.lowercased().contains("iphone") == true
        return isAppleDevice && identifiesIPhone
    }
}
