import CoreGraphics

enum TodayEnergyChartLayout {
    static let compactHeight: CGFloat = 210
    static let maximumHeight: CGFloat = 300
    static let compactWidth: CGFloat = 340

    static func height(for width: CGFloat) -> CGFloat {
        guard width.isFinite, width > compactWidth else { return compactHeight }
        let proportionalHeight = compactHeight * width / compactWidth
        return min(proportionalHeight, maximumHeight)
    }
}
