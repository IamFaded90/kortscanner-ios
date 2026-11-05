import SwiftUI
import UIKit

struct ZoomPhotoView: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                ZoomScrollView(data: data)
                Text("Knib med to fingre for at zoome. Dobbelttryk for at nulstille.").font(.footnote).foregroundStyle(.secondary).padding()
                Button("Luk") { dismiss() }.buttonStyle(BigButtonStyle(filled: false)).padding()
            }.navigationTitle("Se detaljerne").navigationBarTitleDisplayMode(.inline)
        }
    }
}
struct ZoomScrollView: UIViewRepresentable {
    let data: Data
    final class PhotoScroll: UIScrollView, UIScrollViewDelegate {
        let imageView = UIImageView()
        private var laidOut = false
        override init(frame: CGRect) {
            super.init(frame: frame)
            minimumZoomScale = 1; maximumZoomScale = 8
            delegate = self
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
            let tap = UITapGestureRecognizer(target: self, action: #selector(reset))
            tap.numberOfTapsRequired = 2
            addGestureRecognizer(tap)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) er ikke understøttet") }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard !laidOut, bounds.width > 0, bounds.height > 0 else { return }
            imageView.frame = bounds
            contentSize = bounds.size
            laidOut = true
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc private func reset() { setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled) }
    }
    func makeUIView(context: Context) -> PhotoScroll {
        let view = PhotoScroll()
        view.imageView.image = UIImage(data: data)
        return view
    }
    func updateUIView(_ view: PhotoScroll, context: Context) {}
}

struct ConditionInspector: View {
    let front: Data
    let back: Data?
    @Environment(\.dismiss) private var dismiss
    @State private var side = 0
    @State private var zoomData: Data?
    @State private var showZoom = false
    private var image: UIImage? { UIImage(data: side == 1 ? back ?? front : front) }
    private let regions: [(String, CGRect)] = [
        ("Øverst til venstre", CGRect(x: 0, y: 0, width: 0.26, height: 0.20)),
        ("Øverst til højre", CGRect(x: 0.74, y: 0, width: 0.26, height: 0.20)),
        ("Nederst til venstre", CGRect(x: 0, y: 0.80, width: 0.26, height: 0.20)),
        ("Nederst til højre", CGRect(x: 0.74, y: 0.80, width: 0.26, height: 0.20)),
        ("Venstre kant", CGRect(x: 0, y: 0.2, width: 0.12, height: 0.6)),
        ("Højre kant", CGRect(x: 0.88, y: 0.2, width: 0.12, height: 0.6)),
        ("Øverste kant", CGRect(x: 0.2, y: 0, width: 0.6, height: 0.12)),
        ("Nederste kant", CGRect(x: 0.2, y: 0.88, width: 0.6, height: 0.12))
    ]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Du vurderer standen").font(.title2.bold())
                    Text("Se efter slid, hvide kanter, ridser og bøjninger. Appen gætter ikke på stand eller graderingskarakter.").foregroundStyle(.secondary)
                    Picker("Side", selection: $side) {
                        Text("Forside").tag(0)
                        if back != nil { Text("Bagside").tag(1) }
                    }.pickerStyle(.segmented).frame(minHeight: 56)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                            if let crop = crop(region.1) {
                                Button {
                                    zoomData = crop.jpegData(compressionQuality: 1)
                                    showZoom = true
                                } label: {
                                    VStack {
                                        Image(uiImage: crop).resizable().scaledToFit().frame(height: 150)
                                        Text(region.0).font(.caption.bold()).foregroundStyle(.primary)
                                    }.padding(12).frame(minHeight: 190).glassPanel()
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Button("Luk stand-tjek") { dismiss() }.buttonStyle(BigButtonStyle())
                }.padding(20)
            }.background(Theme.bg).navigationTitle("Kanter og hjørner").navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showZoom) { if let zoomData { ZoomPhotoView(data: zoomData) } }
        }
    }
    private func crop(_ normalized: CGRect) -> UIImage? {
        guard let cg = image?.cgImage else { return nil }
        let rect = CGRect(x: normalized.minX * CGFloat(cg.width), y: normalized.minY * CGFloat(cg.height),
                          width: normalized.width * CGFloat(cg.width), height: normalized.height * CGFloat(cg.height))
        return cg.cropping(to: rect).map { UIImage(cgImage: $0) }
    }
}
