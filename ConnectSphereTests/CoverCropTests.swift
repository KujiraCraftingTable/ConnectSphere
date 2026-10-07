import CoreGraphics
import Testing
@testable import ConnectSphere

/// A 300 × 200 frame — the 3 : 2 cover shape.
private let frame = CGSize(width: 300, height: 200)

struct CoverCropTests {
    @Test func coverShapeMatchesTheFrameUsedHere() {
        #expect(CoverPhotoView.aspectRatio == frame.width / frame.height)
    }

    @Test func verticalPhotoIsZoomedToFillTheWidth() {
        let image = CGSize(width: 1000, height: 2000)
        let s = CoverCrop.minScale(image: image, frame: frame)
        #expect(image.width * s == frame.width)          // fills the width exactly
        #expect(image.height * s >= frame.height)        // overflows vertically, no bars
    }

    @Test func tinyPhotoIsScaledUpToCoverTheFrame() {
        let image = CGSize(width: 200, height: 100)
        let s = CoverCrop.minScale(image: image, frame: frame)
        #expect(s > 1)
        #expect(image.width * s >= frame.width && image.height * s >= frame.height)
    }

    @Test func dragPastTheEdgeIsClampedBack() {
        let image = CGSize(width: 1000, height: 2000)
        let s = CoverCrop.minScale(image: image, frame: frame)   // 0.3 → 300 × 600
        let o = CoverCrop.clampedOffset(CGSize(width: 50, height: 9_999), scale: s, image: image, frame: frame)
        #expect(o.width == 0)          // no horizontal overhang to move into
        #expect(abs(o.height - 200) < 0.001)   // (600 − 200) / 2
    }

    @Test func centredUnzoomedCropOfAMatchingPhotoIsTheWholePhoto() {
        let image = CGSize(width: 1500, height: 1000)
        let s = CoverCrop.minScale(image: image, frame: frame)
        let r = CoverCrop.cropRect(scale: s, offset: .zero, image: image, frame: frame)
        #expect(abs(r.minX) < 0.001 && abs(r.minY) < 0.001)
        #expect(abs(r.width - 1500) < 0.001 && abs(r.height - 1000) < 0.001)
    }

    @Test func draggingDownRevealsTheTopOfAVerticalPhoto() {
        let image = CGSize(width: 1000, height: 2000)
        let s = CoverCrop.minScale(image: image, frame: frame)
        let r = CoverCrop.cropRect(scale: s, offset: CGSize(width: 0, height: 9_999), image: image, frame: frame)
        #expect(abs(r.minY) < 0.001)                     // pinned to the very top
        #expect(abs(r.width / r.height - CoverPhotoView.aspectRatio) < 0.001)
    }

    @Test func cropNeverLeavesTheImage() {
        let image = CGSize(width: 1200, height: 900)
        for zoom in [1.0, 2.0, 4.0] {
            let s = CoverCrop.minScale(image: image, frame: frame) * zoom
            for dx in [-5_000.0, 0, 5_000] {
                for dy in [-5_000.0, 0, 5_000] {
                    let r = CoverCrop.cropRect(scale: s, offset: CGSize(width: dx, height: dy), image: image, frame: frame)
                    #expect(r.minX >= -0.001 && r.minY >= -0.001)
                    #expect(r.maxX <= image.width + 0.001 && r.maxY <= image.height + 0.001)
                }
            }
        }
    }
}
