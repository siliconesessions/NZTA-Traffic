import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

private struct IconError: Error, CustomStringConvertible {
    let description: String
}

private func fail(_ message: String) throws -> Never {
    throw IconError(description: message)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    try fail("Usage: swift make_app_icon.swift <input.png> <output.png>")
}

let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let image = NSImage(contentsOf: inputURL),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    try fail("Unable to read input image at \(inputURL.path)")
}

let sourceSize = min(cgImage.width, cgImage.height)
let cropInset = Int(Double(sourceSize) * 0.036)
let cropSize = sourceSize - (cropInset * 2)
let cropX = (cgImage.width - cropSize) / 2
let cropY = (cgImage.height - cropSize) / 2

guard let croppedImage = cgImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropSize, height: cropSize)) else {
    try fail("Unable to crop input image")
}

let outputSize = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

guard let context = CGContext(
    data: nil,
    width: outputSize,
    height: outputSize,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    try fail("Unable to create output image context")
}

let bounds = CGRect(x: 0, y: 0, width: outputSize, height: outputSize)
let cornerRadius = CGFloat(outputSize) * 0.185
let iconPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

context.clear(bounds)
context.addPath(iconPath)
context.clip()
context.interpolationQuality = .high
context.draw(croppedImage, in: bounds)

guard let outputImage = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    try fail("Unable to create PNG destination at \(outputURL.path)")
}

CGImageDestinationAddImage(destination, outputImage, nil)

guard CGImageDestinationFinalize(destination) else {
    try fail("Unable to write PNG at \(outputURL.path)")
}
