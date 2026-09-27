import AppKit
import MetalKit
import simd

// ---------- Shader source (compiled at runtime) ----------
let shaderSource = """
  #include <metal_stdlib>
  using namespace metal;

  struct VertexIn { float3 position [[attribute(0)]]; };

  struct Uniforms { float4x4 mvp; };

  vertex float4 vertex_main(VertexIn in [[stage_in]],
                            constant Uniforms &u [[buffer(1)]]) {
      return u.mvp * float4(in.position, 1.0);
  }

  fragment float4 fragment_main() {
      return float4(0.55, 0.75, 0.95, 1.0); // light blue
  }
  """

// ---------- Math helpers ----------
func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
  let ys = 1 / tan(fovY * 0.5)
  let xs = ys / aspect
  let zs = far / (near - far)
  return simd_float4x4(
    SIMD4(xs, 0, 0, 0),
    SIMD4(0, ys, 0, 0),
    SIMD4(0, 0, zs, -1),
    SIMD4(0, 0, zs * near, 0)
  )
}

// ---------- Renderer ----------
@MainActor
final class CubeRenderer: NSObject, MTKViewDelegate {
  let device: MTLDevice
  let commandQueue: MTLCommandQueue
  let pipeline: MTLRenderPipelineState
  let depthState: MTLDepthStencilState
  let vertexBuffer: MTLBuffer
  let indexBuffer: MTLBuffer
  var uniforms: MTLBuffer

  // Camera state (orbit camera around origin)
  var yaw: Float = 0.5
  var pitch: Float = 0.4
  var distance: Float = 3.0

  init?(view: MTKView) {
    guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue()
    else { return nil }

    // Compile shaders
    guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
      let vertexFn = library.makeFunction(name: "vertex_main"),
      let fragmentFn = library.makeFunction(name: "fragment_main")
    else {
      fatalError("Shader compilation failed.")
    }

    // Vertex descriptor matching VertexIn
    let vd = MTLVertexDescriptor()
    vd.attributes[0].format = .float3
    vd.attributes[0].offset = 0
    vd.attributes[0].bufferIndex = 0
    vd.layouts[0].stride = MemoryLayout<SIMD3<Float>>.stride

    // Pipeline
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = vertexFn
    desc.fragmentFunction = fragmentFn
    desc.vertexDescriptor = vd
    desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
    desc.depthAttachmentPixelFormat = .depth32Float
    guard let pipe = try? device.makeRenderPipelineState(descriptor: desc) else {
      fatalError("Pipeline creation failed.")
    }

    // Depth stencil state
    let depthDesc = MTLDepthStencilDescriptor()
    depthDesc.depthCompareFunction = .less
    depthDesc.isDepthWriteEnabled = true
    guard let depthState = device.makeDepthStencilState(descriptor: depthDesc) else {
      fatalError("Depth state creation failed.")
    }

    // Cube geometry
    let s: Float = 0.5
    let vertices: [SIMD3<Float>] = [
      // front (z+)
      [-s, -s, s], [s, -s, s], [s, s, s], [-s, s, s],
      // back (z-)
      [-s, -s, -s], [-s, s, -s], [s, s, -s], [s, -s, -s],
      // top (y+)
      [-s, s, -s], [-s, s, s], [s, s, s], [s, s, -s],
      // bottom (y-)
      [-s, -s, -s], [s, -s, -s], [s, -s, s], [-s, -s, s],
      // right (x+)
      [s, -s, -s], [s, s, -s], [s, s, s], [s, -s, s],
      // left (x-)
      [-s, -s, -s], [-s, -s, s], [-s, s, s], [-s, s, -s],
    ]
    let indices: [UInt16] = [
      0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7,
      8, 9, 10, 8, 10, 11, 12, 13, 14, 12, 14, 15,
      16, 17, 18, 16, 18, 19, 20, 21, 22, 20, 22, 23,
    ]

    self.device = device
    self.commandQueue = queue
    self.pipeline = pipe
    self.depthState = depthState
    self.vertexBuffer = device.makeBuffer(
      bytes: vertices, length: MemoryLayout<SIMD3<Float>>.stride * vertices.count)!
    self.indexBuffer = device.makeBuffer(
      bytes: indices, length: MemoryLayout<UInt16>.stride * indices.count)!
    self.uniforms = device.makeBuffer(length: MemoryLayout<simd_float4x4>.stride)!

    view.device = device
    view.depthStencilPixelFormat = .depth32Float
    view.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)  // black
    super.init()
    view.delegate = self
  }

  // Camera controls
  func rotateCamera(dx: Float, dy: Float) {
    yaw += dx * 0.01
    pitch += dy * 0.01
    pitch = max(-1.5, min(1.5, pitch))
  }

  func zoomCamera(delta: Float) {
    distance -= delta * 0.01
    distance = max(0.5, min(20, distance))
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    // Presentation mode.
    yaw += 0.01

    // Camera: orbit around origin
    let model = matrix_identity_float4x4
    let viewMat =
      simd_float4x4(translationZ: -distance)
      * simd_float4x4(rotationX: -pitch)
      * simd_float4x4(rotationY: -yaw)
    let proj = perspective(
      fovY: 65 * .pi / 180,
      aspect: Float(view.drawableSize.width / view.drawableSize.height),
      near: 0.1, far: 100)
    var mvp = proj * viewMat * model
    memcpy(uniforms.contents(), &mvp, MemoryLayout<simd_float4x4>.stride)

    guard let drawable = view.currentDrawable,
      let pass = view.currentRenderPassDescriptor,
      let cmd = commandQueue.makeCommandBuffer(),
      let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
    else { return }

    enc.setRenderPipelineState(pipeline)
    enc.setDepthStencilState(depthState)
    enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    enc.setVertexBuffer(uniforms, offset: 0, index: 1)
    enc.drawIndexedPrimitives(
      type: .triangle, indexCount: 36,
      indexType: .uint16, indexBuffer: indexBuffer,
      indexBufferOffset: 0)
    enc.endEncoding()
    cmd.present(drawable)
    cmd.commit()
  }
}

