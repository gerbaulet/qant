import Testing
@testable import Quant

struct HealthEnergySourceClassifierTests {
    @Test("An iPhone product type identifies the phone source")
    func productType() {
        #expect(HealthEnergySourceClassifier.isIPhone(
            productType: "iPhone18,3",
            deviceName: nil,
            deviceModel: nil,
            manufacturer: nil
        ))
    }

    @Test("Apple device metadata can identify the phone source")
    func deviceMetadata() {
        #expect(HealthEnergySourceClassifier.isIPhone(
            productType: nil,
            deviceName: "iPhone von Saskia",
            deviceModel: "iPhone",
            manufacturer: "Apple Inc."
        ))
    }

    @Test("The local iPhone is recognized without descriptive metadata")
    func localDevice() {
        #expect(HealthEnergySourceClassifier.isIPhone(
            productType: nil,
            deviceName: nil,
            deviceModel: nil,
            manufacturer: nil,
            sourceName: "Health",
            sourceBundleIdentifier: "com.apple.Health",
            isLocalDevice: true
        ))
    }

    @Test("A third-party app on the local iPhone is not treated as the phone source")
    func rejectsLocalThirdPartySource() {
        #expect(!HealthEnergySourceClassifier.isIPhone(
            productType: nil,
            deviceName: nil,
            deviceModel: nil,
            manufacturer: nil,
            sourceName: "Energy Importer",
            sourceBundleIdentifier: "com.example.energy",
            isLocalDevice: true
        ))
    }

    @Test("Apple Health source metadata can identify an iPhone without device metadata")
    func appleSourceMetadata() {
        #expect(HealthEnergySourceClassifier.isIPhone(
            productType: nil,
            deviceName: nil,
            deviceModel: nil,
            manufacturer: nil,
            sourceName: "iPhone von Saskia",
            sourceBundleIdentifier: "com.apple.Health"
        ))
    }

    @Test("A third-party source named after an iPhone is not trusted")
    func rejectsThirdPartySourceName() {
        #expect(!HealthEnergySourceClassifier.isIPhone(
            productType: nil,
            deviceName: nil,
            deviceModel: nil,
            manufacturer: nil,
            sourceName: "iPhone bridge",
            sourceBundleIdentifier: "com.example.bridge"
        ))
    }

    @Test("A similarly named third-party device is not trusted")
    func rejectsThirdPartyDevice() {
        #expect(!HealthEnergySourceClassifier.isIPhone(
            productType: nil,
            deviceName: "iPhone-compatible tracker",
            deviceModel: "iPhone bridge",
            manufacturer: "Example Corp"
        ))
    }

    @Test("Apple Watch is not classified as an iPhone")
    func rejectsWatch() {
        #expect(!HealthEnergySourceClassifier.isIPhone(
            productType: "Watch8,1",
            deviceName: "Apple Watch",
            deviceModel: "Watch",
            manufacturer: "Apple Inc.",
            isLocalDevice: true
        ))
    }

    @Test("An Apple Watch product type identifies the Watch source")
    func watchProductType() {
        #expect(HealthEnergySourceClassifier.isAppleWatch(
            productType: "Watch8,1",
            deviceName: nil,
            deviceModel: nil,
            manufacturer: nil,
            sourceName: "Health",
            sourceBundleIdentifier: "com.apple.Health"
        ))
    }

    @Test("A third-party source mentioning Watch is not trusted")
    func rejectsThirdPartyWatchSource() {
        #expect(!HealthEnergySourceClassifier.isAppleWatch(
            productType: nil,
            deviceName: nil,
            deviceModel: nil,
            manufacturer: nil,
            sourceName: "Watch Importer",
            sourceBundleIdentifier: "com.example.watch"
        ))
    }
}
