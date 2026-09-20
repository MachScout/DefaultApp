import Foundation
import DefaultAppCore

public struct CLIUsageError: Error, Equatable, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct CLIParser: Sendable {
    public init() {}

    public func parse(_ arguments: [String]) throws -> CLICommand {
        if arguments.isEmpty || arguments == ["help"] || arguments == ["--help"] || arguments == ["-h"] {
            return .help
        }

        let parsed = try parseTokens(arguments)
        guard let name = parsed.positionals.first else {
            throw CLIUsageError("Missing command.")
        }
        let operands = Array(parsed.positionals.dropFirst())

        switch name {
        case "apps":
            try parsed.require(operands: operands, count: 0, allowing: [.json])
            return .apps(json: parsed.json)
        case "app":
            try parsed.require(operands: operands, count: 1, allowing: [.json])
            return .app(app: operands[0], json: parsed.json)
        case "schemes":
            try parsed.require(operands: operands, count: 0, allowing: [.json])
            return .schemes(json: parsed.json)
        case "types":
            try parsed.require(operands: operands, count: 0, allowing: [.json])
            return .types(json: parsed.json)
        case "handlers", "get":
            try parsed.require(operands: operands, count: 2, allowing: [.json, .backend, .role])
            let selection = try associationSelection(operands: operands, parsed: parsed)
            if name == "handlers" {
                return .handlers(
                    kind: selection.kind,
                    identifier: selection.identifier,
                    backend: selection.backend,
                    role: selection.role,
                    json: parsed.json
                )
            }
            return .get(
                kind: selection.kind,
                identifier: selection.identifier,
                backend: selection.backend,
                role: selection.role,
                json: parsed.json
            )
        case "set":
            try parsed.require(operands: operands, count: 2, allowing: [.app, .backend, .role])
            guard let application = parsed.app, !application.isEmpty else {
                throw CLIUsageError("set requires --app <bundle-id-or-path>.")
            }
            let selection = try associationSelection(operands: operands, parsed: parsed)
            return .set(
                kind: selection.kind,
                identifier: selection.identifier,
                app: application,
                backend: selection.backend,
                role: selection.role
            )
        case "doctor":
            try parsed.require(operands: operands, count: 0, allowing: [.json])
            return .doctor(json: parsed.json)
        default:
            throw CLIUsageError("Unknown command: \(name)")
        }
    }

    private func associationSelection(operands: [String], parsed: ParsedArguments) throws -> AssociationSelection {
        guard let kind = CLIAssociationKind(rawValue: operands[0]) else {
            throw CLIUsageError("Association kind must be scheme or uti.")
        }
        guard !operands[1].isEmpty else {
            throw CLIUsageError("Association identifier must not be empty.")
        }
        let association = try kind.association(identifier: operands[1])

        let backend = try parsed.backend.map(parseBackend) ?? .modern
        let role = try parsed.role.map(parseRole) ?? .all
        if kind == .scheme, role != .all {
            throw CLIUsageError("URL schemes do not support handler roles.")
        }
        if backend == .modern, role != .all {
            throw CLIUsageError("The modern backend does not support handler roles.")
        }

        return AssociationSelection(kind: kind, identifier: association.identifier, backend: backend, role: role)
    }

    private func parseBackend(_ value: String) throws -> Backend {
        guard let backend = Backend(rawValue: value) else {
            throw CLIUsageError("Backend must be modern or legacy.")
        }
        return backend
    }

    private func parseRole(_ value: String) throws -> HandlerRole {
        switch value {
        case "all": .all
        case "viewer": .viewer
        case "editor": .editor
        case "shell": .shell
        default: throw CLIUsageError("Role must be all, viewer, editor, or shell.")
        }
    }

    private func parseTokens(_ arguments: [String]) throws -> ParsedArguments {
        var parsed = ParsedArguments()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                try parsed.setFlag(.json)
            case "--backend", "--role", "--app":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
                    throw CLIUsageError("Missing value for \(argument).")
                }
                index += 1
                try parsed.setValue(option: argument, value: arguments[index])
            default:
                if argument.hasPrefix("-") {
                    throw CLIUsageError("Unknown option: \(argument)")
                }
                parsed.positionals.append(argument)
            }
            index += 1
        }
        return parsed
    }
}

private struct AssociationSelection {
    let kind: CLIAssociationKind
    let identifier: String
    let backend: Backend
    let role: HandlerRole
}

private enum CLIOption: String, Hashable {
    case json = "--json"
    case backend = "--backend"
    case role = "--role"
    case app = "--app"
}

private struct ParsedArguments {
    var positionals: [String] = []
    var json = false
    var backend: String?
    var role: String?
    var app: String?
    private var supplied: Set<CLIOption> = []

    mutating func setFlag(_ option: CLIOption) throws {
        try markSupplied(option)
        json = true
    }

    mutating func setValue(option rawOption: String, value: String) throws {
        guard let option = CLIOption(rawValue: rawOption) else {
            throw CLIUsageError("Unknown option: \(rawOption)")
        }
        try markSupplied(option)
        switch option {
        case .backend: backend = value
        case .role: role = value
        case .app: app = value
        case .json: json = true
        }
    }

    func require(operands: [String], count: Int, allowing allowed: Set<CLIOption>) throws {
        guard operands.count == count else {
            throw CLIUsageError("Expected \(count) argument\(count == 1 ? "" : "s"), received \(operands.count).")
        }
        if let option = supplied.first(where: { !allowed.contains($0) }) {
            throw CLIUsageError("\(option.rawValue) is not valid for this command.")
        }
    }

    private mutating func markSupplied(_ option: CLIOption) throws {
        guard supplied.insert(option).inserted else {
            throw CLIUsageError("Duplicate option: \(option.rawValue)")
        }
    }
}
