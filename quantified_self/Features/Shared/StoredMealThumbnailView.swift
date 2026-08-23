import SwiftUI
import UIKit

struct StoredMealThumbnailView: View {
    let storageKey: String?
    let size: CGFloat

    @State private var image: UIImage?

    init(storageKey: String?, size: CGFloat = 64) {
        self.storageKey = storageKey
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(.rect(cornerRadius: 12))
                } else {
                    Image(systemName: storageKey == nil ? "fork.knife" : "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: storageKey) {
                image = nil
                guard let storageKey else { return }
                guard let data = try? await FileImageStorage().data(forStorageKey: storageKey) else {
                    return
                }
                image = UIImage(data: data)
            }
            .accessibilityHidden(true)
    }
}
