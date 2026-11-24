import Foundation

enum HealthEnergySourceClassifier {
    static func isIPhone(
        productType: String?,
        deviceName: String?,
        deviceModel: String?,
        manufacturer: String?,
        sourceName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        isLocalDevice: Bool = false
    ) -> Bool {
        let normalizedProductType = productType?.lowercased()
        let normalizedDeviceName = deviceName?.lowercased()
        let normalizedDeviceModel = deviceModel?.lowercased()
        let normalizedSourceName = sourceName?.lowercased()
        let isAppleSource = sourceBundleIdentifier?.lowercased().hasPrefix("com.apple.") == true

        let identifiesWatch = normalizedProductType?.hasPrefix("watch") == true ||
            normalizedDeviceModel?.contains("watch") == true ||
            normalizedDeviceName?.contains("watch") == true ||
            normalizedSourceName?.contains("watch") == true
        if identifiesWatch {
            return false
        }

        if normalizedProductType?.hasPrefix("iphone") == true ||
            (isLocalDevice && isAppleSource) {
            return true
        }

        let isAppleDevice = manufacturer?.lowercased().contains("apple") == true
        let identifiesIPhone = normalizedDeviceModel?.contains("iphone") == true ||
            normalizedDeviceName?.contains("iphone") == true
        if isAppleDevice && identifiesIPhone {
            return true
        }

        let sourceIdentifiesIPhone = normalizedSourceName?.contains("iphone") == true
        return isAppleSource && sourceIdentifiesIPhone
    }

    static func isAppleWatch(
        productType: String?,
        deviceName: String?,
        deviceModel: String?,
        manufacturer: String?,
        sourceName: String?,
        sourceBundleIdentifier: String?
    ) -> Bool {
        let normalizedProductType = productType?.lowercased()
        if normalizedProductType?.hasPrefix("watch") == true {
            return true
        }

        let isAppleDevice = manufacturer?.lowercased().contains("apple") == true
        let identifiesWatch = deviceModel?.lowercased().contains("watch") == true ||
            deviceName?.lowercased().contains("watch") == true
        if isAppleDevice && identifiesWatch {
            return true
        }

        let isAppleSource = sourceBundleIdentifier?.lowercased().hasPrefix("com.apple.") == true
        let sourceIdentifiesWatch = sourceName?.lowercased().contains("watch") == true
        return isAppleSource && sourceIdentifiesWatch
    }
}
