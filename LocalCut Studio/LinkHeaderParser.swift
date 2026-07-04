import Foundation

nonisolated struct ICEServerInfo: Hashable, Sendable {
    let url: URL
    let username: String?
    let credential: String?
}

nonisolated enum LinkHeaderParser {
    static func parse(headerValues: [String]) -> [ICEServerInfo] {
        headerValues.flatMap { parseSingleHeaderValue($0) }
    }

    private static func parseSingleHeaderValue(_ headerValue: String) -> [ICEServerInfo] {
        let links = splitLinks(headerValue)
        return links.compactMap { parseOneLink($0) }
    }

    private static func splitLinks(_ value: String) -> [String] {
        var results: [String] = []
        var current = ""
        var inAngleBrackets = false
        var inQuotes = false
        for char in value {
            switch char {
            case "\"" where !inAngleBrackets:
                inQuotes.toggle()
                current.append(char)
            case "<":
                inAngleBrackets = true
                current.append(char)
            case ">":
                inAngleBrackets = false
                current.append(char)
            case "," where !inAngleBrackets && !inQuotes:
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { results.append(trimmed) }
                current = ""
            default:
                current.append(char)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { results.append(trimmed) }
        return results
    }

    private static func parseOneLink(_ link: String) -> ICEServerInfo? {
        guard let ltIndex = link.firstIndex(of: "<"),
              let gtIndex = link[ltIndex...].firstIndex(of: ">") else { return nil }
        let urlString = String(link[link.index(after: ltIndex)..<gtIndex])
            .trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlString) else { return nil }
        let paramsString = String(link[link.index(after: gtIndex)...])
        let params = parseParameters(paramsString)
        guard let rel = params["rel"], rel == "ice-server" else { return nil }
        let username = params["username"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let credential = params["credential"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return ICEServerInfo(
            url: url,
            username: username?.isEmpty == true ? nil : username,
            credential: credential?.isEmpty == true ? nil : credential
        )
    }

    private static func parseParameters(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        for char in text {
            switch char {
            case "\"":
                inQuotes.toggle()
                current.append(char)
            case ";" where !inQuotes:
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { segments.append(trimmed) }
                current = ""
            default:
                current.append(char)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { segments.append(trimmed) }
        for segment in segments {
            guard let eqIndex = segment.firstIndex(of: "=") else { continue }
            let key = String(segment[..<eqIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(segment[segment.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }
}
