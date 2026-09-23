// Renders the YoClicky app icon: a blue cursor triangle on a frosted-glass
// macOS icon squircle.
// Usage: swift design/render-app-icon.swift <output.png>
import AppKit
import CoreGraphics

let canvasSize: CGFloat = 1024
let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: Int(canvasSize), height: Int(canvasSize), bitsPerComponent: 8,
                        bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// 1. Background squircle (macOS icon grid: 824pt tile, 100pt margin), frosted glass
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the tile
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x1A2A44, 0.35))
context.addPath(tilePath)
context.setFillColor(color(0xE9EEF5))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(tilePath)
context.clip()

// Frosted base: bright at the top, cool blue-gray at the bottom
let glassBaseGradient = CGGradient(colorsSpace: colorSpace,
                                   colors: [color(0xFBFDFF), color(0xE4EBF5), color(0xC9D5E6)] as CFArray,
                                   locations: [0, 0.55, 1])!
context.drawLinearGradient(glassBaseGradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Blue light "refracting" through the glass behind the triangle
let refractionGradient = CGGradient(colorsSpace: colorSpace,
                                    colors: [color(0x3380FF, 0.30), color(0x3380FF, 0)] as CFArray,
                                    locations: [0, 1])!
context.drawRadialGradient(refractionGradient, startCenter: CGPoint(x: 500, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 500, y: 470), endRadius: 430, options: [])

// Diagonal specular sheen across the upper-left of the glass
let sheenGradient = CGGradient(colorsSpace: colorSpace,
                               colors: [color(0xFFFFFF, 0.65), color(0xFFFFFF, 0)] as CFArray,
                               locations: [0, 1])!
context.drawLinearGradient(sheenGradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 520, y: 520), options: [])
context.restoreGState()

// Glass rim: bright inner edge, soft darker outer hairline
context.saveGState()
context.addPath(tilePath)
context.setStrokeColor(color(0x8E9BB0, 0.45))
context.setLineWidth(3)
context.strokePath()
let innerRimPath = CGPath(roundedRect: tileRect.insetBy(dx: 5, dy: 5), cornerWidth: 180, cornerHeight: 180, transform: nil)
context.addPath(innerRimPath)
context.setStrokeColor(color(0xFFFFFF, 0.85))
context.setLineWidth(4)
context.strokePath()
context.restoreGState()

// 2. Triangle (same proportions as the on-screen cursor), tilted like a pointer
let triangleSize: CGFloat = 540
let triangleHeight = triangleSize * sqrt(3) / 2
var center = CGPoint(x: 512, y: 512)
let rotation = CGFloat(35) * .pi / 180 // counter-clockwise in CG coords (y up) = points up-left

func rotated(_ point: CGPoint) -> CGPoint {
    let dx = point.x - center.x, dy = point.y - center.y
    return CGPoint(x: center.x + dx * cos(rotation) - dy * sin(rotation),
                   y: center.y + dx * sin(rotation) + dy * cos(rotation))
}

// CG y axis points up, so the "top" vertex has the larger y.
var topVertex = rotated(CGPoint(x: center.x, y: center.y + triangleHeight / 1.5))
var bottomLeftVertex = rotated(CGPoint(x: center.x - triangleSize / 2, y: center.y - triangleHeight / 3))
var bottomRightVertex = rotated(CGPoint(x: center.x + triangleSize / 2, y: center.y - triangleHeight / 3))

// Center the rotated triangle's bounding box on the tile.
let boundingMinX = min(topVertex.x, bottomLeftVertex.x, bottomRightVertex.x)
let boundingMaxX = max(topVertex.x, bottomLeftVertex.x, bottomRightVertex.x)
let boundingMinY = min(topVertex.y, bottomLeftVertex.y, bottomRightVertex.y)
let boundingMaxY = max(topVertex.y, bottomLeftVertex.y, bottomRightVertex.y)
let centeringShift = CGPoint(x: 512 - (boundingMinX + boundingMaxX) / 2, y: 512 - (boundingMinY + boundingMaxY) / 2)
for vertexIndex in 0..<3 {
    var vertex = [topVertex, bottomLeftVertex, bottomRightVertex][vertexIndex]
    vertex.x += centeringShift.x
    vertex.y += centeringShift.y
    if vertexIndex == 0 { topVertex = vertex } else if vertexIndex == 1 { bottomLeftVertex = vertex } else { bottomRightVertex = vertex }
}

let trianglePath = CGMutablePath()
trianglePath.move(to: topVertex)
trianglePath.addLine(to: bottomLeftVertex)
trianglePath.addLine(to: bottomRightVertex)
trianglePath.closeSubpath()

let centroid = CGPoint(x: (topVertex.x + bottomLeftVertex.x + bottomRightVertex.x) / 3,
                       y: (topVertex.y + bottomLeftVertex.y + bottomRightVertex.y) / 3)

// Glow
context.saveGState()
context.setShadow(offset: .zero, blur: 50, color: color(0x1F5FE0, 0.55))
context.addPath(trianglePath)
context.setFillColor(color(0x3380FF))
context.fillPath()
context.restoreGState()

// Body gradient
context.saveGState()
context.addPath(trianglePath)
context.clip()
let bodyGradient = CGGradient(colorsSpace: colorSpace,
                              colors: [color(0x7DB8FF), color(0x3380FF), color(0x1F5FE0)] as CFArray,
                              locations: [0, 0.55, 1])!
context.drawLinearGradient(bodyGradient, start: topVertex,
                           end: CGPoint(x: (bottomLeftVertex.x + bottomRightVertex.x) / 2,
                                        y: (bottomLeftVertex.y + bottomRightVertex.y) / 2), options: [])
// Glass highlight on the upper part
let highlightGradient = CGGradient(colorsSpace: colorSpace,
                                   colors: [color(0xFFFFFF, 0.45), color(0xFFFFFF, 0)] as CFArray,
                                   locations: [0, 1])!
context.drawLinearGradient(highlightGradient, start: topVertex, end: centroid, options: [])
context.restoreGState()

let image = context.makeImage()!
let bitmap = NSBitmapImageRep(cgImage: image)
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
