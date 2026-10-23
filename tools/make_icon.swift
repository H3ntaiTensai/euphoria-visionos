import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Usage: swift tools/make_icon.swift PICTURE visionOS/Euphoria/Assets.xcassets
//
// Writes the app icon's asset catalog from one square picture of your own; the catalog
// stays out of git, and tools/create_xcode_project.py adds it to the project when present.
//
// The icon is one picture, not a composition — but visionOS will not have a one-picture
// icon: actool rejects a stack with fewer than two layers holding content ("it has 2
// layers, only 1 has applicable content"), and a flat .appiconset for the vision idiom
// compiles to nothing at all. So the art goes on the Back and the Front is an empty
// transparent sheet, which satisfies the rule and still draws the picture undivided.
// Both are filed at 2x of the stack's 512 pt, because the deepest layer holding content
// must fill the stack exactly: 1024 px.
guard CommandLine.arguments.count == 3 else {
    print("Usage: swift tools/make_icon.swift PICTURE visionOS/Euphoria/Assets.xcassets")
    exit(1)
}
let source = CommandLine.arguments[1]
let catalog = URL(fileURLWithPath: CommandLine.arguments[2])
let stack = catalog.appending(path: "AppIcon.solidimagestack")
let side = 1024

let info = #""info" : { "author" : "xcode", "version" : 1 }"#

func file(_ url: URL, _ text: String) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

func layer(_ draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.clear(CGRect(x: 0, y: 0, width: side, height: side))
    draw(context)
    return context.makeImage()!
}

/// One layer of the stack: its folder, its image set, and the picture in it.
func write(_ image: CGImage, layer name: String) {
    let folder = stack.appending(path: "\(name).solidimagestacklayer")
    let imageSet = folder.appending(path: "Content.imageset")
    file(folder.appending(path: "Contents.json"), "{\n  \(info)\n}\n")
    file(imageSet.appending(path: "Contents.json"), """
        {
          "images" : [ { "filename" : "Content.png", "idiom" : "vision", "scale" : "2x" } ],
          \(info)
        }

        """)
    let url = imageSet.appending(path: "Content.png") as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let read = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil)
    ?? { fatalError("cannot read \(source)") }()
guard let art = CGImageSourceCreateImageAtIndex(read, 0, nil) else { fatalError("no image") }

file(catalog.appending(path: "Contents.json"), "{\n  \(info)\n}\n")
file(stack.appending(path: "Contents.json"), """
    {
      \(info),
      "layers" : [ { "filename" : "Front.solidimagestacklayer" }, { "filename" : "Back.solidimagestacklayer" } ]
    }

    """)
write(layer { context in
    context.interpolationQuality = .high
    context.draw(art, in: CGRect(x: 0, y: 0, width: side, height: side))
}, layer: "Back")
write(layer { _ in }, layer: "Front")
print("Icon written to \(stack.path) at \(side)x\(side)")
