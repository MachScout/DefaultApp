import Foundation

public protocol ApplicationReferenceResolving: Sendable {
    func reference(forApplicationAt url: URL) -> ApplicationReference
}

/// Resolves the application identity stored in a bundle at a known filesystem URL.
///
/// Application metadata inspection belongs to DefaultAppCore so clients do not
/// need to know which Foundation representation backs an application record.
public struct BundleApplicationReferenceResolver: ApplicationReferenceResolving {
    private let bundleIdentifierReader: @Sendable (URL) -> String?

    public init(
        bundleIdentifierReader: @escaping @Sendable (URL) -> String? = {
            Bundle(url: $0)?.bundleIdentifier
        }
    ) {
        self.bundleIdentifierReader = bundleIdentifierReader
    }

    public func reference(forApplicationAt url: URL) -> ApplicationReference {
        ApplicationReference(url: url, bundleIdentifier: bundleIdentifierReader(url))
    }
}
