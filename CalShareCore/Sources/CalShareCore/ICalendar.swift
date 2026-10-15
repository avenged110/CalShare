// MARK: - ICalendar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Validation of calendar object resources (RFC 4791 §4.1) and the metadata the server
// indexes for each one: component type, UID, and the UTC span its occurrences can cover,
// which answers time-range queries without expanding recurrences on every request.

import Foundation

public struct CalendarObjectInfo: Sendable, Equatable {
    public var component: String          // VEVENT, VTODO, VJOURNAL, VFREEBUSY
    public var uid: String
    public var firstOccurrence: Date?     // nil = unbounded in that direction
    public var lastOccurrence: Date?
}

public enum CalendarValidationError: Error, Equatable, CustomStringConvertible {
    case unparseable(String)
    case notACalendar
    case noComponents
    case mixedComponents
    case missingUID
    case mixedUIDs

    public var description: String {
        switch self {
        case .unparseable(let reason): "Not valid iCalendar data: \(reason)"
        case .notACalendar: "The body is not a single VCALENDAR."
        case .noComponents: "The calendar contains no event, task, journal, or free/busy component."
        case .mixedComponents: "A calendar object resource must hold one kind of component."
        case .missingUID: "The component has no UID."
        case .mixedUIDs: "All components in one resource must share a UID."
        }
    }
}

public enum ICalendar {
    public static let objectComponents: Set<String> = ["VEVENT", "VTODO", "VJOURNAL", "VFREEBUSY"]

    public static func parseCalendar(_ text: String) throws(CalendarValidationError) -> ContentComponent {
        let roots: [ContentComponent]
        do { roots = try ContentLineParser.parse(text) } catch {
            throw .unparseable(String(describing: error))
        }
        guard roots.count == 1, let calendar = roots.first, calendar.name == "VCALENDAR" else { throw .notACalendar }
        return calendar
    }

    public static func validate(_ data: Data) throws(CalendarValidationError) -> CalendarObjectInfo {
        guard let text = String(data: data, encoding: .utf8) else { throw .unparseable("not UTF-8") }
        let calendar = try parseCalendar(text)
        let components = calendar.children.filter { objectComponents.contains($0.name) }
        guard let firstComponent = components.first else { throw .noComponents }
        guard components.allSatisfy({ $0.name == firstComponent.name }) else { throw .mixedComponents }
        let uids = Set(components.map { $0.property("UID")?.value.trimmingCharacters(in: .whitespaces) ?? "" })
        guard !uids.contains("") else { throw .missingUID }
        guard uids.count == 1, let uid = uids.first else { throw .mixedUIDs }

        let timezones = TimeZoneResolver(calendar: calendar)
        var first: Date? = .distantFuture
        var last: Date? = .distantPast
        for component in components {
            let span = occurrenceSpan(component, timezones: timezones)
            if let current = first { first = span.first.map { min($0, current) } ?? nil }
            if let current = last { last = span.last.map { max($0, current) } ?? nil }
        }
        return CalendarObjectInfo(component: firstComponent.name, uid: uid,
                                  firstOccurrence: first, lastOccurrence: last)
    }

    // MARK: Occurrence span

    /// The widest UTC span this component's occurrences can touch. Floating and unknown
    /// time zones are widened by fourteen hours either way, so the span is conservative:
    /// a time-range query may return an extra resource but never misses one.
    static func occurrenceSpan(_ component: ContentComponent, timezones: TimeZoneResolver) -> (first: Date?, last: Date?) {
        let start = component.property("DTSTART").flatMap { timezones.date(for: $0) }
        var duration: TimeInterval = 0
        var end: ParsedDate?
        switch component.name {
        case "VEVENT":
            if let dtend = component.property("DTEND").flatMap({ timezones.date(for: $0) }) {
                end = dtend
            } else if let value = component.property("DURATION")?.value, let parsed = parseDuration(value) {
                duration = parsed
            } else if let start, start.isDateOnly {
                duration = 86_400
            }
        case "VTODO":
            if let due = component.property("DUE").flatMap({ timezones.date(for: $0) }) {
                end = due
            } else if let value = component.property("DURATION")?.value, let parsed = parseDuration(value) {
                duration = parsed
            }
            if start == nil && end == nil {
                // A task with no dates matches every range (RFC 4791 §9.9).
                return (nil, nil)
            }
        default:
            break
        }
        guard let begin = start ?? end else { return (nil, nil) }
        let slack: TimeInterval = (begin.isFloating ? 50_400 : 0)
        let firstDate = begin.date.addingTimeInterval(-slack)
        let instanceLength = max(0, (end?.date.timeIntervalSince(begin.date)) ?? duration)
        var lastDate = (end?.date ?? begin.date.addingTimeInterval(duration)).addingTimeInterval(slack)

        if let rrule = component.property("RRULE")?.value {
            guard let bound = recurrenceBound(rrule, start: begin.date, timezones: timezones) else {
                return (firstDate, nil)
            }
            lastDate = max(lastDate, bound.addingTimeInterval(instanceLength + slack))
        }
        for rdate in component.properties("RDATE") {
            for piece in rdate.value.split(separator: ",") {
                var single = rdate
                single.value = String(piece.split(separator: "/").first ?? piece)
                if let parsed = timezones.date(for: single) {
                    lastDate = max(lastDate, parsed.date.addingTimeInterval(instanceLength + slack + 50_400))
                }
            }
        }
        return (firstDate, lastDate)
    }

