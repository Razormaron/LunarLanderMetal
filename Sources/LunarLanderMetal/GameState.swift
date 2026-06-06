import Foundation
import simd

// MARK: - Constants

enum C {
    static let width:  Float = 800
    static let height: Float = 600

    // Physics
    static let gravity:    Float = 0.055   // px / frame²
    static let thrustAcc:  Float = 0.13    // px / frame² (main)
    static let torque:     Float = 0.5     // deg / frame²
    static let maxAngVel:  Float = 1.8     // deg / frame
    static let maxFuel:    Float = 1000
    static let fuelMain:   Float = 1.0     // per frame (main)
    static let fuelSide:   Float = 0.4     // per frame (rotation)

    // Lander local geometry  (origin = lander centre, y+ = down)
    static let bodyW:   Float = 26         // full width
    static let bodyH:   Float = 32         // full height
    static let legOutX: Float = 22         // foot x offset from centre
    static let legBotY: Float = 42         // foot y offset from centre

    // Landing thresholds
    static let maxLandVX:  Float = 20      // px / frame
    static let maxLandVY:  Float = 25      // px / frame
    static let maxLandAng: Float = 15      // degrees

    // Terrain
    static let terrainMinY: Float = 395
    static let terrainMaxY: Float = 545
    static let padWidth:    Float = 96     // primary pad
    static let pad2Width:   Float = 68     // secondary pad
}

// MARK: - Phase

enum Phase { case waiting, flying, landed, crashed }

// MARK: - GameState

final class GameState {

    // Physics state
    var x:      Float = C.width / 2
    var y:      Float = 70
    var vx:     Float = 0
    var vy:     Float = 0
    var angle:  Float = 0       // degrees; +ve = clockwise
    var angVel: Float = 0       // degrees / frame
    var fuel:   Float = C.maxFuel

    // Terrain
    private(set) var terrain: [(x: Float, y: Float)] = []
    private(set) var pad1: (x0: Float, x1: Float, y: Float) = (0, 0, 0)
    private(set) var pad2: (x0: Float, x1: Float, y: Float) = (0, 0, 0)

    // Game state
    private(set) var phase:     Phase = .waiting
    private(set) var score:     Int   = 0   // last landing score
    private(set) var runScore:  Int   = 0   // accumulated this run (streak)
    private(set) var highScore: Int   = UserDefaults.standard.integer(forKey: "highScore")

    // Input — written main thread, read render thread (low-risk)
    var thrustMain  = false
    var thrustLeft  = false
    var thrustRight = false

    // Sound triggers — set for one frame, cleared by Renderer
    var soundLand  = false
    var soundCrash = false

    // Flame length for Renderer (0 = off)
    private(set) var flameLen: Float = 0

    init() { generateTerrain() }

    // MARK: - Public API

    var windowTitle: String {
        let hs = highScore > 0 ? "  Best: \(highScore)" : ""
        switch phase {
        case .waiting:
            return "LUNAR LANDER  ·  SPACE to launch\(hs)"
        case .flying:
            return "LUNAR LANDER  ·  Fuel: \(Int(fuel / C.maxFuel * 100))%  ·  Run: \(runScore)\(hs)"
        case .landed:
            return "LUNAR LANDER  ·  LANDED! +\(score)  Run: \(runScore)\(hs)  ·  SPACE for next"
        case .crashed:
            return "LUNAR LANDER  ·  CRASHED!  Run: \(runScore)\(hs)  ·  SPACE to retry"
        }
    }

    func pressSpace() {
        switch phase {
        case .waiting:
            phase = .flying
        case .landed:
            resetLander(keepRunScore: true)
        case .crashed:
            resetLander(keepRunScore: false)
        default:
            break
        }
    }

    func update() {
        guard phase == .flying else { return }
        applyControls()
        integrate()
        checkCollision()
    }

    // MARK: - Physics

    private func applyControls() {
        if thrustLeft {
            angVel -= C.torque
            fuel    = max(0, fuel - C.fuelSide)
        }
        if thrustRight {
            angVel += C.torque
            fuel    = max(0, fuel - C.fuelSide)
        }
        if !thrustLeft && !thrustRight {
            angVel *= 0.70                         // strong spin damping when no input
            angle  *= 0.97                         // gentle self-righting toward upright
        }
        angVel = angVel.clamped(to: -C.maxAngVel...C.maxAngVel)
        angle += angVel

        if thrustMain && fuel > 0 {
            let a = angle * (.pi / 180)
            vx   += sin(a) * C.thrustAcc
            vy   -= cos(a) * C.thrustAcc       // y+ = down; thrust up → subtract vy
            fuel  = max(0, fuel - C.fuelMain)
            flameLen = Float.random(in: 14...26)
        } else {
            flameLen = 0
        }
    }

    private func integrate() {
        vy += C.gravity
        x  += vx
        y  += vy
        x   = x.clamped(to: 2...C.width - 2)
        if y < 0 { y = 0; vy = abs(vy) * 0.4 }
    }

    // MARK: - Terrain helpers

    /// Interpolated terrain height at world x.
    func terrainY(at xPos: Float) -> Float {
        let pts = terrain
        guard pts.count >= 2 else { return C.height }
        if xPos <= pts.first!.x { return pts.first!.y }
        if xPos >= pts.last!.x  { return pts.last!.y  }
        for i in 0..<(pts.count - 1) where xPos >= pts[i].x && xPos <= pts[i+1].x {
            let t = (xPos - pts[i].x) / (pts[i+1].x - pts[i].x)
            return pts[i].y + t * (pts[i+1].y - pts[i].y)
        }
        return C.height
    }

