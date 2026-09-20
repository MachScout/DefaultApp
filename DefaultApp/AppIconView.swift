import AppKit
import SwiftUI

/// AppKit images stay in the UI layer and are cached by installation path.
@MainActor
struct AppIconView: View {
    @State private var icon: NSImage?
    private static let cache = NSCache<NSString, NSImage>()
    let url: URL
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: url) {
            let key = url.standardizedFileURL.path as NSString
            if let cached = Self.cache.object(forKey: key) {
                icon = cached
            } else {
                let loaded = NSWorkspace.shared.icon(forFile: url.path)
                Self.cache.setObject(loaded, forKey: key)
                icon = loaded
            }
        }
    }
}