    /// An upper bound for the last occurrence start of an RRULE, or nil if unbounded.
    static func recurrenceBound(_ rule: String, start: Date, timezones: TimeZoneResolver) -> Date? {
        var parts: [String: String] = [:]
        for piece in rule.split(separator: ";") {
            let pair = piece.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { parts[pair[0].uppercased()] = String(pair[1]) }
        }
        if let until = parts["UNTIL"] {
            let property = ContentProperty(name: "UNTIL", group: nil, parameters: [:], value: until)
            return timezones.date(for: property).map { $0.date.addingTimeInterval(50_400) }
        }
        guard let countText = parts["COUNT"], let count = Double(countText) else { return nil }
        let interval = Double(parts["INTERVAL"] ?? "1") ?? 1
        let period: TimeInterval
        switch parts["FREQ"]?.uppercased() {
        case "SECONDLY": period = 1
        case "MINUTELY": period = 60
        case "HOURLY": period = 3_600
        case "DAILY": period = 86_400
        case "WEEKLY": period = 7 * 86_400
        case "MONTHLY": period = 31 * 86_400
        case "YEARLY": period = 366 * 86_400
        default: return nil
        }
        // BY* rules can skip whole periods (the 31st of a month, February 29th), so they get
        // a generous multiplier; the bound only needs to be safe, not tight.
        let hasByRules = parts.keys.contains { $0.hasPrefix("BY") }
        let factor: Double = hasByRules ? 4 : 1
        let seconds = min(count * interval * period * factor, 200 * 366 * 86_400)
        return start.addingTimeInterval(seconds + 86_400)
    }

    public static func parseDuration(_ text: String) -> TimeInterval? {
        var value = text.trimmingCharacters(in: .whitespaces).uppercased()
        var sign: Double = 1
        if value.hasPrefix("-") { sign = -1; value.removeFirst() } else if value.hasPrefix("+") { value.removeFirst() }
        guard value.hasPrefix("P") else { return nil }
        value.removeFirst()
        var total: TimeInterval = 0
        var number = ""
        var inTime = false
        for character in value {
            if character == "T" { inTime = true; continue }
            if character.isNumber { number.append(character); continue }
            guard let amount = Double(number) else { return nil }
            number = ""
            switch (character, inTime) {
            case ("W", _): total += amount * 7 * 86_400
            case ("D", _): total += amount * 86_400
            case ("H", true): total += amount * 3_600
            case ("M", true): total += amount * 60
            case ("S", true): total += amount
            default: return nil
            }
        }
        return number.isEmpty ? sign * total : nil
    }

    // MARK: Export

    /// Merges several calendar object resources into one VCALENDAR for export, keeping one
    /// copy of each VTIMEZONE.
    public static func merge(_ resources: [Data], name: String) -> String {
        var merged = ContentComponent(name: "VCALENDAR")
        merged.properties = [
            ContentProperty(name: "VERSION", group: nil, parameters: [:], value: "2.0"),
            ContentProperty(name: "PRODID", group: nil, parameters: [:], value: "-//CalShare//CalShare 1.0//EN"),
            ContentProperty(name: "X-WR-CALNAME", group: nil, parameters: [:], value: name),
        ]
        var seenZones = Set<String>()
        for data in resources {
            guard let text = String(data: data, encoding: .utf8),
                  let calendar = try? parseCalendar(text) else { continue }
            for child in calendar.children {
                if child.name == "VTIMEZONE" {
                    let id = child.property("TZID")?.value ?? ""
                    guard seenZones.insert(id).inserted else { continue }
                }
                merged.children.append(child)
            }
        }
        // Time zones first, as most importers expect.
        merged.children.sort { ($0.name == "VTIMEZONE" ? 0 : 1) < ($1.name == "VTIMEZONE" ? 0 : 1) }
        return ContentLineParser.serialize(merged)
    }

