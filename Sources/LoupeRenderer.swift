import AppKit
import CoreVideo
import Metal
import QuartzCore

struct LoupeError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

@MainActor
final class LoupeRenderer: NSObject {
    static let panelSide: CGFloat = 248
    static let radius: CGFloat = panelSide * 197 / designSide
    private static let designSide: CGFloat = 448
    private static let samplingMargin: CGFloat = 128

    private struct Pose {
        let angle: CGFloat
        let scale: CGFloat

        static let left = Pose(angle: .pi / 2, scale: 1)
        static let right = Pose(angle: 0, scale: 1)
        static let lifted = Pose(angle: 42 * .pi / 180, scale: 1.1)
    }

    private struct Spring {
        let from: Pose
        let to: Pose
        let start: CFTimeInterval
        let stiffness: Double
        let damping: Double

        func pose(at time: CFTimeInterval) -> Pose? {
            let elapsed = max(0, time - start)
            let decay = damping / 2
            let envelope = exp(-decay * elapsed)
            guard envelope > 0.001 else { return nil }
            let frequency = sqrt(stiffness - decay * decay)
            let phase = frequency * elapsed
            let remaining = envelope * (cos(phase) + decay / frequency * sin(phase))
            return Pose(angle: to.angle + (from.angle - to.angle) * remaining,
                        scale: to.scale + (from.scale - to.scale) * remaining)
        }
    }

    private let package: PreviewLoupePackage
    private weak var view: NSView?
    private let root = CALayer()
    private let scene = CALayer()
    private let background = CALayer()
    private let output = CAMetalLayer()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let lightGlass: CALayer?
    private let darkGlass: CALayer?
    private var compositor: CARenderer?
    private var sceneTexture: MTLTexture?
    private var pixelBuffer: CVPixelBuffer?
    private var inFlightBuffer: CVPixelBuffer?
    private var displayFrame = CGRect.zero
    private var center = CGPoint.zero
    private var scale: CGFloat = 0
    private var scheduled = false
    private var needsFrame = false
    private var restPose = Pose.right
    private var pose = Pose.right
    private var spring: Spring?
    private var displayLink: CADisplayLink?

    init(packageURL: URL, view: NSView) throws {
        package = try PreviewLoupePackage(url: packageURL)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw LoupeError("当前会话无法使用 Metal GPU。")
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: Self.compositeShader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "loupeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "loupeFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let loupe = package.rootLayer
        lightGlass = Self.findLayer(in: loupe, named: "Light Mode")
        darkGlass = Self.findLayer(in: loupe, named: "Dark Mode")
        self.view = view
        super.init()
        root.masksToBounds = true
        let fullSide = Self.designSide + 2 * Self.samplingMargin
        scene.bounds = CGRect(x: 0, y: 0, width: fullSide, height: fullSide)
        root.addSublayer(scene)
        background.contentsGravity = .resize
        background.magnificationFilter = .linear
        scene.addSublayer(background)
        // The CAML centers the outside disk at (187, 196) in a 400-point canvas.
        loupe.anchorPoint = CGPoint(x: 187 / loupe.bounds.width, y: 196 / loupe.bounds.height)
        loupe.position = CGPoint(x: fullSide / 2, y: fullSide / 2)
        scene.addSublayer(loupe)

        output.device = device
        output.pixelFormat = .bgra8Unorm
        output.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        output.isOpaque = false
        output.isHidden = true
        view.layer = output
        view.wantsLayer = true
    }

    private static func findLayer(in layer: CALayer, named name: String) -> CALayer? {
        if layer.name == name { return layer }
        for child in layer.sublayers ?? [] {
            if let match = findLayer(in: child, named: name) { return match }
        }
        return nil
    }

    func move(to center: CGPoint, scale: CGFloat) {
        guard self.center != center || self.scale != scale else { return }
        self.center = center
        self.scale = scale
        requestFrame()
    }

    func update(_ buffer: CVPixelBuffer, displayFrame: CGRect) {
        guard CVPixelBufferGetIOSurface(buffer) != nil else { return }
        pixelBuffer = buffer
        self.displayFrame = displayFrame
        requestFrame()
    }

    func setDarkAppearance(_ dark: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lightGlass?.isHidden = dark
        darkGlass?.isHidden = !dark
        CATransaction.commit()
        requestFrame()
    }

    func pickUp() {
        animate(to: .lifted, stiffness: 240, damping: 20, animated: true)
    }

    func putDown(onLeft: Bool, animated: Bool) {
        restPose = onLeft ? .left : .right
        animate(to: restPose, stiffness: 93, damping: 15, animated: animated)
    }

