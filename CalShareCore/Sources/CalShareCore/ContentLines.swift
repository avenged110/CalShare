// MARK: - ContentLines.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// The text format shared by iCalendar (RFC 5545) and vCard (RFC 6350): folded content
// lines grouped into BEGIN/END components. The parser is tolerant of what real clients
// send (bare LF line endings, lowercase names, quoted parameters containing ':' or ';')
// and strict about structure (balanced BEGIN/END, a single root).

import Foundation

public struct ContentProperty: Sendable, Equatable {
    /// Uppercased name, without any vCard group prefix ("item1.EMAIL" → "EMAIL").
    public var name: String
    public var group: String?
    /// Parameter names uppercased; values in order, unquoted.
    public var parameters: [String: [String]]
    public var value: String

    public func parameter(_ name: String) -> String? { parameters[name.uppercased()]?.first }
}

public struct ContentComponent: Sendable, Equatable {
    public var name: String
    public var properties: [ContentProperty] = []
    public var children: [ContentComponent] = []

    public func property(_ name: String) -> ContentProperty? {
        let upper = name.uppercased()
        return properties.first { $0.name == upper }
    }

    public func properties(_ name: String) -> [ContentProperty] {
        let upper = name.uppercased()
        return properties.filter { $0.name == upper }
    }
}

public struct ContentParseError: Error, CustomStringConvertible, Equatable {
    public let description: String
    init(_ description: String) { self.description = description }
}

public enum ContentLineParser {
    /// Unfolds lines: a line beginning with a space or tab continues the previous one.
    public static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        var current: String?
        // Normalize CRLF and lone CR to LF before splitting.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = rawLine.first, first == " " || first == "\t" {
                // Appended in place: a long value (a contact photo) is folded into
                // thousands of lines, and rebuilding it for each one is quadratic.
                if current == nil { current = "" }
                current!.append(contentsOf: rawLine.dropFirst())
            } else {
                if let current, !current.isEmpty { lines.append(current) }
                current = String(rawLine)
            }
        }
        if let current, !current.isEmpty { lines.append(current) }
        return lines
    }

    public static func parseLine(_ line: String) throws -> ContentProperty {
        var nameEnd = line.startIndex
        while nameEnd < line.endIndex, line[nameEnd] != ";", line[nameEnd] != ":" {
            nameEnd = line.index(after: nameEnd)
        }
        guard nameEnd < line.endIndex else { throw ContentParseError("Line has no value: \(line.prefix(60))") }
        var fullName = String(line[line.startIndex..<nameEnd])
        guard !fullName.isEmpty else { throw ContentParseError("Line has no name") }
        var group: String?
        if let dot = fullName.lastIndex(of: ".") {
            group = String(fullName[fullName.startIndex..<dot])
            fullName = String(fullName[fullName.index(after: dot)...])
        }
        var parameters: [String: [String]] = [:]
        var index = nameEnd
        // Parameters: ;NAME=value,value or ;NAME="quoted;value"
        while index < line.endIndex, line[index] == ";" {
            index = line.index(after: index)
            var paramNameEnd = index
            while paramNameEnd < line.endIndex, !"=;:".contains(line[paramNameEnd]) {
                paramNameEnd = line.index(after: paramNameEnd)
            }
            let paramName = String(line[index..<paramNameEnd]).uppercased()
            index = paramNameEnd
            var values: [String] = []
            if index < line.endIndex, line[index] == "=" {
                index = line.index(after: index)
                repeat {
                    if index < line.endIndex, line[index] == "," { index = line.index(after: index) }
                    if index < line.endIndex, line[index] == "\"" {
                        let start = line.index(after: index)
                        guard let close = line[start...].firstIndex(of: "\"") else {
                            throw ContentParseError("Unterminated quoted parameter")
                        }
                        values.append(String(line[start..<close]))
                        index = line.index(after: close)
                    } else {
                        let start = index
                        while index < line.endIndex, !",;:".contains(line[index]) {
                            index = line.index(after: index)
                        }
                        values.append(String(line[start..<index]))
                    }
                } while index < line.endIndex && line[index] == ","
            } else {
                // vCard 2.1-style bare parameter ("TEL;CELL:") is treated as a TYPE.
                values.append(paramName)
                parameters["TYPE", default: []].append(contentsOf: values)
                continue
            }
            if !paramName.isEmpty { parameters[paramName, default: []].append(contentsOf: values) }
        }
        guard index < line.endIndex, line[index] == ":" else {
            throw ContentParseError("Malformed parameters: \(line.prefix(60))")
        }
        let value = String(line[line.index(after: index)...])
        return ContentProperty(name: fullName.uppercased(), group: group, parameters: parameters, value: value)
    }

    /// Parses the whole text into its root components (usually exactly one).
    public static func parse(_ text: String) throws -> [ContentComponent] {
        var roots: [ContentComponent] = []
        var stack: [ContentComponent] = []
        for line in unfold(text) {
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) { continue }
            let property = try parseLine(line)
            switch property.name {
            case "BEGIN":
                stack.append(ContentComponent(name: property.value.uppercased().trimmingCharacters(in: .whitespaces)))
                guard stack.count <= 32 else { throw ContentParseError("Components nested too deeply") }
            case "END":
                guard let component = stack.popLast() else { throw ContentParseError("END without BEGIN") }
                guard component.name == property.value.uppercased().trimmingCharacters(in: .whitespaces) else {
                    throw ContentParseError("END:\(property.value) does not close BEGIN:\(component.name)")
                }
                if stack.isEmpty { roots.append(component) } else { stack[stack.count - 1].children.append(component) }
            default:
                guard !stack.isEmpty else { throw ContentParseError("Property outside any component") }
                stack[stack.count - 1].properties.append(property)
            }
        }
        guard stack.isEmpty else { throw ContentParseError("BEGIN:\(stack.last!.name) is never closed") }
        return roots
    }

    /// Unescapes a TEXT value (\\n, \\, \\; \\,).
    public static func unescapeText(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var out = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.next() {
                switch next {
                case "n", "N": out.append("\n")
                default: out.append(next)
                }
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// Serializes a component back to text with CRLF endings and 75-octet folding.
    public static func serialize(_ component: ContentComponent) -> String {
        var out = ""
        func emit(_ line: String) {
            let utf8 = Array(line.utf8)
            // Walks forward by index: removing each piece from the front instead would move
            // the rest of a long value along for every 75 bytes written.
            var start = 0
            while start < utf8.count {
                let limit = start == 0 ? 75 : 74
                var cut = min(start + limit, utf8.count)
                // Never split inside a multi-byte UTF-8 sequence.
                while cut < utf8.count, cut > start, (utf8[cut] & 0xC0) == 0x80 { cut -= 1 }
                out += (start == 0 ? "" : " ") + String(decoding: utf8[start..<cut], as: UTF8.self) + "\r\n"
                start = cut
            }
        }
        func write(_ component: ContentComponent) {
            emit("BEGIN:\(component.name)")
            for property in component.properties {
                var line = (property.group.map { $0 + "." } ?? "") + property.name
                for (name, values) in property.parameters.sorted(by: { $0.key < $1.key }) {
                    let rendered = values.map { value in
                        value.contains(where: { ",;:".contains($0) }) ? "\"\(value)\"" : value
                    }
                    line += ";\(name)=" + rendered.joined(separator: ",")
                }
                emit(line + ":" + property.value)
            }
            for child in component.children { write(child) }
            emit("END:\(component.name)")
        }
        write(component)
        return out
    }
}
