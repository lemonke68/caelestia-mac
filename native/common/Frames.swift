// Shared by rice-wallpaper and rice-picker.

import AppKit
import ImageIO

// Decoded image: every gif frame once, as CGImages, plus per-frame delays.
struct Frames {
    let images: [CGImage]
    let delays: [Double]

    /// maxPixel downsamples while decoding (thumbnails); firstOnly stops after frame 0.
    init?(path: String, maxPixel: Int? = nil, firstOnly: Bool = false) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        var images: [CGImage] = []
        var delays: [Double] = []
        let count = firstOnly ? min(1, CGImageSourceGetCount(source)) : CGImageSourceGetCount(source)
        let thumbOptions: CFDictionary? = maxPixel.map {
            [kCGImageSourceCreateThumbnailFromImageAlways: true,
             kCGImageSourceCreateThumbnailWithTransform: true,
             kCGImageSourceThumbnailMaxPixelSize: $0] as CFDictionary
        }
        for i in 0..<count {
            let decoded = thumbOptions.map { CGImageSourceCreateThumbnailAtIndex(source, i, $0) }
                ?? CGImageSourceCreateImageAtIndex(source, i, nil)
            guard let image = decoded else { continue }
            images.append(image)
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            delays.append(delay < 0.02 ? 0.1 : delay)  // browsers treat tiny delays as 100 ms
        }
        if images.isEmpty { return nil }
        self.images = images
        self.delays = delays
    }
}

// Layer-backed view: the GPU scales with aspect-fill, the CPU only swaps frame pointers.
final class FillView: NSView {
    private var frames: Frames?
    private var index = 0
    private var timer: Timer?
    var paused = false { didSet { paused ? stop() : start() } }

    init(frame: NSRect, background: NSColor = .black, gravity: CALayerContentsGravity = .resizeAspectFill) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        layer?.contentsGravity = gravity
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ frames: Frames) {
        self.frames = frames
        index = 0
        // Small pixel-art gifs stay crisp when upscaled; big images get smooth filtering.
        let w = frames.images[0].width
        layer?.magnificationFilter = w < 1000 ? .nearest : .linear
        layer?.minificationFilter = .trilinear
        layer?.contents = frames.images[0]
        start()
    }

    private func start() {
        stop()
        guard !paused, let frames, frames.images.count > 1 else { return }
        schedule(after: frames.delays[index])
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule(after delay: Double) {
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, let frames = self.frames else { return }
            self.index = (self.index + 1) % frames.images.count
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer?.contents = frames.images[self.index]
            CATransaction.commit()
            self.schedule(after: frames.delays[self.index])
        }
        timer?.tolerance = delay * 0.1
    }
}
