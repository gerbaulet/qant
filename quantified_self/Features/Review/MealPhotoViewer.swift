import SwiftUI
import UIKit

enum MealPhotoZoomPolicy {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 5
    static let preferredDoubleTapScale: CGFloat = 3

    static func doubleTapScale(
        currentScale: CGFloat,
        maximumScale: CGFloat
    ) -> CGFloat {
        if currentScale > minimumScale + 0.01 {
            return minimumScale
        }
        return min(preferredDoubleTapScale, maximumScale)
    }
}

struct MealPhotoViewer: View {
    @Environment(\.dismiss) private var dismiss

    let storageKey: String
    let imageStorage: any ImageStorageProviding

    @State private var image: UIImage?
    @State private var didFailToLoad = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let image {
                    ZoomableMealPhoto(image: image)
                        .accessibilityLabel("Mahlzeitenfoto")
                        .accessibilityHint("Zum Vergrößern doppeltippen oder mit zwei Fingern zoomen")
                } else if didFailToLoad {
                    ContentUnavailableView(
                        "Foto nicht verfügbar",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("Die Bilddatei konnte nicht geladen werden.")
                    )
                    .foregroundStyle(.white)
                } else {
                    ProgressView("Foto wird geladen …")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .navigationTitle("Foto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schließen") {
                        dismiss()
                    }
                    .accessibilityIdentifier("meal.closePhotoViewer")
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .accessibilityIdentifier("meal.photoViewer")
        .task(id: storageKey) {
            image = nil
            didFailToLoad = false
            do {
                let data = try await imageStorage.data(forStorageKey: storageKey)
                guard let decodedImage = await Self.decode(data) else {
                    throw ImageStorageError.invalidImage
                }
                guard !Task.isCancelled else { return }
                image = decodedImage
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                didFailToLoad = true
            }
        }
    }

    nonisolated private static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
    }
}

private struct ZoomableMealPhoto: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let scrollView = ZoomingImageScrollView()
        scrollView.configure(image: image)
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomingImageScrollView, context: Context) {
        guard scrollView.displayedImage !== image else { return }
        scrollView.configure(image: image)
    }
}

private final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var previousBoundsSize = CGSize.zero

    var displayedImage: UIImage? {
        imageView.image
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = MealPhotoZoomPolicy.minimumScale
        maximumZoomScale = MealPhotoZoomPolicy.maximumScale
        bouncesZoom = true
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        isAccessibilityElement = true
        accessibilityLabel = "Mahlzeitenfoto"
        accessibilityHint = "Zum Vergrößern doppeltippen oder mit zwei Fingern zoomen"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(image: UIImage) {
        setZoomScale(minimumZoomScale, animated: false)
        imageView.image = image
        previousBoundsSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if previousBoundsSize != bounds.size {
            let preservedScale = zoomScale
            setZoomScale(minimumZoomScale, animated: false)
            imageView.frame = bounds
            previousBoundsSize = bounds.size
            setZoomScale(max(preservedScale, minimumZoomScale), animated: false)
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let targetScale = MealPhotoZoomPolicy.doubleTapScale(
            currentScale: zoomScale,
            maximumScale: maximumZoomScale
        )
        guard targetScale > minimumZoomScale else {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }

        let point = gesture.location(in: imageView)
        let targetSize = CGSize(
            width: bounds.width / targetScale,
            height: bounds.height / targetScale
        )
        zoom(
            to: CGRect(
                x: point.x - targetSize.width / 2,
                y: point.y - targetSize.height / 2,
                width: targetSize.width,
                height: targetSize.height
            ),
            animated: true
        )
    }

    private func centerImage() {
        let horizontalInset = max((bounds.width - contentSize.width) / 2, 0)
        let verticalInset = max((bounds.height - contentSize.height) / 2, 0)
        imageView.center = CGPoint(
            x: contentSize.width / 2 + horizontalInset,
            y: contentSize.height / 2 + verticalInset
        )
    }
}