    /// Both leg-tip world positions.
    func legTips() -> (left: SIMD2<Float>, right: SIMD2<Float>) {
        let a = angle * (.pi / 180)
        let c = cos(a), s = sin(a)
        func w(_ lx: Float, _ ly: Float) -> SIMD2<Float> {
            SIMD2<Float>(x + lx * c - ly * s,
                         y + lx * s + ly * c)
        }
        return (w(-C.legOutX, C.legBotY), w(C.legOutX, C.legBotY))
    }

    // MARK: - Collision / landing

    private func checkCollision() {
        let tips   = legTips()
        let leftTY = terrainY(at: tips.left.x)
        let rightTY = terrainY(at: tips.right.x)

        // Also probe the body's lowest world point to catch high-speed belly landings
        let a = angle * (.pi / 180)
        let c = cos(a), s = sin(a)
        let by = C.bodyH / 2 + 4
        let bodyBot = SIMD2<Float>(x - by * s, y + by * c)
        let bodyHit = bodyBot.y >= terrainY(at: bodyBot.x)

        let leftHit  = tips.left.y  >= leftTY
        let rightHit = tips.right.y >= rightTY

        guard leftHit || rightHit || bodyHit else { return }

        // Determine pad membership for each foot
        let onP1 = tips.left.x  >= pad1.x0 && tips.left.x  <= pad1.x1
                && tips.right.x >= pad1.x0 && tips.right.x <= pad1.x1
        let onP2 = tips.left.x  >= pad2.x0 && tips.left.x  <= pad2.x1
                && tips.right.x >= pad2.x0 && tips.right.x <= pad2.x1

        if (onP1 || onP2) && !bodyHit {
            // Normalise angle to 0…180
            var normAng = abs(angle).truncatingRemainder(dividingBy: 360)
            if normAng > 180 { normAng = 360 - normAng }

            if abs(vx) <= C.maxLandVX
                && vy >= 0 && vy <= C.maxLandVY
                && normAng <= C.maxLandAng {

                // Snap lander so feet sit exactly on pad
                let padY = onP1 ? pad1.y : pad2.y
                let footWorldY = y + 0 * s + C.legBotY * c   // approx for small angles
                y -= footWorldY - padY

                vx = 0; vy = 0; angVel = 0

                let fuelBonus  = Int(fuel / C.maxFuel * 500)
                let speedBonus = max(0, Int((1 - hypot(vx, vy) / (C.maxLandVX + C.maxLandVY)) * 300))
                let angBonus   = max(0, Int((1 - normAng / C.maxLandAng) * 200))
                score     = 1000 + fuelBonus + speedBonus + angBonus
                runScore += score
                if runScore > highScore {
                    highScore = runScore
                    UserDefaults.standard.set(highScore, forKey: "highScore")
                }
                soundLand = true
                phase     = .landed
                return
            }
        }

        // Crash — run ends, check high score
        vx = 0; vy = 0; angVel = 0
        if runScore > highScore {
            highScore = runScore
            UserDefaults.standard.set(highScore, forKey: "highScore")
        }
        runScore   = 0
        soundCrash = true
        phase      = .crashed
    }

    // MARK: - Terrain generation

    private func generateTerrain() {
        let p1x0 = Float.random(in: 55...260)
        let p1y  = Float.random(in: 430...510)
        let p2x0 = Float.random(in: 460...640)
        let p2y  = Float.random(in: 430...510)

        pad1 = (x0: p1x0,  x1: p1x0  + C.padWidth,  y: p1y)
        pad2 = (x0: p2x0,  x1: p2x0  + C.pad2Width, y: p2y)

        // Random terrain checkpoints
        var pts: [(x: Float, y: Float)] = []
        pts.append((x: 0,        y: Float.random(in: 455...500)))
        var cx: Float = Float.random(in: 28...48)
        while cx < C.width - 20 {
            pts.append((x: cx, y: Float.random(in: C.terrainMinY...C.terrainMaxY)))
            cx += Float.random(in: 26...52)
        }
        pts.append((x: C.width,  y: Float.random(in: 455...500)))

        // Inject explicit pad boundary points
        pts += [(pad1.x0, pad1.y), (pad1.x1, pad1.y),
                (pad2.x0, pad2.y), (pad2.x1, pad2.y)]

        pts.sort { $0.x < $1.x }

        // Deduplicate & flatten interior of pads
        var result: [(x: Float, y: Float)] = []
        for pt in pts {
            let inP1 = pt.x >= pad1.x0 && pt.x <= pad1.x1
            let inP2 = pt.x >= pad2.x0 && pt.x <= pad2.x1
            let fy   = inP1 ? pad1.y : (inP2 ? pad2.y : pt.y)
            if let last = result.last, abs(last.x - pt.x) < 2 { continue }
            result.append((x: pt.x, y: fy))
        }
        terrain = result
    }

    private func resetLander(keepRunScore: Bool) {
        x      = C.width / 2 + Float.random(in: -80...80)
        y      = 70
        vx     = Float.random(in: -0.4...0.4)
        vy     = 0
        angle  = 0
        angVel = 0
        fuel   = C.maxFuel
        score  = 0
        flameLen = 0
        if !keepRunScore { runScore = 0 }
        generateTerrain()
        phase  = .waiting
    }
}

// MARK: - Utility

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        max(range.lowerBound, min(self, range.upperBound))
    }
}
