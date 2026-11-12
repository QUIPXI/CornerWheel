import Foundation
import ImageIO
import CoreGraphics

func pixels(_ path: String) throws -> (Int, Int, [UInt8]) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "CornerWheelImageComparison", code: 1)
    }
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
        guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                      CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else { throw NSError(domain: "CornerWheelImageComparison", code: 2) }
    return (width, height, bytes)
}

let before = try pixels(CommandLine.arguments[1])
let after = try pixels(CommandLine.arguments[2])
var result: [String: Any] = ["before_width": before.0, "before_height": before.1,
                           "after_width": after.0, "after_height": after.1]
if before.0 == after.0, before.1 == after.1 {
    var differentPixels = 0, largestDifference = 0, totalDifference = 0
    for pixel in 0..<(before.0 * before.1) {
        var different = false
        for channel in 0..<4 {
            let index = pixel * 4 + channel
            let delta = abs(Int(before.2[index]) - Int(after.2[index]))
            if delta > 0 { different = true }
            largestDifference = max(largestDifference, delta)
            totalDifference += delta
        }
        if different { differentPixels += 1 }
    }
    result["identical_pixels"] = differentPixels == 0
    result["different_pixels"] = differentPixels
    result["total_pixels"] = before.0 * before.1
    result["largest_channel_difference"] = largestDifference
    result["mean_channel_difference"] = Double(totalDifference) / Double(before.2.count)
} else {
    result["identical_pixels"] = false
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
