import Foundation

/// Display filters never remove entries from the catalog or handler lookups.
public struct ApplicationFilters: Equatable, Sendable {
    public var hideAuxiliary: Bool
    public var hideDevelopment: Bool
    public var hideWithoutAssociations: Bool

    public init(hideAuxiliary: Bool = false, hideDevelopment: Bool = false, hideWithoutAssociations: Bool = false) {
        self.hideAuxiliary = hideAuxiliary
        self.hideDevelopment = hideDevelopment
        self.hideWithoutAssociations = hideWithoutAssociations
    }
}

public struct ApplicationVisibility: Sendable {
    public let auxiliaryReason: String?
    public let developmentReason: String?
    public let hasNoAssociations: Bool

    public init(record: ApplicationRecord) {
        let path = record.url.standardizedFileURL.path
        let lower = path.lowercased()
        let parent = record.url.deletingLastPathComponent().path.lowercased()
        let isEmbeddedUserTool = parent.hasSuffix(".app/contents/applications")
            || parent.hasSuffix(".app/contents/developer/applications")
        func under(_ root: String) -> Bool { lower == root || lower.hasPrefix(root + "/") }
        let auxiliaryRoots = [
            "/system/library/privateframeworks", "/system/library/frameworks",
            "/system/library/input methods", "/library/input methods",
            "/system/library/services", "/library/services",
            "/system/library/image capture", "/system/library/classroom",
            "/system/library/preferencepanes", "/library/developer/privateframeworks",
            "/library/apple/system/library", "/usr/local/libexec", "/usr/libexec",
        ]
        if let root = auxiliaryRoots.first(where: under) {
            auxiliaryReason = "System component: \(root)"
        } else if lower.contains(".app/contents/") && !isEmbeddedUserTool {
            auxiliaryReason = "Helper embedded in another application"
        } else if lower.contains("/library/input methods/") || lower.contains("/library/services/") {
            auxiliaryReason = "Input method or service"
        } else if lower.contains("/launchagents/") || lower.contains("/org.sparkle-project.sparkle/")
                    || lower.contains("/autoupdater/") {
            auxiliaryReason = "Background agent or updater"
        } else if under("/system/library/coreservices")
                    && !under("/system/library/coreservices/applications")
                    && !["finder.app", "archive utility.app", "screen sharing.app", "directory utility.app",
                         "network utility.app", "wireless diagnostics.app", "ticket viewer.app"]
                        .contains(record.url.lastPathComponent.lowercased()) {
            auxiliaryReason = "CoreServices component"
        } else if lower.contains("/system/library/coreservices/") && under("/system/volumes/preboot") {
            auxiliaryReason = "System cryptex component"
        } else if record.url.pathExtension.lowercased() != "app" {
            auxiliaryReason = "Not an application bundle"
        } else {
            auxiliaryReason = nil
        }

        let components = lower.split(separator: "/").map(String.init)
        if under("/tmp") || under("/private/tmp") || under("/var/tmp") || under("/private/var/tmp")
            || under("/var/folders") || under("/private/var/folders") {
            developmentReason = "Temporary directory"
        } else if components.contains("deriveddata") || components.contains("derived-data")
                    || lower.contains("/build/products/") || lower.contains("/build/debug/")
                    || lower.contains("/build/release/") || lower.contains("/.build/") {
            developmentReason = "Development build / DerivedData"
        } else {
            developmentReason = nil
        }
        hasNoAssociations = record.urlSchemes.isEmpty
            && record.documentTypeClaims.allSatisfy {
                $0.contentTypeIdentifiers.isEmpty && $0.filenameExtensions.isEmpty && $0.mimeTypes.isEmpty
            }
            && record.exportedTypeDeclarations.isEmpty && record.importedTypeDeclarations.isEmpty
    }

    public func isVisible(using filters: ApplicationFilters) -> Bool {
        !(filters.hideAuxiliary && auxiliaryReason != nil)
            && !(filters.hideDevelopment && developmentReason != nil)
            && !(filters.hideWithoutAssociations && hasNoAssociations)
    }
}
