import Foundation

public protocol HandlerBackend: Sendable {
    func applications(for association: Association, role: HandlerRole) async throws -> [ApplicationReference]
    func defaultApplication(for association: Association, role: HandlerRole) async throws -> ApplicationReference?
    func setDefaultApplication(_ application: ApplicationReference, for association: Association, role: HandlerRole) async throws
}
