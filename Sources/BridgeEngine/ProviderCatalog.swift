import Foundation
import CryptoKit
import Darwin

/// A preview of explicitly configured providers, never an effective-runtime config.
public struct NativeProvider: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let endpointOrigin: String?
    public let selectable: Bool
    public let blocker: String?

    enum CodingKeys: String, CodingKey {
        case id, name, selectable, blocker
        case endpointOrigin = "endpoint_origin"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(selectable, forKey: .selectable)
        if let endpointOrigin { try values.encode(endpointOrigin, forKey: .endpointOrigin) }
        else { try values.encodeNil(forKey: .endpointOrigin) }
        if let blocker { try values.encode(blocker, forKey: .blocker) }
        else { try values.encodeNil(forKey: .blocker) }
    }
}

public struct ProviderCatalogResult: Codable, Equatable, Sendable {
    public let providers: [NativeProvider]
    /// Private preflight binding. Do not display it as configuration content.
    public let configRevision: String
    public let configSource: String
    public let overridesUnknown: Bool

    enum CodingKeys: String, CodingKey {
        case providers
        case configRevision = "config_revision"
        case configSource = "config_source"
        case overridesUnknown = "overrides_unknown"
    }
}

/// Every error is fixed text. Neither OS errors nor parser input escape this type.
public enum ProviderCatalogError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case unsafeHome, unavailable, unsafeConfig, tooLarge, changed
    case invalidTOML, invalidIdentifier, invalidTable

    public var code: String {
        switch self {
        case .unsafeHome: return "unsafe_home"
        case .unavailable: return "config_unavailable"
        case .unsafeConfig: return "unsafe_config"
        case .tooLarge: return "config_too_large"
        case .changed: return "config_changed"
        case .invalidTOML, .invalidIdentifier, .invalidTable: return "invalid_config"
        }
    }

    public var message: String {
        switch self {
        case .unsafeHome: return "Select an absolute, non-symlink CODEX_HOME directory."
        case .unavailable: return "Selected config could not be read safely."
        case .unsafeConfig: return "Selected config must be a regular, non-linked file."
        case .tooLarge: return "Selected config exceeds the 1 MiB limit."
        case .changed: return "Selected config changed while being read; retry the preview."
        case .invalidTOML: return "Selected config is not valid TOML."
        case .invalidIdentifier: return "Selected config contains an invalid provider identifier."
        case .invalidTable: return "Selected config contains an invalid provider table."
        }
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

public enum NativeProviderCatalog {
    private static let maximumBytes = 1_024 * 1_024

    public static func read(home: URL) throws -> ProviderCatalogResult {
        let raw = try readSelectedConfig(home: home)
        guard let text = String(data: raw, encoding: .utf8) else {
            throw ProviderCatalogError.invalidTOML
        }
        let root = try CatalogTOML.parse(text)
        let definitions: CatalogTable
        if let value = root.entries["model_providers"] {
            guard case let .table(table) = value else { throw ProviderCatalogError.invalidTable }
            definitions = table
        } else {
            definitions = CatalogTable()
        }

        var providers: [NativeProvider] = []
        for (rawID, value) in definitions.entries {
            let id = try providerID(rawID)
            guard case let .table(definition) = value else { throw ProviderCatalogError.invalidTable }
            let endpoint = definition.entries["base_url"]
            let origin: String?
            if case let .string(value)? = endpoint {
                origin = endpointOrigin(value)
            } else {
                origin = nil
            }
            let missing: Bool
            if endpoint == nil { missing = true }
            else if case .string("")? = endpoint { missing = true }
            else { missing = false }
            providers.append(NativeProvider(
                id: id, name: providerName(definition.entries["name"], fallback: id),
                endpointOrigin: origin, selectable: origin != nil,
                blocker: origin != nil ? nil : (missing ? "host_unknown" : "invalid_endpoint")
            ))
        }
        if let activeValue = root.entries["model_provider"] {
            guard case let .string(value) = activeValue else { throw ProviderCatalogError.invalidIdentifier }
            let active = try providerID(value)
            if definitions.entries[active] == nil {
                providers.append(NativeProvider(id: active, name: active, endpointOrigin: nil,
                                                selectable: false, blocker: "host_unknown"))
            }
        }
        return ProviderCatalogResult(
            providers: providers.sorted { $0.id < $1.id },
            configRevision: SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined(),
            configSource: "CODEX_HOME/config.toml", overridesUnknown: true
        )
    }

    private static func readSelectedConfig(home: URL) throws -> Data {
        // Never standardize/resolve the selected URL or consult HOME/CODEX_HOME.
        let path = home.path
        // POSIX separators are bytes. Character-based splitting can miss a '/'
        // followed by a combining mark and accidentally pass a multi-component
        // name to openat, weakening O_NOFOLLOW on an intermediate component.
        let components = path.utf8.split(separator: 47).map { String(decoding: $0, as: UTF8.self) }
        guard home.isFileURL, home.baseURL == nil,
              home.host == nil || home.host == "", home.query == nil, home.fragment == nil,
              home.user == nil, home.password == nil, home.port == nil,
              path.utf8.first == 47, !path.utf8.contains(0),
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw ProviderCatalogError.unsafeHome
        }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var directory = Darwin.open("/", directoryFlags)
        guard directory >= 0 else { throw ProviderCatalogError.unavailable }
        defer { Darwin.close(directory) }
        for component in components {
            let next = component.withCString { Darwin.openat(directory, $0, directoryFlags) }
            guard next >= 0 else { throw ProviderCatalogError.unavailable }
            Darwin.close(directory)
            directory = next
        }
        let descriptor = Darwin.openat(directory, "config.toml", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProviderCatalogError.unavailable }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0 else { throw ProviderCatalogError.unavailable }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1,
              before.st_size >= 0 else { throw ProviderCatalogError.unsafeConfig }
        guard before.st_size <= off_t(maximumBytes) else { throw ProviderCatalogError.tooLarge }
        var result = Data()
        result.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while result.count <= maximumBytes {
            let requested = min(buffer.count, maximumBytes + 1 - result.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, requested) }
            if count < 0 {
                if errno == EINTR { continue }
                throw ProviderCatalogError.unavailable
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard result.count <= maximumBytes else { throw ProviderCatalogError.tooLarge }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else { throw ProviderCatalogError.unavailable }
        guard before.st_size == after.st_size, off_t(result.count) == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_nlink == 1, after.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ProviderCatalogError.changed
        }
        return result
    }

    private static func providerID(_ value: String) throws -> String {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first, asciiAlphanumeric(first),
              bytes.allSatisfy({ asciiAlphanumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else {
            throw ProviderCatalogError.invalidIdentifier
        }
        return value
    }

    private static func providerName(_ value: CatalogValue?, fallback: String) -> String {
        guard case let .string(name)? = value, (1...80).contains(name.unicodeScalars.count),
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name.unicodeScalars.allSatisfy(isPrintable) else { return fallback }
        return name
    }

    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
            return false
        case .spaceSeparator: return scalar.value == 32
        default: return true
        }
    }

    private static func endpointOrigin(_ value: String) -> String? {
        guard !value.isEmpty, value.unicodeScalars.count <= 8_192,
              value.unicodeScalars.allSatisfy({ isPrintable($0) && !$0.properties.isWhitespace }),
              !value.contains("\\"), validPercentEscapes(value),
              let separator = value.range(of: "://") else { return nil }
        let scheme = value[..<separator.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let remainder = value[separator.upperBound...]
        let authority = remainder.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.isEmpty, authority.filter({ $0 == "@" }).count <= 1 else { return nil }
        let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last!
        let hostname: String
        let portString: Substring?
        if hostAndPort.hasPrefix("[") {
            guard let closing = hostAndPort.firstIndex(of: "]") else { return nil }
            let host = String(hostAndPort[hostAndPort.index(after: hostAndPort.startIndex)..<closing])
            let suffix = hostAndPort[hostAndPort.index(after: closing)...]
            guard suffix.isEmpty || suffix.hasPrefix(":"), !host.contains("%"),
                  let normalized = ipv6(host) else { return nil }
            hostname = "[" + normalized + "]"
            portString = suffix.isEmpty ? nil : suffix.dropFirst()
        } else {
            let parts = hostAndPort.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2, let first = parts.first,
                  let normalized = dnsHostname(String(first)) else { return nil }
            hostname = normalized
            portString = parts.count == 2 ? parts[1] : nil
        }
        var portSuffix = ""
        if let portString {
            guard !portString.isEmpty, portString.utf8.allSatisfy({ (48...57).contains($0) }),
                  let port = Int(portString), (1...65_535).contains(port) else { return nil }
            portSuffix = ":" + String(port)
        }
        return scheme + "://" + hostname + portSuffix
    }

    private static func validPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { return false }
                index += 3
            } else { index += 1 }
        }
        return true
    }

    private static func dnsHostname(_ input: String) -> String? {
        guard !input.isEmpty, !input.contains("%") else { return nil }
        // Conservative IDNA subset: normalize Unicode letters/numbers/marks,
        // then Punycode. Other Unicode hostname syntax is rejected, not guessed.
        let folded = input.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{3002}", with: ".")
            .replacingOccurrences(of: "\u{FF0E}", with: ".")
            .replacingOccurrences(of: "\u{FF61}", with: ".")
            .lowercased()
        let trailingDot = folded.hasSuffix(".")
        let name = trailingDot ? String(folded.dropLast()) : folded
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        var normalized: [String] = []
        for label in labels {
            guard !label.isEmpty, let initial = label.unicodeScalars.first,
                  initial.value != 45, label.unicodeScalars.last?.value != 45 else { return nil }
            switch initial.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return nil
            default: break
            }
            let ascii: String
            if label.utf8.allSatisfy({ $0 < 128 }) { ascii = String(label) }
            else {
                guard label.unicodeScalars.count <= 63,
                      label.unicodeScalars.allSatisfy({ scalar in
                          if scalar.value < 128 { return asciiAlphanumeric(UInt8(scalar.value)) || scalar.value == 45 }
                          switch scalar.properties.generalCategory {
                          case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                               .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber:
                              return true
                          default: return false
                          }
                      }), let encoded = punycode(String(label)) else { return nil }
                ascii = "xn--" + encoded
            }
            let bytes = Array(ascii.utf8)
            guard (1...63).contains(bytes.count), asciiAlphanumeric(bytes[0]), asciiAlphanumeric(bytes[bytes.count - 1]),
                  bytes.allSatisfy({ asciiAlphanumeric($0) || $0 == 45 }) else { return nil }
            normalized.append(ascii)
        }
        let host = normalized.joined(separator: ".")
        guard host.utf8.count <= 253 else { return nil }
        // Avoid showing a DNS-looking origin that permissive URL/IP parsers
        // interpret as an alternate numeric IPv4 address (e.g. 0x7f000001).
        if normalized.contains(where: { $0.hasPrefix("0x") }), normalized.allSatisfy({ label in
            if label.hasPrefix("0x") {
                let digits = label.utf8.dropFirst(2)
                return !digits.isEmpty && digits.allSatisfy(isHex)
            }
            return !label.isEmpty && label.utf8.allSatisfy { (48...57).contains($0) }
        }) { return nil }
        if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ part in
                !part.isEmpty && (part.count == 1 || part.first != "0") && Int(part).map { (0...255).contains($0) } == true
            }) else { return nil }
            return host // Numeric addresses have no trailing-dot form in the result.
        }
        return host + (trailingDot ? "." : "")
    }

    private static func ipv6(_ value: String) -> String? {
        var address = in6_addr()
        guard value.withCString({ Darwin.inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        let groups = stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        var bestStart = 0, bestLength = 0, index = 0
        while index < groups.count {
            if groups[index] != 0 { index += 1; continue }
            let start = index
            while index < groups.count && groups[index] == 0 { index += 1 }
            if index - start > bestLength { bestStart = start; bestLength = index - start }
        }
        let strings = groups.map { String($0, radix: 16) }
        guard bestLength >= 2 else { return strings.joined(separator: ":") }
        let left = strings.prefix(bestStart).joined(separator: ":")
        let right = strings.dropFirst(bestStart + bestLength).joined(separator: ":")
        return left + "::" + right
    }

    /// RFC 3492 Bootstring, used only after the conservative hostname filter.
    private static func punycode(_ label: String) -> String? {
        let points = label.unicodeScalars.map { Int($0.value) }
        var output = points.filter { $0 < 128 }.map { UInt8($0) }
        let basicCount = output.count
        var handled = basicCount, n = 128, delta = 0, bias = 72
        if basicCount > 0 { output.append(45) }
        func digit(_ value: Int) -> UInt8 { UInt8(value < 26 ? value + 97 : value - 26 + 48) }
        func adapt(_ original: Int, _ count: Int, _ first: Bool) -> Int {
            var value = first ? original / 700 : original / 2
            value += value / count
            var k = 0
            while value > 455 { value /= 35; k += 36 }
            return k + 36 * value / (value + 38)
        }
        while handled < points.count {
            guard let minimum = points.filter({ $0 >= n }).min() else { return nil }
            delta += (minimum - n) * (handled + 1)
            n = minimum
            for point in points {
                if point < n { delta += 1 }
                if point == n {
                    var q = delta, k = 36
                    while true {
                        let threshold = k <= bias ? 1 : (k >= bias + 26 ? 26 : k - bias)
                        if q < threshold { break }
                        output.append(digit(threshold + (q - threshold) % (36 - threshold)))
                        q = (q - threshold) / (36 - threshold)
                        k += 36
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
            if output.count > 59 { return nil }
        }
        return String(bytes: output, encoding: .ascii)
    }
}

private func asciiAlphanumeric(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
}

private func isHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
}

private enum CatalogValue {
    case string(String), other, table(CatalogTable)
}

private final class CatalogTable {
    var entries: [String: CatalogValue] = [:]
    var explicitlyDefined = false
    var sealed = false
}

/// Deliberately conservative TOML. Supports normal/quoted table paths, simple
/// keys, one-line strings, numbers, booleans, arrays, and inline tables. Rejects
/// multiline syntax, array tables, dotted assignment keys, and date/time values.
/// All lines are lexed, including ignored fields; strings cannot create tables.
private enum CatalogTOML {
    static func parse(_ text: String) throws -> CatalogTable {
        let root = CatalogTable()
        root.explicitlyDefined = true
        var current = root
        let lines = text.utf8.split(separator: 10, omittingEmptySubsequences: false)
        for (lineNumber, rawLine) in lines.enumerated() {
            var bytes = Array(rawLine)
            // A CR is allowed only as the CRLF line ending, never by itself.
            if lineNumber < lines.count - 1, bytes.last == 13 { bytes.removeLast() }
            guard bytes.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else {
                throw ProviderCatalogError.invalidTOML
            }
            var lexer = CatalogLine(bytes: bytes)
            lexer.skipSpace()
            if lexer.finished || lexer.peek == 35 { continue }
            if lexer.take(91) {
                guard lexer.peek != 91 else { throw ProviderCatalogError.invalidTOML }
                let path = try lexer.keyPath()
                guard lexer.take(93) else { throw ProviderCatalogError.invalidTOML }
                try lexer.finish()
                var table = root
                for (index, key) in path.enumerated() {
                    guard !table.sealed else { throw ProviderCatalogError.invalidTOML }
                    let next: CatalogTable
                    if let existing = table.entries[key] {
                        guard case let .table(value) = existing, !value.sealed else { throw ProviderCatalogError.invalidTOML }
                        next = value
                    } else {
                        next = CatalogTable()
                        table.entries[key] = .table(next)
                    }
                    if index == path.count - 1 {
                        guard !next.explicitlyDefined else { throw ProviderCatalogError.invalidTOML }
                        next.explicitlyDefined = true
                    }
                    table = next
                }
                current = table
            } else {
                let key = try lexer.simpleAssignmentKey()
                guard current.entries[key] == nil else { throw ProviderCatalogError.invalidTOML }
                current.entries[key] = try lexer.value(depth: 0)
                try lexer.finish()
            }
        }
        return root
    }
}

private struct CatalogLine {
    let bytes: [UInt8]
    var index = 0
    var finished: Bool { index >= bytes.count }
    var peek: UInt8? { finished ? nil : bytes[index] }

    mutating func skipSpace() {
        while peek == 32 || peek == 9 { index += 1 }
    }

    @discardableResult mutating func take(_ expected: UInt8) -> Bool {
        guard peek == expected else { return false }
        index += 1
        return true
    }

    mutating func finish() throws {
        skipSpace()
        guard finished || peek == 35 else { throw ProviderCatalogError.invalidTOML }
    }

    mutating func keyPath() throws -> [String] {
        var result = [try key()]
        skipSpace()
        while take(46) {
            guard result.count < 32 else { throw ProviderCatalogError.invalidTOML }
            result.append(try key())
            skipSpace()
        }
        return result
    }

    mutating func key() throws -> String {
        skipSpace()
        if peek == 34 || peek == 39 { return try string() }
        let start = index
        while let byte = peek, asciiAlphanumeric(byte) || byte == 45 || byte == 95 { index += 1 }
        guard index > start else { throw ProviderCatalogError.invalidTOML }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    mutating func simpleAssignmentKey() throws -> String {
        let name = try key()
        skipSpace()
        guard take(61) else { throw ProviderCatalogError.invalidTOML }
        skipSpace()
        return name
    }

    mutating func value(depth: Int) throws -> CatalogValue {
        guard depth < 32 else { throw ProviderCatalogError.invalidTOML }
        skipSpace()
        if peek == 34 || peek == 39 { return .string(try string()) }
        if take(91) {
            skipSpace()
            if take(93) { return .other }
            while true {
                _ = try value(depth: depth + 1)
                skipSpace()
                if take(93) { return .other }
                guard take(44) else { throw ProviderCatalogError.invalidTOML }
                skipSpace()
                if take(93) { return .other }
            }
        }
        if take(123) {
            let table = CatalogTable()
            table.sealed = true
            table.explicitlyDefined = true
            skipSpace()
            if take(125) { return .table(table) }
            while true {
                let key = try simpleAssignmentKey()
                guard table.entries[key] == nil else { throw ProviderCatalogError.invalidTOML }
                table.entries[key] = try value(depth: depth + 1)
                skipSpace()
                if take(125) { return .table(table) }
                guard take(44) else { throw ProviderCatalogError.invalidTOML }
                skipSpace()
                // TOML inline tables cannot have a trailing comma.
                guard peek != 125 else { throw ProviderCatalogError.invalidTOML }
            }
        }
        let start = index
        while let byte = peek, ![UInt8(9), 32, 35, 44, 93, 125].contains(byte) { index += 1 }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        guard validScalar(token) else { throw ProviderCatalogError.invalidTOML }
        return .other
    }

    private func validScalar(_ value: String) -> Bool {
        if ["true", "false", "inf", "+inf", "-inf", "nan", "+nan", "-nan"].contains(value) { return true }
        let decimal = #"[+-]?(?:0|[1-9](?:_?[0-9])*)"#
        let fraction = #"\.[0-9](?:_?[0-9])*"#
        let exponent = #"[eE][+-]?[0-9](?:_?[0-9])*"#
        let patterns = [
            "^" + decimal + "$",
            #"^0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*$"#,
            #"^0o[0-7](?:_?[0-7])*$"#,
            #"^0b[01](?:_?[01])*$"#,
            "^" + decimal + "(?:" + fraction + "(?:" + exponent + ")?|" + exponent + ")$"
        ]
        return patterns.contains {
            guard let match = value.range(of: $0, options: .regularExpression) else { return false }
            // ICU's $ also matches before a final Unicode line separator.
            // A token must be consumed in full, with no hidden suffix.
            return match.lowerBound == value.startIndex && match.upperBound == value.endIndex
        }
    }

    mutating func string() throws -> String {
        guard let quote = peek, quote == 34 || quote == 39 else { throw ProviderCatalogError.invalidTOML }
        index += 1
        if index + 1 < bytes.count, bytes[index] == quote, bytes[index + 1] == quote {
            throw ProviderCatalogError.invalidTOML
        }
        var output: [UInt8] = []
        while let byte = peek {
            index += 1
            if byte == quote {
                guard let result = String(bytes: output, encoding: .utf8) else { throw ProviderCatalogError.invalidTOML }
                return result
            }
            if byte == 92 && quote == 34 {
                guard let escape = peek else { throw ProviderCatalogError.invalidTOML }
                index += 1
                switch escape {
                case 34, 92: output.append(escape)
                case 98: output.append(8)
                case 116: output.append(9)
                case 110: output.append(10)
                case 102: output.append(12)
                case 114: output.append(13)
                case 117, 85:
                    let count = escape == 117 ? 4 : 8
                    guard index + count <= bytes.count else { throw ProviderCatalogError.invalidTOML }
                    let digits = bytes[index..<(index + count)]
                    guard digits.allSatisfy(isHex),
                          let number = UInt32(String(decoding: digits, as: UTF8.self), radix: 16),
                          let scalar = Unicode.Scalar(number) else { throw ProviderCatalogError.invalidTOML }
                    output.append(contentsOf: String(scalar).utf8)
                    index += count
                default: throw ProviderCatalogError.invalidTOML
                }
            } else { output.append(byte) }
        }
        throw ProviderCatalogError.invalidTOML
    }
}
