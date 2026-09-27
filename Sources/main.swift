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
      return float4(0.55, 0.75, 0.95, 1.0); // light blue (your favorite!)
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

// ---------- App boilerplate ----------
@MainActor
final class CubeRenderer: NSObject, MTKViewDelegate {
  let device: MTLDevice
  let commandQueue: MTLCommandQueue
  let pipeline: MTLRenderPipelineState
  let vertexBuffer: MTLBuffer
  let indexBuffer: MTLBuffer
  var uniforms: MTLBuffer

  var angle: Float = 0

  init?(view: MTKView) {
    guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue()
    else { return nil }

    guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
      let vertexFn = library.makeFunction(name: "vertex_main"),
      let fragmentFn = library.makeFunction(name: "fragment_main")
    else {
      fatalError("Shader compilation failed")
    }

    let vd = MTLVertexDescriptor()
    vd.attributes[0].format = .float3
    vd.attributes[0].offset = 0
    vd.attributes[0].bufferIndex = 0
    vd.layouts[0].stride = MemoryLayout<SIMD3<Float>>.stride

    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = vertexFn
    desc.fragmentFunction = fragmentFn
    desc.vertexDescriptor = vd
    desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
    guard let pipe = try? device.makeRenderPipelineState(descriptor: desc) else {
      fatalError("Pipeline creation failed")
    }

    // Cube geometry (24 verts for face normals later, 36 indices)
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
    self.vertexBuffer = device.makeBuffer(
      bytes: vertices, length: MemoryLayout<SIMD3<Float>>.stride * vertices.count)!
    self.indexBuffer = device.makeBuffer(
      bytes: indices, length: MemoryLayout<UInt16>.stride * indices.count)!
    self.uniforms = device.makeBuffer(length: MemoryLayout<simd_float4x4>.stride)!

    view.device = device
    view.depthStencilPixelFormat = .depth32Float
    view.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1)
    super.init()
    view.delegate = self
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    angle += 0.01

    let model = simd_float4x4(rotationY: angle)
    let viewMat = simd_float4x4(translationZ: -3.0)
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

extension simd_float4x4 {
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
  fatalError("Metal unavailable")
}

app.activate(ignoringOtherApps: true)
app.run()
