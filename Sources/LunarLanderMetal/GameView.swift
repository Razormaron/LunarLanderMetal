import AppKit
import Metal
import MetalKit

// MTKView subclass — owns GameState and routes keyboard input.
final class GameView: MTKView {

    let gameState = GameState()
    private(set) var renderer: Renderer!
    private var keyDownMonitor: Any?
    private var keyUpMonitor:   Any?

    required init(coder: NSCoder) { fatalError("use init(frame:device:)") }

    init(frame: NSRect, device: MTLDevice) {
        super.init(frame: frame, device: device)

        colorPixelFormat         = .bgra8Unorm
        clearColor               = MTLClearColor(red: 0.01, green: 0.01, blue: 0.04, alpha: 1)
        preferredFramesPerSecond = 60
        isPaused                 = false
        enableSetNeedsDisplay    = false
        layer?.isOpaque          = true

        do {
            renderer = try Renderer(device: device, pixelFormat: colorPixelFormat)
        } catch {
            fatalError("Renderer init failed: \(error)")
        }
        renderer.gameState = gameState
        renderer.onTitleChange = { [weak self] title in
            self?.window?.title = title
        }
        self.delegate = renderer

        // Store the tokens — without this the monitors are immediately deallocated
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event)
            return event
        }
    }

    // MARK: - Key handling

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
        return true
    }

    // Clicking the view re-grabs keyboard focus
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        handleKeyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        handleKeyUp(event)
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        switch event.keyCode {
        case 126, 13:  gameState.thrustMain  = true
        case 123,  0:  gameState.thrustLeft  = true
        case 124,  2:  gameState.thrustRight = true
        case 49:       gameState.pressSpace()
        default:       break
        }
    }

    private func handleKeyUp(_ event: NSEvent) {
        switch event.keyCode {
        case 126, 13:  gameState.thrustMain  = false
        case 123,  0:  gameState.thrustLeft  = false
        case 124,  2:  gameState.thrustRight = false
        default:       break
        }
    }
}