    private func animate(to target: Pose, stiffness: Double, damping: Double, animated: Bool) {
        let now = CACurrentMediaTime()
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let view {
            pose = spring?.pose(at: now) ?? pose
            spring = Spring(from: pose, to: target, start: now, stiffness: stiffness, damping: damping)
            if displayLink == nil {
                let link = view.displayLink(target: self, selector: #selector(advanceMotion(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            endMotion(at: target)
        }
        requestFrame()
    }

    @objc private func advanceMotion(_ link: CADisplayLink) {
        guard let spring else { return }
        if let next = spring.pose(at: CACurrentMediaTime()) {
            pose = next
        } else {
            endMotion(at: spring.to)
        }
        requestFrame()
    }

    private func endMotion(at target: Pose) {
        pose = target
        spring = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    func reset() {
        endMotion(at: restPose)
        output.isHidden = true
        background.contents = nil
        pixelBuffer = nil
        needsFrame = false
    }

    private func requestFrame() {
        guard pixelBuffer != nil, scale > 0 else { return }
        needsFrame = true
        guard !scheduled, inFlightBuffer == nil else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.drawIfNeeded() }
    }

    private func configureCompositor(panelPixels: Int) {
        let pixelsPerUnit = CGFloat(panelPixels) / Self.designSide
        let side = Int(ceil(scene.bounds.width * pixelsPerUnit))
        guard sceneTexture?.width != side || compositor == nil else { return }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let colorSpace = output.colorspace else { return }
        sceneTexture = texture
        let renderer = CARenderer(mtlTexture: texture, options: [
            kCARendererMetalCommandQueue: queue,
            kCARendererColorSpace: colorSpace
        ])
        root.frame = CGRect(x: 0, y: 0, width: side, height: side)
        scene.position = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        scene.setAffineTransform(CGAffineTransform(scaleX: pixelsPerUnit, y: pixelsPerUnit))
        renderer.bounds = root.bounds
        renderer.layer = root
        compositor = renderer
    }

    private func drawIfNeeded() {
        scheduled = false
        guard needsFrame, let pixelBuffer, inFlightBuffer == nil else { return }
        needsFrame = false

        let panelPixels = (Self.panelSide * scale).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        output.contentsScale = scale
        output.drawableSize = CGSize(width: panelPixels, height: panelPixels)
        CATransaction.commit()

        guard let drawable = output.nextDrawable(),
              let commands = renderFrame(to: drawable.texture, from: pixelBuffer) else { return }
        // Keep the capture buffer alive until the GPU has consumed its IOSurface.
        inFlightBuffer = pixelBuffer
        commands.addCompletedHandler { [self] _ in
            DispatchQueue.main.async {
                self.inFlightBuffer = nil
                if self.needsFrame { self.requestFrame() }
            }
        }
        output.isHidden = false
        commands.present(drawable)
        commands.commit()
    }

    func renderFrame(to target: MTLTexture, from buffer: CVPixelBuffer) -> MTLCommandBuffer? {
        guard let surface = CVPixelBufferGetIOSurface(buffer) else { return nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        configureCompositor(panelPixels: target.width)
        let unitsPerPoint = Self.designSide / Self.panelSide
        let halfSide = scene.bounds.width / 2
        background.bounds = CGRect(x: 0, y: 0, width: displayFrame.width * unitsPerPoint,
                                   height: displayFrame.height * unitsPerPoint)
        background.position = CGPoint(x: halfSide + (displayFrame.midX - center.x) * unitsPerPoint,
                                      y: halfSide + (displayFrame.midY - center.y) * unitsPerPoint)
        background.contents = surface.takeUnretainedValue()
        let transform = CGAffineTransform(rotationAngle: pose.angle).scaledBy(x: pose.scale, y: pose.scale)
        package.rootLayer.setAffineTransform(transform)
        CATransaction.commit()
        guard let compositor, let sceneTexture else { return nil }

        CATransaction.flush()
        compositor.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        compositor.addUpdate(compositor.bounds)
        compositor.render()
        compositor.endFrame()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var shape = SIMD3<Float>(Float(target.width) / Float(sceneTexture.width),
                                 Float(Self.radius / Self.panelSide * pose.scale), Float(target.width))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(sceneTexture, index: 0)
        encoder.setFragmentBytes(&shape, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return commands
    }

    // The offscreen scene includes a margin for refraction. Crop to the panel
    // and make everything outside the glass transparent in the final pass.
    private static let compositeShader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex loupeVertex(uint id [[vertex_id]]) {
            float2 position = float2(id == 1 ? 3.0 : -1.0, id == 2 ? 3.0 : -1.0);
            return { float4(position, 0.0, 1.0), position * 0.5 + 0.5 };
        }
        fragment half4 loupeFragment(Vertex in [[stage_in]],
                                     texture2d<half> scene [[texture(0)]],
                                     constant float3 &shape [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float2 delta = in.uv - 0.5;
            half coverage = half(smoothstep(-0.5, 0.5, (shape.y - length(delta)) * shape.z));
            return scene.sample(s, 0.5 + delta * shape.x) * coverage;
        }
        """
}
