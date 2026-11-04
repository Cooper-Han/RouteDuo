import Foundation

@objc protocol RouteHelperProtocol {
    func healthCheck(withReply reply: @escaping (Bool, String) -> Void)
    func addRoutes(_ routes: [String], withReply reply: @escaping (Bool, String) -> Void)
    func deleteRoutes(_ routes: [String], withReply reply: @escaping (Bool, String) -> Void)
    func replaceRoutes(_ routesToDelete: [String], with routesToAdd: [String], withReply reply: @escaping (Bool, String) -> Void)
    func reorderNetworkServices(_ services: [String], withReply reply: @escaping (Bool, String) -> Void)
    func setNetworkServiceOrder(_ serviceIDs: [String], withReply reply: @escaping (Bool, String) -> Void)
}
