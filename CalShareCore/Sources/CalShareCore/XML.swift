// MARK: - XML.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// WebDAV request bodies are parsed into a small namespace-aware tree. Document type
// declarations are refused outright, which rules out entity expansion and external
// entity attacks before the parser ever sees them. Responses are written with a builder
// that declares the common namespaces once on the root element.

import Foundation

public struct QName: Hashable, Sendable, CustomStringConvertible {
    public var namespace: String
    public var name: String

    public init(_ namespace: String, _ name: String) { self.namespace = namespace; self.name = name }

    public var description: String { "{\(namespace)}\(name)" }

    /// Whether the local name can be written as an element name as it stands: an XML
    /// NCName in the ASCII range, which covers every DAV, CalDAV, and CardDAV property.
    /// Names that arrive as attribute values (expand-property) are checked against it,
    /// since XMLWriter writes names unescaped.
    public var hasWritableName: Bool {
        guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= 256,
              first.properties.isAlphabetic && first.isASCII || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "-_.".unicodeScalars.contains($0)) }
    }
}

public enum NS {
    public static let dav = "DAV:"
    public static let caldav = "urn:ietf:params:xml:ns:caldav"
    public static let carddav = "urn:ietf:params:xml:ns:carddav"
    public static let calendarServer = "http://calendarserver.org/ns/"
    public static let apple = "http://apple.com/ns/ical/"
    public static let me = "http://me.com/_namespace/"

    /// Prefixes declared on every response root.
    static let prefixes: [(String, String)] = [
        ("d", dav), ("cal", caldav), ("card", carddav), ("cs", calendarServer), ("ical", apple),
    ]

    static func prefix(for namespace: String) -> String? { prefixes.first { $0.1 == namespace }?.0 }
}

public final class XMLElementNode: @unchecked Sendable {
    public let qname: QName
    public var attributes: [String: String] = [:]
    public var children: [XMLElementNode] = []
    public var text = ""
    /// The element's content re-serialized, for storing dead properties verbatim.
    public var innerXML = ""

    init(qname: QName) { self.qname = qname }

    public func child(_ namespace: String, _ name: String) -> XMLElementNode? {
        children.first { $0.qname == QName(namespace, name) }
    }

    public func children(_ namespace: String, _ name: String) -> [XMLElementNode] {
        children.filter { $0.qname == QName(namespace, name) }
    }

    public func descendant(_ namespace: String, _ name: String) -> XMLElementNode? {
        for child in children {
            if child.qname == QName(namespace, name) { return child }
            if let found = child.descendant(namespace, name) { return found }
        }
        return nil
    }

    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum XMLParseError: Error { case doctypeNotAllowed, malformed(String), tooDeep }

public enum XMLRequestParser {
    public static func parse(_ data: Data) throws -> XMLElementNode {
        // Refuse DTDs: no entity declarations means no billion-laughs and no XXE. The byte
        // search only sees UTF-8, so a body in any other encoding (UTF-16 or UTF-32, which
        // carry NUL bytes or a byte-order mark) is refused too, and the delegate below
        // aborts on any declaration that gets through regardless.
        if data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!ENTITY".utf8)) != nil
            || data.contains(0) || data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE]) {
            throw XMLParseError.doctypeNotAllowed
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        // XMLParser holds its delegate unowned(unsafe), so the delegate's lifetime is made
        // explicit across the parse rather than left to where it is last used.
        return try withExtendedLifetime(delegate) {
            unsafe parser.delegate = delegate
            guard parser.parse(), !delegate.sawDeclaration, let root = delegate.root else {
                if delegate.sawDeclaration { throw XMLParseError.doctypeNotAllowed }
                if delegate.tooDeep { throw XMLParseError.tooDeep }
                throw XMLParseError.malformed(parser.parserError?.localizedDescription ?? "unknown")
            }
            return root
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var root: XMLElementNode?
        var stack: [XMLElementNode] = []
        var tooDeep = false
        /// Set by any DTD content: a request body never needs one.
        var sawDeclaration = false

        private func refuse(_ parser: XMLParser) {
            sawDeclaration = true
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { refuse(parser) }
        func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String, type: String?, defaultValue: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            refuse(parser)
            return nil
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard !sawDeclaration else { return }
            guard stack.count < 64 else { tooDeep = true; parser.abortParsing(); return }
            let node = XMLElementNode(qname: QName(namespaceURI ?? "", elementName))
            node.attributes = attributeDict
            let attributes = attributeDict.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(XMLEscape.text($0.value))\"" }.joined()
            for ancestor in stack { ancestor.innerXML += "<\(elementName) xmlns=\"\(XMLEscape.text(namespaceURI ?? ""))\"\(attributes)>" }
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
            for ancestor in stack { ancestor.innerXML += "</\(elementName)>" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
            for node in stack { node.innerXML += XMLEscape.text(string) }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            let string = String(decoding: CDATABlock, as: UTF8.self)
            stack.last?.text += string
            for node in stack { node.innerXML += XMLEscape.text(string) }
        }
    }
}

/// Builds response XML. Elements in the five well-known namespaces use their standard
/// prefixes; anything else gets a local default-namespace declaration.
public struct XMLWriter {
    public private(set) var output = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"

    public init() {}

    static func tag(_ qname: QName) -> (open: String, close: String) {
        if let prefix = NS.prefix(for: qname.namespace) {
            return ("\(prefix):\(qname.name)", "\(prefix):\(qname.name)")
        }
        // A prefix can't be bound to the empty namespace; an unprefixed name can be.
        if qname.namespace.isEmpty { return ("\(qname.name) xmlns=\"\"", qname.name) }
        return ("x:\(qname.name) xmlns:x=\"\(XMLEscape.text(qname.namespace))\"", "x:\(qname.name)")
    }

    public mutating func openRoot(_ qname: QName) {
        let declarations = NS.prefixes.map { " xmlns:\($0.0)=\"\($0.1)\"" }.joined()
        output += "<\(Self.tag(qname).open)\(declarations)>"
    }

    public mutating func open(_ qname: QName) { output += "<\(Self.tag(qname).open)>" }
    public mutating func close(_ qname: QName) { output += "</\(Self.tag(qname).close)>" }
    public mutating func empty(_ qname: QName) { output += "<\(Self.tag(qname).open)/>" }

    public mutating func element(_ qname: QName, text: String) {
        let tag = Self.tag(qname)
        output += "<\(tag.open)>\(XMLEscape.text(text))</\(tag.close)>"
    }

    public mutating func element(_ qname: QName, rawXML: String) {
        let tag = Self.tag(qname)
        output += "<\(tag.open)>\(rawXML)</\(tag.close)>"
    }

    public mutating func raw(_ xml: String) { output += xml }

    public mutating func href(_ path: String) { element(QName(NS.dav, "href"), text: path) }
}

/// A DAV:error body naming a failed precondition (RFC 4918 §16).
public func preconditionErrorBody(_ condition: QName, description: String? = nil) -> String {
    var writer = XMLWriter()
    writer.openRoot(QName(NS.dav, "error"))
    writer.empty(condition)
    if let description { writer.element(QName(NS.calendarServer, "error-description"), text: description) }
    writer.close(QName(NS.dav, "error"))
    return writer.output
}
