import Foundation

struct RouteAddressFile: Codable {
    struct Record: Codable {
        let address: String
        let note: String
    }
    struct ValidationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    let version: Int
    let routes: [Record]

    func validate() throws {
        guard version == 1 else { throw ValidationError("不支持此文件版本：\(version)。") }
        guard !routes.isEmpty, routes.count <= 10000 else {
            throw ValidationError("文件需包含 1 至 10000 条分流地址。")
        }
        for (index, record) in routes.enumerated() {
            let prefix = "第 \(index + 1) 条记录："
            let address = record.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { throw ValidationError(prefix + "地址不能为空。") }
            guard !record.note.contains("|"), !record.note.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ValidationError(prefix + "备注不能包含换行、控制字符或 |。")
            }
            guard !address.contains("*"), !address.contains(":") else {
                throw ValidationError(prefix + "目前仅支持 IPv4 或完整域名，不支持通配符、IPv6、端口及网址链接。")
            }
            let parts = address.split(separator: ".", omittingEmptySubsequences: false)
            if address.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) {
                guard parts.count == 4, parts.allSatisfy({ part in
                    guard !part.isEmpty, part.count <= 3, let number = Int(part), (0...255).contains(number) else { return false }
                    return part.count == 1 || part.first != "0"
                }) else { throw ValidationError(prefix + "IPv4 地址格式不正确：\(address)") }
            } else {
                guard address.utf8.count <= 253, parts.count >= 2,
                      parts.allSatisfy({ label in
                          !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                          label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
                      }), parts.last!.utf8.contains(where: { (65...90).contains($0) || (97...122).contains($0) }) else {
                    throw ValidationError(prefix + "域名格式不正确：\(address)。请填写完整域名，国际化域名请使用 Punycode。")
                }
            }
        }
    }
}
