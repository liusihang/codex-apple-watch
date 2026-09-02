import Foundation
import ImageIO
import SwiftUI

private let petColumns: CGFloat = 8
private let frameAspect: CGFloat = 192.0 / 208.0

private enum PetSpriteImageCache {
    static let images = NSCache<NSString, CGImage>()

    static func image(for pet: CodexPet, data: Data) -> CGImage? {
        let key = "\(pet.id):\(pet.spriteRevision ?? String(data.count))" as NSString
        if let cached = images.object(forKey: key) {
            return cached
        }
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        images.setObject(image, forKey: key)
        return image
    }
}

struct CodexPetSpriteView: View {
    let pet: CodexPet
    let state: PetVisualState
    var isAnimationEnabled = true
    var spriteData: Data?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frameIndex = 0

    private var animation: PetAnimation {
        PetAnimation.animation(for: state)
    }

    private var activeFrame: PetFrame {
        let frames = animation.frames
        guard !frames.isEmpty else {
            return PetFrame(row: 0, column: 0, duration: 1)
        }
        return frames[min(frameIndex, frames.count - 1)]
    }

    private var spriteImage: Image? {
        if let spriteData, let image = PetSpriteImageCache.image(for: pet, data: spriteData) {
            return Image(decorative: image, scale: 1)
        }
        if let imageName = pet.imageName {
            return Image(imageName)
        }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width, proxy.size.height * frameAspect)
            let height = width / frameAspect
            let frame = activeFrame

            if let spriteImage {
                ZStack(alignment: .topLeading) {
                    spriteImage
                    .resizable()
                    .interpolation(.none)
                    .antialiased(false)
                    .frame(
                        width: width * petColumns,
                        height: height * CGFloat(pet.spriteRows),
                        alignment: .topLeading
                    )
                    .offset(
                        x: -width * CGFloat(frame.column),
                        y: -height * CGFloat(frame.row)
                    )
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .clipped()
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            } else {
                ProgressView()
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .aspectRatio(frameAspect, contentMode: .fit)
        .accessibilityLabel(pet.displayName)
        .task(id: "\(pet.id)-\(state.rawValue)-\(isAnimationEnabled)-\(reduceMotion)") {
            await animate()
        }
    }

    private func animate() async {
        let animation = animation
        let shouldAnimate = isAnimationEnabled && !reduceMotion
        let frames = shouldAnimate ? animation.frames : Array(animation.frames.prefix(1))
        guard !frames.isEmpty else { return }

        var index = 0
        await MainActor.run {
            frameIndex = 0
        }

        if frames.count == 1 {
            return
        }

        while !Task.isCancelled {
            let frame = frames[min(index, frames.count - 1)]
            let delay = UInt64(max(frame.duration, 0.01) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled {
                return
            }

            let next = index + 1
            if next >= frames.count {
                if let loopStartIndex = animation.loopStartIndex, loopStartIndex < frames.count {
                    index = loopStartIndex
                } else {
                    return
                }
            } else {
                index = next
            }

            await MainActor.run {
                frameIndex = index
            }
        }
    }
}

#Preview {
    CodexPetSpriteView(pet: .builtIns[0], state: .running)
        .frame(width: 120, height: 130)
        .background(.black)
}
