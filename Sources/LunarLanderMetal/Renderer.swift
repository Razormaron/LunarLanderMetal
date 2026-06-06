import Metal
import MetalKit
import simd

// MARK: - Vertex

struct Vertex {
    var position: SIMD2<Float>
    var color:    SIMD4<Float>
}

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {

    let device:       MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline:     MTLRenderPipelineState

    weak var gameState: GameState?
    var onTitleChange: ((String) -> Void)?
    private var lastTitle = ""
    private let audio = AudioManager()

    private let vertexBuffer: MTLBuffer
    private let stars: [(x: Float, y: Float, b: Float)]  // x, y, brightness

    // 7-segment patterns [A B C D E F G]
    private static let segPatterns: [[Bool]] = [
        [true,  true,  true,  true,  true,  true,  false], // 0
        [false, true,  true,  false, false, false, false],  // 1
        [true,  true,  false, true,  true,  false, true],   // 2
        [true,  true,  true,  true,  false, false, true],   // 3
        [false, true,  true,  false, false, true,  true],   // 4
        [true,  false, true,  true,  false, true,  true],   // 5
        [true,  false, true,  true,  true,  true,  true],   // 6
        [true,  true,  true,  false, false, false, false],  // 7
        [true,  true,  true,  true,  true,  true,  true],   // 8
        [true,  true,  true,  true,  false, true,  true],   // 9
    ]

    private let dW:  Float = 20   // digit width
    private let dH:  Float = 32   // digit height
    private let dG:  Float = 3    // digit gap
    private let dSW: Float = 4    // segment stroke width

    // MARK: Init

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device       = device
        self.commandQueue = device.makeCommandQueue()!

        let library = try device.makeLibrary(source: metalShaderSource, options: nil)
        let vertFn  = library.makeFunction(name: "vertex_main")!
        let fragFn  = library.makeFunction(name: "fragment_main")!

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format      = .float2
        vd.attributes[0].offset      = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format      = .float4
        vd.attributes[1].offset      = MemoryLayout<Vertex>.offset(of: \.color)!
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride         = MemoryLayout<Vertex>.stride

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction                  = vertFn
        pd.fragmentFunction                = fragFn
        pd.colorAttachments[0].pixelFormat = pixelFormat
        pd.vertexDescriptor                = vd

        self.pipeline = try device.makeRenderPipelineState(descriptor: pd)
        self.vertexBuffer = device.makeBuffer(
            length: 3000 * MemoryLayout<Vertex>.stride,
            options: .storageModeShared)!

        // Pre-generate stars (random fixed positions in the sky region)
        var s: [(x: Float, y: Float, b: Float)] = []
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<70 {
            s.append((Float.random(in: 0...C.width,  using: &rng),
                      Float.random(in: 0...C.terrainMinY - 30, using: &rng),
                      Float.random(in: 0.4...1.0,    using: &rng)))
        }
        self.stars = s

        super.init()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let gs = gameState else { return }

        gs.update()

        if gs.soundLand  { audio.playLand();  gs.soundLand  = false }
        if gs.soundCrash { audio.playCrash(); gs.soundCrash = false }

        let title = gs.windowTitle
        if title != lastTitle {
            lastTitle = title
            let cb = onTitleChange
            DispatchQueue.main.async { cb?(title) }
        }

        var verts = UnsafeMutableBufferPointer<Vertex>(
            start: vertexBuffer.contents().assumingMemoryBound(to: Vertex.self),
            count: 3000)
        var n = 0
        buildGeometry(gs, into: &verts, n: &n)

        guard n > 0,
              let rpd    = view.currentRenderPassDescriptor,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc    = cmdBuf.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: n)
        enc.endEncoding()

        if let drawable = view.currentDrawable { cmdBuf.present(drawable) }
        cmdBuf.commit()
    }

    // MARK: - Geometry builder

    private func buildGeometry(_ gs: GameState,
                                into v: inout UnsafeMutableBufferPointer<Vertex>,
                                n: inout Int) {
        // Stars
        for star in stars {
            let b = star.b
            addRect(&v, &n, x: star.x, y: star.y, w: 2, h: 2,
                    c: SIMD4<Float>(b, b, b, 1))
        }

        // Terrain fill
        let pts = gs.terrain
        let moonGray = SIMD4<Float>(0.20, 0.20, 0.23, 1)
        let rimColor = SIMD4<Float>(0.50, 0.52, 0.58, 1)
        for i in 0..<(pts.count - 1) {
            let x0 = pts[i].x,   y0 = pts[i].y
            let x1 = pts[i+1].x, y1 = pts[i+1].y
            let bot = C.height + 2
            let p00 = ndcP(x0, y0);  let p10 = ndcP(x1, y1)
            let p01 = ndcP(x0, bot); let p11 = ndcP(x1, bot)
            v[n] = Vertex(position: p00, color: moonGray); n += 1
            v[n] = Vertex(position: p10, color: moonGray); n += 1
            v[n] = Vertex(position: p01, color: moonGray); n += 1
            v[n] = Vertex(position: p10, color: moonGray); n += 1
            v[n] = Vertex(position: p11, color: moonGray); n += 1
            v[n] = Vertex(position: p01, color: moonGray); n += 1
        }
        // Terrain rim highlight
        for i in 0..<(pts.count - 1) {
            let segW = pts[i+1].x - pts[i].x
            addRect(&v, &n, x: pts[i].x, y: pts[i].y, w: segW, h: 2, c: rimColor)
        }

        // Landing pads
        let padYellow = SIMD4<Float>(1.0, 0.88, 0.0, 1)
        let padDim    = SIMD4<Float>(0.6, 0.52, 0.0, 1)
        for pad in [gs.pad1, gs.pad2] {
            let pw = pad.x1 - pad.x0
            addRect(&v, &n, x: pad.x0, y: pad.y, w: pw, h: 4, c: padYellow)
            // Edge poles
            addRect(&v, &n, x: pad.x0 - 2, y: pad.y - 14, w: 4, h: 16, c: padDim)
            addRect(&v, &n, x: pad.x1 - 2, y: pad.y - 14, w: 4, h: 16, c: padDim)
            // Pole tips
            addRect(&v, &n, x: pad.x0 - 3, y: pad.y - 18, w: 6, h: 6, c: padYellow)
            addRect(&v, &n, x: pad.x1 - 3, y: pad.y - 18, w: 6, h: 6, c: padYellow)
        }

        // Lander
        drawLander(&v, &n, gs: gs)

        // HUD
        drawHUD(&v, &n, gs: gs)
    }

    // MARK: - Lander rendering

    private func drawLander(_ v: inout UnsafeMutableBufferPointer<Vertex>,
                            _ n: inout Int, gs: GameState) {
        let lx = gs.x, ly = gs.y
        let a  = gs.angle * (.pi / 180)

        let silver   = SIMD4<Float>(0.88, 0.88, 0.95, 1)
        let darkGray = SIMD4<Float>(0.45, 0.45, 0.50, 1)
        let gold     = SIMD4<Float>(0.90, 0.70, 0.20, 1)
        let flameO   = SIMD4<Float>(1.00, 0.45, 0.05, 1)
        let flameY   = SIMD4<Float>(1.00, 1.00, 0.30, 1)
        let thrustC  = SIMD4<Float>(0.50, 0.80, 1.00, 1)

        // Descent stage (lower body)
        rotRect(&v, &n, lx: lx, ly: ly, rx: 0, ry: 4, w: C.bodyW, h: C.bodyH - 8,
                angle: a, c: darkGray)
        // Ascent stage (upper body — narrower)
        rotRect(&v, &n, lx: lx, ly: ly, rx: 0, ry: -(C.bodyH / 2 - 4), w: C.bodyW - 8, h: 16,
                angle: a, c: silver)
        // Window
        rotRect(&v, &n, lx: lx, ly: ly, rx: 0, ry: -(C.bodyH / 2 - 5), w: 8, h: 7,
                angle: a, c: SIMD4<Float>(0.4, 0.7, 1.0, 1))
        // Engine bell
        rotRect(&v, &n, lx: lx, ly: ly, rx: 0, ry: C.bodyH / 2 + 5, w: 10, h: 9,
                angle: a, c: darkGray)

        // Legs — each leg goes from body-bottom corner to foot tip
        // Left leg: start = (-bodyW/2, bodyH/2) → end = (-legOutX, legBotY)
        let legStartX = C.bodyW / 2           // 13
        let legStartY = C.bodyH / 2           // 16
        let legDX     = C.legOutX - legStartX // 9
        let legDY     = C.legBotY - legStartY // 26
        let legLen    = hypot(legDX, legDY)
        let legAng    = atan2(legDY, legDX)   // ~70.8°
        let legMidX   = (legStartX + C.legOutX) / 2  // 17.5
        let legMidY   = (legStartY + C.legBotY) / 2  // 29

        // Left leg (mirror: negate x offsets)
        rotRect(&v, &n, lx: lx, ly: ly, rx: -legMidX, ry: legMidY,
                w: legLen, h: 3, angle: a - legAng, c: silver)
        // Right leg
        rotRect(&v, &n, lx: lx, ly: ly, rx:  legMidX, ry: legMidY,
                w: legLen, h: 3, angle: a + legAng, c: silver)

        // Horizontal foot-pads
        rotRect(&v, &n, lx: lx, ly: ly, rx: -C.legOutX, ry: C.legBotY,
                w: 16, h: 3, angle: a, c: gold)
        rotRect(&v, &n, lx: lx, ly: ly, rx:  C.legOutX, ry: C.legBotY,
                w: 16, h: 3, angle: a, c: gold)

        // Main-engine flame
        if gs.flameLen > 0 {
            let fl  = gs.flameLen
            let fCY = C.bodyH / 2 + 5 + 4.5 + fl / 2  // below engine bell centre
            rotRect(&v, &n, lx: lx, ly: ly, rx: 0, ry: fCY,
                    w: 7, h: fl, angle: a, c: flameO)
            rotRect(&v, &n, lx: lx, ly: ly, rx: 0, ry: fCY + fl * 0.25,
                    w: 3.5, h: fl * 0.5, angle: a, c: flameY)
        }

        // Side-thruster puffs (fire opposite side to turn direction)
        if gs.thrustLeft {
            rotRect(&v, &n, lx: lx, ly: ly, rx: C.bodyW / 2 + 5, ry: -C.bodyH / 4,
                    w: 9, h: 4, angle: a, c: thrustC)
        }
        if gs.thrustRight {
            rotRect(&v, &n, lx: lx, ly: ly, rx: -(C.bodyW / 2 + 5), ry: -C.bodyH / 4,
                    w: 9, h: 4, angle: a, c: thrustC)
        }
    }

    // MARK: - HUD

    private func drawHUD(_ v: inout UnsafeMutableBufferPointer<Vertex>,
                         _ n: inout Int, gs: GameState) {
        let hudC  = SIMD4<Float>(0.65, 0.88, 1.00, 1)
        let greenC = SIMD4<Float>(0.20, 0.95, 0.20, 1)
        let redC   = SIMD4<Float>(0.95, 0.20, 0.20, 1)
        let warnC  = SIMD4<Float>(1.00, 0.60, 0.00, 1)

        // ── Fuel bar (left side) ───────────────────────────────────────────────
        let bx: Float = 16, by: Float = 80
        let bw: Float = 14, bh: Float = 190
        let frac = gs.fuel / C.maxFuel
        let fillC = frac > 0.30 ? greenC : (frac > 0.12 ? warnC : redC)

        // Background trough
        addRect(&v, &n, x: bx, y: by, w: bw, h: bh,
                c: SIMD4<Float>(0.10, 0.10, 0.12, 1))
        // Fill level (grows from bottom)
        let fillH = bh * frac
        addRect(&v, &n, x: bx, y: by + bh - fillH, w: bw, h: fillH, c: fillC)
        // Border
        let bc = SIMD4<Float>(0.50, 0.50, 0.55, 1)
        addRect(&v, &n, x: bx - 1,      y: by - 1,      w: bw + 2, h: 1,   c: bc)
        addRect(&v, &n, x: bx - 1,      y: by + bh,     w: bw + 2, h: 1,   c: bc)
        addRect(&v, &n, x: bx - 1,      y: by,          w: 1,      h: bh,  c: bc)
        addRect(&v, &n, x: bx + bw,     y: by,          w: 1,      h: bh,  c: bc)
        // "F" label below bar
        addRect(&v, &n, x: bx, y: by + bh + 6,  w: bw, h: 3,  c: hudC)   // top of F
        addRect(&v, &n, x: bx, y: by + bh + 6,  w: 3,  h: 22, c: hudC)   // spine
        addRect(&v, &n, x: bx, y: by + bh + 16, w: 10, h: 3,  c: hudC)   // middle bar

        // ── Velocity readout (top right) ───────────────────────────────────────
        let rx: Float = C.width - 130
        let ry: Float = 18

        // Horizontal speed label "H"
        addRect(&v, &n, x: rx,     y: ry,     w: 3,  h: 14, c: hudC)
        addRect(&v, &n, x: rx + 7, y: ry,     w: 3,  h: 14, c: hudC)
        addRect(&v, &n, x: rx,     y: ry + 5, w: 10, h: 3,  c: hudC)
        // Minus sign if moving left
        let vxSign: Float = gs.vx < 0 ? -1 : 1
        let vxSignColor = vxSign < 0 ? redC : greenC
        if gs.vx < 0 { addRect(&v, &n, x: rx + 15, y: ry + 5, w: 7, h: 3, c: vxSignColor) }
        addNumber(&v, &n, value: Int(abs(gs.vx)), x: rx + 24, y: ry, c: hudC)

        // Vertical speed label "V"
        let vry = ry + 36
        addRect(&v, &n, x: rx,     y: vry,     w: 3,  h: 14, c: hudC)
        addRect(&v, &n, x: rx + 7, y: vry,     w: 3,  h: 14, c: hudC)
        addRect(&v, &n, x: rx + 1, y: vry + 9, w: 8,  h: 5,  c: hudC)
        // Down arrow or up indicator based on vy sign
        let vyColor = gs.vy > C.maxLandVY ? redC : greenC
        if gs.vy < 0 { addRect(&v, &n, x: rx + 15, y: vry + 5, w: 7, h: 3, c: vyColor) }
        addNumber(&v, &n, value: Int(abs(gs.vy)), x: rx + 24, y: vry, c: vyColor)

        // ── Score on landing ───────────────────────────────────────────────────
        if gs.phase == .landed {
            addNumber(&v, &n, value: gs.score,
                      x: C.width / 2 - 50, y: 20,
                      c: SIMD4<Float>(0.25, 1.00, 0.25, 1))
        }
    }

    // MARK: - Digit rendering (7-segment)

    private func addNumber(_ v: inout UnsafeMutableBufferPointer<Vertex>, _ n: inout Int,
                           value: Int, x: Float, y: Float, c: SIMD4<Float>) {
        let s = max(0, min(value, 9999))
        if s >= 1000 { addDigit(&v, &n, d: s / 1000,       x: x,              y: y, c: c) }
        if s >= 100  { addDigit(&v, &n, d: (s / 100) % 10, x: x + (dW + dG),  y: y, c: c) }
        if s >= 10   { addDigit(&v, &n, d: (s / 10) % 10,  x: x + (dW + dG) * (s >= 100 ? 2 : 1), y: y, c: c) }
        addDigit(&v, &n, d: s % 10,
                 x: x + (dW + dG) * Float(s >= 1000 ? 3 : s >= 100 ? 2 : s >= 10 ? 1 : 0),
                 y: y, c: c)
    }

    private func addDigit(_ v: inout UnsafeMutableBufferPointer<Vertex>, _ n: inout Int,
                          d: Int, x: Float, y: Float, c: SIMD4<Float>) {
        guard d >= 0 && d < Renderer.segPatterns.count else { return }
        let seg = Renderer.segPatterns[d]
        let w = dW, h = dH, sw = dSW
        let mid = (h / 2).rounded()

        if seg[0] { addRect(&v, &n, x: x,          y: y,              w: w,  h: sw,       c: c) } // A top
        if seg[1] { addRect(&v, &n, x: x + w - sw, y: y,              w: sw, h: mid,      c: c) } // B top-right
        if seg[2] { addRect(&v, &n, x: x + w - sw, y: y + mid,        w: sw, h: h - mid,  c: c) } // C bot-right
        if seg[3] { addRect(&v, &n, x: x,          y: y + h - sw,     w: w,  h: sw,       c: c) } // D bottom
        if seg[4] { addRect(&v, &n, x: x,          y: y + mid,        w: sw, h: h - mid,  c: c) } // E bot-left
        if seg[5] { addRect(&v, &n, x: x,          y: y,              w: sw, h: mid,      c: c) } // F top-left
        if seg[6] { addRect(&v, &n, x: x,          y: y + mid - sw/2, w: w,  h: sw,       c: c) } // G middle
    }

    // MARK: - Primitive helpers

    /// Axis-aligned rect (game coords → NDC).
    private func addRect(_ v: inout UnsafeMutableBufferPointer<Vertex>, _ n: inout Int,
                         x: Float, y: Float, w: Float, h: Float, c: SIMD4<Float>) {
        let (x0, y0) = ndc(x,     y    )
        let (x1, y1) = ndc(x + w, y + h)
        v[n] = Vertex(position: [x0, y0], color: c); n += 1  // TL
        v[n] = Vertex(position: [x1, y0], color: c); n += 1  // TR
        v[n] = Vertex(position: [x0, y1], color: c); n += 1  // BL
        v[n] = Vertex(position: [x1, y0], color: c); n += 1  // TR
        v[n] = Vertex(position: [x1, y1], color: c); n += 1  // BR
        v[n] = Vertex(position: [x0, y1], color: c); n += 1  // BL
    }

    /// Rotated rect: centre at (lx + rx_rotated, ly + ry_rotated), rotated by `angle` radians.
    /// rx/ry are the rect-centre offsets in lander-local coords.
    private func rotRect(_ v: inout UnsafeMutableBufferPointer<Vertex>, _ n: inout Int,
                         lx: Float, ly: Float,
                         rx: Float, ry: Float,
                         w: Float, h: Float,
                         angle: Float,
                         c: SIMD4<Float>) {
        let ca = cos(angle), sa = sin(angle)
        let hw = w / 2, hh = h / 2

        // 4 corners in local rect space, then rotate + translate to world
        func wp(_ clx: Float, _ cly: Float) -> (Float, Float) {
            let loclX = rx + clx
            let loclY = ry + cly
            return (lx + loclX * ca - loclY * sa,
                    ly + loclX * sa + loclY * ca)
        }

        let (ax, ay) = wp(-hw, -hh)   // TL
        let (bx, by) = wp( hw, -hh)   // TR
        let (cx2, cy2) = wp( hw,  hh) // BR
        let (dx, dy) = wp(-hw,  hh)   // BL

        let p0 = ndcVec(ax, ay)
        let p1 = ndcVec(bx, by)
        let p2 = ndcVec(cx2, cy2)
        let p3 = ndcVec(dx, dy)

        v[n] = Vertex(position: p0, color: c); n += 1
        v[n] = Vertex(position: p1, color: c); n += 1
        v[n] = Vertex(position: p3, color: c); n += 1
        v[n] = Vertex(position: p1, color: c); n += 1
        v[n] = Vertex(position: p2, color: c); n += 1
        v[n] = Vertex(position: p3, color: c); n += 1
    }

    /// Game coords → Metal NDC (tuple form).
    @inline(__always)
    private func ndc(_ gx: Float, _ gy: Float) -> (Float, Float) {
        ((gx / C.width) * 2 - 1,  1 - (gy / C.height) * 2)
    }

    /// Game coords → Metal NDC (SIMD2 form).
    @inline(__always)
    private func ndcVec(_ gx: Float, _ gy: Float) -> SIMD2<Float> {
        let (x, y) = ndc(gx, gy)
        return SIMD2<Float>(x, y)
    }

    /// Game coords → Metal NDC (SIMD2 form, from point).
    @inline(__always)
    private func ndcP(_ gx: Float, _ gy: Float) -> SIMD2<Float> {
        SIMD2<Float>((gx / C.width) * 2 - 1,  1 - (gy / C.height) * 2)
    }
}
