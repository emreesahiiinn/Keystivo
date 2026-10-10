import AppKit
import SwiftUI

/// Renders each design's System Settings thumbnail at a classic "10:09" moment.
/// Usage: thumbnails OUTPUT_DIR  →  OUTPUT_DIR/<style>/thumbnail.png, thumbnail@2x.png
@main
struct ThumbnailGenerator {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 10, minute: 9, second: 30))!
        for style in SaverStyle.allCases {
            let folder = output.appending(path: style.rawValue)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (scale, name) in [(1.0, "thumbnail.png"), (2.0, "thumbnail@2x.png")] {
                let renderer = ImageRenderer(content: SaverRootView(style: style, isPreview: true, fixedDate: date)
                    .frame(width: 320, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
                renderer.scale = scale
                guard let image = renderer.cgImage else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: name))
            }
        }
    }
}
