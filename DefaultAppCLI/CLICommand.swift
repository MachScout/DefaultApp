import DefaultAppCore

public enum CLIAssociationKind: String, Codable, Equatable, Sendable {
    case scheme
    case uti

    func association(identifier: String) throws -> Association {
        switch self {
        case .scheme:
            try .urlScheme(identifier)
        case .uti:
            try .contentType(identifier)
        }
    }
}

public enum CLICommand: Equatable, Sendable {
    case help
    case apps(json: Bool)
    case app(app: String, json: Bool)
    case schemes(json: Bool)
    case types(json: Bool)
    case handlers(kind: CLIAssociationKind, identifier: String, backend: Backend, role: HandlerRole, json: Bool)
    case get(kind: CLIAssociationKind, identifier: String, backend: Backend, role: HandlerRole, json: Bool)
    case set(kind: CLIAssociationKind, identifier: String, app: String, backend: Backend, role: HandlerRole)
    case doctor(json: Bool)

    public var usesJSON: Bool {
        switch self {
        case .help, .set:
            false
        case let .apps(json), let .app(_, json), let .schemes(json), let .types(json),
             let .handlers(_, _, _, _, json), let .get(_, _, _, _, json), let .doctor(json):
            json
        }
    }
}
