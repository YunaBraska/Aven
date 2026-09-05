#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
  FileHandle.standardError.write(Data("usage: prepare_app_icon.swift INPUT OUTPUT\n".utf8))
  exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destinationURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
  FileHandle.standardError.write(Data("Could not decode icon source.\n".utf8))
  exit(1)
}

let size = 1_024
let colorSpace = CGColorSpaceCreateDeviceRGB()
var pixels = [UInt8](repeating: 0, count: size * size * 4)
guard
  let context = CGContext(
    data: &pixels,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: size * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )
else {
  FileHandle.standardError.write(Data("Could not create icon canvas.\n".utf8))
  exit(1)
}
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

func isBackground(_ position: Int) -> Bool {
  let offset = position * 4
  let red = Int(pixels[offset])
  let green = Int(pixels[offset + 1])
  let blue = Int(pixels[offset + 2])
  return min(red, green, blue) >= 238 && max(red, green, blue) - min(red, green, blue) <= 14
}

var seen = [Bool](repeating: false, count: size * size)
var queue: [Int] = []
queue.reserveCapacity(size * 8)
for x in 0..<size {
  queue.append(x)
  queue.append((size - 1) * size + x)
}
for y in 1..<(size - 1) {
  queue.append(y * size)
  queue.append(y * size + size - 1)
}
var head = 0
while head < queue.count {
  let position = queue[head]
  head += 1
  guard !seen[position], isBackground(position) else { continue }
  seen[position] = true
  pixels[position * 4 + 3] = 0
  let x = position % size
  let y = position / size
  if x > 0 { queue.append(position - 1) }
  if x + 1 < size { queue.append(position + 1) }
  if y > 0 { queue.append(position - size) }
  if y + 1 < size { queue.append(position + size) }
}

guard let outputImage = context.makeImage(),
  let destination = CGImageDestinationCreateWithURL(
    destinationURL as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
  )
else {
  FileHandle.standardError.write(Data("Could not encode icon.\n".utf8))
  exit(1)
}
CGImageDestinationAddImage(destination, outputImage, nil)
guard CGImageDestinationFinalize(destination) else {
  FileHandle.standardError.write(Data("Could not save icon.\n".utf8))
  exit(1)
}
