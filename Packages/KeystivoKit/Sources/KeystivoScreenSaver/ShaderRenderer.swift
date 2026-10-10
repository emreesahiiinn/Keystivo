import AppKit
import Metal
import QuartzCore
import SwiftUI

/// Compiles the shader effects once (at runtime, by the Metal driver) and draws
/// them either live into a CAMetalLayer or offscreen into an image.
nonisolated final class ShaderRenderer: @unchecked Sendable {
    static let shared = ShaderRenderer()

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let library: any MTLLibrary
    private var pipelines: [String: any MTLRenderPipelineState] = [:]
    private let lock = NSLock()

    private struct Uniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var seed: Float
    }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let options = MTLCompileOptions()
        options.mathMode = .fast
        guard let library = try? device.makeLibrary(source: ShaderSource.code, options: options) else { return nil }
        self.device = device
        self.queue = queue
        self.library = library
    }

    private func pipeline(_ effect: ShaderEffect, format: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        lock.withLock {
            let key = "\(effect.rawValue)-\(format.rawValue)"
            if let cached = pipelines[key] { return cached }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fx_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: effect.fragmentFunction)
            descriptor.colorAttachments[0].pixelFormat = format
            guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            pipelines[key] = state
            return state
        }
    }

    /// Shader time: wraps daily so it keeps float precision.
    static func shaderTime(_ date: Date) -> Float {
        Float(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86_400))
    }

    private func encode(_ effect: ShaderEffect, into texture: any MTLTexture, time: Float, commandBuffer: any MTLCommandBuffer) {
        guard let pipeline = pipeline(effect, format: texture.pixelFormat) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Uniforms(resolution: SIMD2(Float(texture.width), Float(texture.height)), time: time, seed: 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Draws one frame into the layer's next drawable.
    func render(_ effect: ShaderEffect, into layer: CAMetalLayer, time: Float) {
        guard let drawable = layer.nextDrawable(), let commandBuffer = queue.makeCommandBuffer() else { return }
        encode(effect, into: drawable.texture, time: time, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// A still frame (previews, thumbnails).
    func image(_ effect: ShaderEffect, pixelSize: CGSize, time: Float) -> CGImage? {
        let width = max(1, Int(pixelSize.width)), height = max(1, Int(pixelSize.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let commandBuffer = queue.makeCommandBuffer() else { return nil }
        encode(effect, into: texture, time: time, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&pixels, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Live GPU background: a CAMetalLayer redrawn by the display link (30 fps).
final class ShaderEffectView: NSView {
    var effect: ShaderEffect { didSet { if effect != oldValue { needsLayout = true } } }
    private var displayLink: CADisplayLink?

    init(effect: ShaderEffect) {
        self.effect = effect
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = ShaderRenderer.shared?.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.magnificationFilter = .linear
        return layer
    }

    override func layout() {
        super.layout()
        guard let metal = layer as? CAMetalLayer else { return }
        let scale = (window?.backingScaleFactor ?? 2) * effect.renderScale
        metal.contentsScale = window?.backingScaleFactor ?? 2
        metal.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step() {
        guard let metal = layer as? CAMetalLayer else { return }
        ShaderRenderer.shared?.render(effect, into: metal, time: ShaderRenderer.shaderTime(.now))
    }
}

/// A shader background: live while animating, a still image for previews.
struct ShaderBackground: View {
    let effect: ShaderEffect
    /// nil = live.
    let stillDate: Date?

    var body: some View {
        if let stillDate {
            GeometryReader { proxy in
                let pixels = CGSize(width: proxy.size.width * 2 * effect.renderScale, height: proxy.size.height * 2 * effect.renderScale)
                if let image = ShaderRenderer.shared?.image(effect, pixelSize: pixels, time: ShaderRenderer.shaderTime(stillDate)) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                } else {
                    Color.black
                }
            }
        } else {
            ShaderEffectRepresentable(effect: effect)
        }
    }
}

private struct ShaderEffectRepresentable: NSViewRepresentable {
    let effect: ShaderEffect

    func makeNSView(context: Context) -> ShaderEffectView { ShaderEffectView(effect: effect) }
    func updateNSView(_ view: ShaderEffectView, context: Context) { view.effect = effect }
}
