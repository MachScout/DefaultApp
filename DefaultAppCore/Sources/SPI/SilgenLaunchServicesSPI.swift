import CoreServices
import Foundation

@_silgen_name("_LSCopyAllApplicationURLs")
private func silgenCopyAllApplicationURLs(
    _ applications: UnsafeMutablePointer<Unmanaged<CFArray>?>
) -> OSStatus

@_silgen_name("_LSCopySchemesAndHandlerURLs")
private func silgenCopySchemesAndHandlerURLs(
    _ schemes: UnsafeMutablePointer<Unmanaged<CFArray>?>,
    _ handlerURLs: UnsafeMutablePointer<Unmanaged<CFArray>?>
) -> OSStatus

@_silgen_name("_UTCopyDeclaredTypeIdentifiers")
private func silgenCopyDeclaredTypeIdentifiers() -> Unmanaged<CFArray>?

public protocol PrivateLaunchServicesProviding: Sendable {
    func applicationURLs() throws -> [URL]
    func schemesAndHandlerURLs() throws -> [(scheme: String, handlerURL: URL)]
    func declaredTypeIdentifiers() throws -> [String]
}

public struct SilgenLaunchServicesSPI: PrivateLaunchServicesProviding {
    public static let expectedSymbolNames = [
        "_LSCopyAllApplicationURLs", "_LSCopySchemesAndHandlerURLs", "_UTCopyDeclaredTypeIdentifiers", "_LSDisplayData"
    ]

    public init() {}

    public func applicationURLs() throws -> [URL] {
        var output: Unmanaged<CFArray>?
        let status = silgenCopyAllApplicationURLs(&output)
        // Copy ownership applies to every non-nil result, including error paths.
        let retained = output?.takeRetainedValue()
        try Self.checkStatus(status, symbol: Self.expectedSymbolNames[0])
        return try Self.applicationURLs(from: Self.array(retained, symbol: Self.expectedSymbolNames[0]), status: status)
    }

    public func schemesAndHandlerURLs() throws -> [(scheme: String, handlerURL: URL)] {
        var schemeOutput: Unmanaged<CFArray>?
        var handlerOutput: Unmanaged<CFArray>?
        let status = silgenCopySchemesAndHandlerURLs(&schemeOutput, &handlerOutput)
        // Adopt both arrays before any validation can throw, so neither leaks.
        let schemes = schemeOutput?.takeRetainedValue()
        let handlers = handlerOutput?.takeRetainedValue()
        let symbol = Self.expectedSymbolNames[1]
        try Self.checkStatus(status, symbol: symbol)
        return try Self.schemePairs(
            schemes: Self.array(schemes, symbol: symbol),
            handlerURLs: Self.array(handlers, symbol: symbol),
            status: status
        )
    }

    public func declaredTypeIdentifiers() throws -> [String] {
        let retained = silgenCopyDeclaredTypeIdentifiers()?.takeRetainedValue()
        return try Self.typeIdentifiers(from: Self.array(retained, symbol: Self.expectedSymbolNames[2]))
    }

    private static func array(_ value: CFArray?, symbol: String) throws -> NSArray? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else {
            throw DefaultAppError.malformedSPIPayload(symbol: symbol)
        }
        return value as NSArray
    }

    // Managed payload decoders also let unit tests exercise validation without calling system SPI.
    static func applicationURLs(from payload: NSArray?, status: Int32) throws -> [URL] {
        let symbol = expectedSymbolNames[0]
        try checkStatus(status, symbol: symbol)
        guard let payload else { throw DefaultAppError.malformedSPIPayload(symbol: symbol) }
        return try payload.map { try fileURL($0, symbol: symbol) }
    }

    static func schemePairs(schemes: NSArray?, handlerURLs: NSArray?, status: Int32) throws -> [(scheme: String, handlerURL: URL)] {
        let symbol = expectedSymbolNames[1]
        try checkStatus(status, symbol: symbol)
        guard let schemes, let handlerURLs, schemes.count == handlerURLs.count else {
            throw DefaultAppError.malformedSPIPayload(symbol: symbol)
        }
        return try (0..<schemes.count).map { index in
            let string = try string(schemes[index], symbol: symbol)
            // LaunchServices includes a wildcard registration alongside concrete schemes.
            if string == "*" { return (string, try fileURL(handlerURLs[index], symbol: symbol)) }
            guard let association = try? Association.urlScheme(string) else {
                throw DefaultAppError.malformedSPIPayload(symbol: symbol)
            }
            return (association.identifier, try fileURL(handlerURLs[index], symbol: symbol))
        }
    }

    static func typeIdentifiers(from payload: NSArray?) throws -> [String] {
        let symbol = expectedSymbolNames[2]
        guard let payload else { throw DefaultAppError.malformedSPIPayload(symbol: symbol) }
        return try payload.map { element in
            let string = try string(element, symbol: symbol)
            guard let association = try? Association.contentType(string) else {
                throw DefaultAppError.malformedSPIPayload(symbol: symbol)
            }
            return association.identifier
        }
    }

    private static func checkStatus(_ status: Int32, symbol: String) throws {
        guard status == noErr else { throw DefaultAppError.privateSPIFailure(symbol: symbol, status: status) }
    }

    private static func string(_ value: Any, symbol: String) throws -> String {
        guard CFGetTypeID(value as CFTypeRef) == CFStringGetTypeID(), let string = value as? String else {
            throw DefaultAppError.malformedSPIPayload(symbol: symbol)
        }
        return string
    }

    private static func fileURL(_ value: Any, symbol: String) throws -> URL {
        guard CFGetTypeID(value as CFTypeRef) == CFURLGetTypeID(), let url = value as? URL, url.isFileURL else {
            throw DefaultAppError.malformedSPIPayload(symbol: symbol)
        }
        return url.standardizedFileURL
    }
}