// ---------- Matrix extensions ----------
extension simd_float4x4 {
  init(rotationX angle: Float) {
    let c = cos(angle)
    let s = sin(angle)
    self = simd_float4x4(
      SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1))
  }
  init(rotationY angle: Float) {
    let c = cos(angle)
    let s = sin(angle)
    self = simd_float4x4(
      SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1))
  }
  init(translationZ z: Float) {
    self = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, z, 1))
  }
}

// ---------- Window (AppKit, minimal) ----------
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(
  contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
  styleMask: [.titled, .closable, .miniaturizable, .resizable],
  backing: .buffered, defer: false)
window.title = "Metal Cube"

let mtkView = MTKView(frame: window.contentView!.bounds, device: nil)
mtkView.autoresizingMask = [.width, .height]
window.contentView = mtkView
window.center()
window.makeKeyAndOrderFront(nil)

guard let renderer = MainActor.assumeIsolated({ CubeRenderer(view: mtkView) }) else {
  fatalError("Metal unavailable.")
}

// ---------- Mouse input: orbit + zoom ----------
var lastMouseLocation: NSPoint?

NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
  event in
  switch event.type {
  case .leftMouseDown:
    lastMouseLocation = NSEvent.mouseLocation
  case .leftMouseDragged:
    let current = NSEvent.mouseLocation
    if let last = lastMouseLocation {
      renderer.rotateCamera(
        dx: -Float(current.x - last.x),
        dy: Float(current.y - last.y))
    }
    lastMouseLocation = current
  case .leftMouseUp:
    lastMouseLocation = nil
  default:
    break
  }
  return event
}

NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
  renderer.zoomCamera(delta: Float(event.scrollingDeltaY))
  return event
}

NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
  if event.modifierFlags.contains(.command) {
    switch event.charactersIgnoringModifiers {
    case "q":
      app.terminate(nil)
    case "c":
      window.center()
    case nil, .some:
      break
    }
  }
  return event
}

// ---------- Extension: menu-action compatible centering ----------
extension NSWindow {
  @objc func centerMenuAction(_ sender: Any?) {
    center()
  }
}

// ---------- Menu bar (needed for Cmd+Q and shortcuts) ----------
let mainMenu = NSMenu()

let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(
  withTitle: "Quit Metal Cube",
  action: #selector(NSApplication.terminate(_:)),
  keyEquivalent: "q")
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)

// Window menu (Cmd+W — close window, standard macOS behavior)
let windowMenuItem = NSMenuItem()
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(
  withTitle: "Close",
  action: #selector(NSWindow.performClose(_:)),
  keyEquivalent: "w")
windowMenu.addItem(
  withTitle: "Center",
  action: #selector(NSWindow.centerMenuAction(_:)),
  keyEquivalent: "c")
windowMenuItem.submenu = windowMenu
mainMenu.addItem(windowMenuItem)

app.activate(ignoringOtherApps: true)
app.mainMenu = mainMenu
app.run()