    /// Splits an imported .ics file into one resource per UID.
    public static func split(_ text: String) throws(CalendarValidationError) -> [(uid: String, data: Data)] {
        let calendar = try parseCalendar(text)
        let zones = calendar.children.filter { $0.name == "VTIMEZONE" }
        var groups: [String: [ContentComponent]] = [:]
        var order: [String] = []
        for child in calendar.children where objectComponents.contains(child.name) {
            let uid = child.property("UID")?.value ?? UUID().uuidString
            if groups[uid] == nil { order.append(uid) }
            groups[uid, default: []].append(child)
        }
        return order.map { uid in
            var resource = ContentComponent(name: "VCALENDAR")
            resource.properties = calendar.properties.filter { $0.name != "METHOD" && !$0.name.hasPrefix("X-WR") }
            if !resource.properties.contains(where: { $0.name == "VERSION" }) {
                resource.properties.insert(ContentProperty(name: "VERSION", group: nil, parameters: [:], value: "2.0"), at: 0)
            }
            if !resource.properties.contains(where: { $0.name == "PRODID" }) {
                resource.properties.append(ContentProperty(name: "PRODID", group: nil, parameters: [:], value: "-//CalShare//CalShare 1.0//EN"))
            }
            var members = groups[uid] ?? []
            if members.first?.property("UID") == nil {
                members = members.map { var c = $0; c.properties.append(ContentProperty(name: "UID", group: nil, parameters: [:], value: uid)); return c }
            }
            let usedZones = Set(members.flatMap { $0.properties.compactMap { $0.parameter("TZID") } })
            resource.children = zones.filter { usedZones.contains($0.property("TZID")?.value ?? "") } + members
            return (uid, Data(ContentLineParser.serialize(resource).utf8))
        }
    }
}

// MARK: - Dates

struct ParsedDate {
    var date: Date
    var isDateOnly: Bool
    /// Floating local time, or a TZID we could not resolve.
    var isFloating: Bool
}

/// Resolves DATE / DATE-TIME values. TZIDs are looked up as Olson identifiers (what Apple's
/// clients send); a TZID defined only by a custom VTIMEZONE falls back to its standard
/// offset, and failing that is treated as floating.
struct TimeZoneResolver {
    private var offsets: [String: Int] = [:]

    init(calendar: ContentComponent) {
        for zone in calendar.children where zone.name == "VTIMEZONE" {
            guard let id = zone.property("TZID")?.value else { continue }
            if let standard = zone.children.first(where: { $0.name == "STANDARD" }) ?? zone.children.first,
               let offset = standard.property("TZOFFSETTO")?.value, let seconds = Self.parseOffset(offset) {
                offsets[id] = seconds
            }
        }
    }

    static func parseOffset(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard digits.count >= 5, let sign = digits.first, sign == "+" || sign == "-" else { return nil }
        let body = Array(digits.dropFirst())
        guard let hours = Int(String(body[0..<2])), let minutes = Int(String(body[2..<4])) else { return nil }
        var seconds = hours * 3600 + minutes * 60
        if body.count >= 6, let extra = Int(String(body[4..<6])) { seconds += extra }
        return sign == "-" ? -seconds : seconds
    }

    func date(for property: ContentProperty) -> ParsedDate? {
        let raw = property.value.trimmingCharacters(in: .whitespaces)
        let isDate = property.parameter("VALUE")?.uppercased() == "DATE" || (raw.count == 8 && !raw.contains("T"))
        var components = DateComponents()
        let chars = Array(raw)
        guard chars.count >= 8, let year = Int(String(chars[0..<4])), let month = Int(String(chars[4..<6])),
              let day = Int(String(chars[6..<8])) else { return nil }
        components.year = year; components.month = month; components.day = day
        var utc = false
        if !isDate {
            guard chars.count >= 15, chars[8] == "T", let hour = Int(String(chars[9..<11])),
                  let minute = Int(String(chars[11..<13])), let second = Int(String(chars[13..<15])) else { return nil }
            components.hour = hour; components.minute = minute; components.second = min(second, 59)
            utc = chars.count >= 16 && chars[15] == "Z"
        }
        var calendar = Calendar(identifier: .gregorian)
        var floating = false
        if utc {
            calendar.timeZone = TimeZone(identifier: "UTC")!
        } else if !isDate, let tzid = property.parameter("TZID") {
            let cleaned = tzid.hasPrefix("/") ? String(tzid.dropFirst()) : tzid
            if let zone = TimeZone(identifier: cleaned) {
                calendar.timeZone = zone
            } else if let offset = offsets[tzid], let zone = TimeZone(secondsFromGMT: offset) {
                calendar.timeZone = zone
            } else {
                calendar.timeZone = TimeZone(identifier: "UTC")!
                floating = true
            }
        } else {
            calendar.timeZone = TimeZone(identifier: "UTC")!
            floating = true
        }
        guard let date = calendar.date(from: components) else { return nil }
        return ParsedDate(date: date, isDateOnly: isDate, isFloating: floating)
    }

    /// Parses a bare UTC value like 20261009T120000Z (used by time-range filters).
    static func utcDate(_ text: String) -> Date? {
        let resolver = TimeZoneResolver(calendar: ContentComponent(name: "VCALENDAR"))
        return resolver.date(for: ContentProperty(name: "X", group: nil, parameters: [:], value: text))?.date
    }
}
