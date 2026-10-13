import CryptoKit
import Foundation

/// Why a plugin was refused, or why its run failed. The text is LensWorks's own; a plugin's strings appear in it
/// only after they passed the manifest's checks.
nonisolated struct LensWorksPluginFailure: LocalizedError, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

/// A plugin package's `plugin.json`: who the plugin is, the filter interface it was built for and the parameters it
/// declares. Everything in it is untrusted until `init(data:)` has checked it (docs/PLUGINS.md).
nonisolated struct LensWorksPluginManifest: Equatable, Sendable {
    enum Kind: String, Sendable { case number, integer, boolean, choice }
    struct Parameter: Equatable, Sendable {
        let name: String
        let label: String
        let kind: Kind
        let minimum: Double?
        let maximum: Double?
        let choices: [String]
        /// The default as the plugin receives it: the number, 0 or 1 for a boolean, or a choice's index.
        let defaultValue: Double
    }
    let interface: Int
    let id: String
    let name: String
    let version: String
    let parameters: [Parameter]

    static let fileName = "plugin.json", moduleName = "filter.wasm"
    static let maximumBytes = 64 * 1024
    static let nameLimit = 40, idLimit = 64, versionLimit = 32, choiceLimit = 32
    /// The largest magnitude a numeric parameter's range or default may have.
    static let magnitudeLimit = 1e9
    /// Argument names every plugin command already has.
    static let reservedParameterNames: Set<String> = ["layer", "plugin"]

    /// The id an agent names: `plugin.run.` then the plugin's id. A plugin id always holds a dot, so this never
    /// collides with a built-in command id.
    var commandName: String { LensWorksCommandRegistry.pluginCommandPrefix + id }
    /// The Filter › Plugins item: the plugin's name with its id alongside, so a name alone never identifies it.
    var menuTitle: String { "\(name) (\(id))" + (parameters.isEmpty ? "" : "…") }
    /// The history entry a run leaves. The prefix keeps it apart from every built-in entry.
    var historyName: String { "Plugin: " + name }
    var defaults: [Double] { parameters.map(\.defaultValue) }

    private static func refuse(_ reason: String) -> LensWorksPluginFailure { .init("The plugin’s manifest was refused: " + reason) }

    /// Display text a plugin supplies: ASCII letters, digits, spaces and `-_.&+'`, no leading or trailing space,
    /// no doubled space, at most `nameLimit` characters. Nothing that could read as a disabled reason (“ — ”), a
    /// dialog ellipsis, an “(Agent)” label or another script's look-alike letters gets through.
    static func isDisplayText(_ text: String) -> Bool {
        guard (1...nameLimit).contains(text.unicodeScalars.count), text.first != " ", text.last != " ", !text.contains("  ") else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || " -_.&+'".unicodeScalars.contains(scalar))
        }
    }
    /// Lowercase letters and digits in at least two parts joined by `.` or `-`, with at least one dot.
    static func isIdentifier(_ text: String) -> Bool {
        guard (3...idLimit).contains(text.utf8.count), text.contains(".") else { return false }
        let parts = text.split(omittingEmptySubsequences: false) { $0 == "." || $0 == "-" }
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { $0.isASCII && (("a"..."z").contains(Character($0)) || ("0"..."9").contains(Character($0))) }
        }
    }
    static func isParameterName(_ text: String) -> Bool {
        guard (1...32).contains(text.utf8.count), let first = text.unicodeScalars.first, first.isASCII, ("a"..."z").contains(Character(first)) else { return false }
        return text.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }
    /// Every title and label a built-in command shows, lowercased without its ellipsis: names a plugin may not take.
    static let builtInNames: Set<String> = Set(LensWorksCommandRegistry.descriptors.flatMap { [$0.label] + $0.titles }
        .map { $0.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces).lowercased() })

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              abs(number.doubleValue) <= magnitudeLimit else { return nil }
        return number.doubleValue
    }
    private static func keys(_ object: [String: Any], required: Set<String>, optional: Set<String> = [], in what: String) throws {
        if let missing = required.subtracting(object.keys).sorted().first { throw refuse("\(what) has no “\(missing)”.") }
        if object.keys.contains(where: { !required.contains($0) && !optional.contains($0) }) {
            throw refuse("\(what) has a key the manifest format does not define. Its keys are: " + required.union(optional).sorted().joined(separator: ", ") + ".")
        }
    }

    /// Reads and checks a manifest. `maximumParameters` is the runtime's own limit.
    init(data: Data, maximumParameters: Int = Int(LensWorksPluginSandbox.limits.parameters),
         interfaceVersion: Int = Int(LensWorksPluginSandbox.limits.interface_version)) throws {
        guard data.count <= Self.maximumBytes else { throw Self.refuse("it is over \(Self.maximumBytes) bytes.") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Self.refuse("it is not a JSON object.") }
        try Self.keys(object, required: ["interface", "id", "name", "version", "parameters"], in: "it")
        guard let interface = Self.number(object["interface"]), interface == interface.rounded() else { throw Self.refuse("“interface” must be a whole number.") }
        guard Int(interface) == interfaceVersion else {
            throw Self.refuse("it was built for filter interface \(Int(interface)); this LensWorks provides interface \(interfaceVersion).")
        }
        guard let id = object["id"] as? String, Self.isIdentifier(id) else {
            throw Self.refuse("“id” must be lowercase letters and digits in parts joined by dots or hyphens, with at least one dot, at most \(Self.idLimit) bytes (for example com.example.invert).")
        }
        guard let name = object["name"] as? String, Self.isDisplayText(name) else {
            throw Self.refuse("“name” must be 1 to \(Self.nameLimit) ASCII letters, digits, spaces or - _ . & + ' with no space at either end.")
        }
        guard !Self.builtInNames.contains(name.lowercased()) else { throw Self.refuse("“name” is the name of a built-in LensWorks command.") }
        guard let version = object["version"] as? String, (1...Self.versionLimit).contains(version.utf8.count),
              version.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".+-".unicodeScalars.contains($0)) }) else {
            throw Self.refuse("“version” must be 1 to \(Self.versionLimit) ASCII letters, digits, dots, plus or hyphen characters.")
        }
        guard let list = object["parameters"] as? [Any], list.count <= maximumParameters else {
            throw Self.refuse("“parameters” must be a list of at most \(maximumParameters) parameters.")
        }
        var parameters: [Parameter] = []
        for (index, entry) in list.enumerated() {
            let what = "parameter \(index + 1)"
            guard let entry = entry as? [String: Any] else { throw Self.refuse("\(what) is not an object.") }
            guard let kind = (entry["type"] as? String).flatMap(Kind.init(rawValue:)) else { throw Self.refuse("\(what) needs “type”: number, integer, boolean or choice.") }
            let ranged = kind == .number || kind == .integer
            try Self.keys(entry, required: Set(["name", "label", "type", "default"] + (ranged ? ["minimum", "maximum"] : kind == .choice ? ["choices"] : [])), in: what)
            guard let name = entry["name"] as? String, Self.isParameterName(name), !Self.reservedParameterNames.contains(name) else {
                throw Self.refuse("\(what) needs a “name” of 1 to 32 ASCII letters and digits starting with a lowercase letter, other than layer or plugin.")
            }
            guard !parameters.contains(where: { $0.name == name }) else { throw Self.refuse("two parameters are named “\(name)”.") }
            guard let label = entry["label"] as? String, Self.isDisplayText(label) else {
                throw Self.refuse("\(what) needs a “label” of 1 to \(Self.nameLimit) ASCII letters, digits, spaces or - _ . & + '.")
            }
            switch kind {
            case .number, .integer:
                guard let minimum = Self.number(entry["minimum"]), let maximum = Self.number(entry["maximum"]), minimum < maximum,
                      let value = Self.number(entry["default"]), (minimum...maximum).contains(value) else {
                    throw Self.refuse("\(what) needs finite “minimum” < “maximum” within ±1e9 and a “default” between them.")
                }
                if kind == .integer, [minimum, maximum, value].contains(where: { $0 != $0.rounded() }) { throw Self.refuse("\(what) is an integer: its range and default must be whole numbers.") }
                parameters.append(.init(name: name, label: label, kind: kind, minimum: minimum, maximum: maximum, choices: [], defaultValue: value))
            case .boolean:
                guard let value = entry["default"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw Self.refuse("\(what) is a boolean: its “default” must be true or false.") }
                parameters.append(.init(name: name, label: label, kind: kind, minimum: nil, maximum: nil, choices: [], defaultValue: value.boolValue ? 1 : 0))
            case .choice:
                guard let choices = entry["choices"] as? [String], (2...Self.choiceLimit).contains(choices.count), Set(choices).count == choices.count,
                      choices.allSatisfy(Self.isDisplayText) else {
                    throw Self.refuse("\(what) needs 2 to \(Self.choiceLimit) different “choices”, each 1 to \(Self.nameLimit) ASCII letters, digits, spaces or - _ . & + '.")
                }
                guard let chosen = entry["default"] as? String, let position = choices.firstIndex(of: chosen) else { throw Self.refuse("\(what)’s “default” must be one of its choices.") }
                parameters.append(.init(name: name, label: label, kind: kind, minimum: nil, maximum: nil, choices: choices, defaultValue: Double(position)))
            }
        }
        self.interface = Int(interface); self.id = id; self.name = name; self.version = version; self.parameters = parameters
    }

    /// The registered parameters of this plugin's command: what the agent's schema lists and its arguments are
    /// checked against, type and range, exactly as every built-in command's are.
    var commandParameters: [LensWorksCommandParameter] {
        parameters.map { parameter in
            let note = " A parameter of the plugin \(id)."
            switch parameter.kind {
            case .number:
                return .init(name: parameter.name, type: .number, description: "\(parameter.label), from \(Self.plain(parameter.minimum!)) through \(Self.plain(parameter.maximum!)); defaults to \(Self.plain(parameter.defaultValue))." + note,
                             minimum: parameter.minimum, maximum: parameter.maximum)
            case .integer:
                return .init(name: parameter.name, type: .integer, description: "\(parameter.label), a whole number from \(Self.plain(parameter.minimum!)) through \(Self.plain(parameter.maximum!)); defaults to \(Self.plain(parameter.defaultValue))." + note,
                             minimum: parameter.minimum, maximum: parameter.maximum)
            case .boolean:
                return .init(name: parameter.name, type: .boolean, description: "\(parameter.label); defaults to \(parameter.defaultValue == 1)." + note)
            case .choice:
                return .init(name: parameter.name, type: .choice, description: "\(parameter.label). One of: " + parameter.choices.joined(separator: ", ") + "; defaults to \(parameter.choices[Int(parameter.defaultValue)])." + note,
                             choices: parameter.choices)
            }
        }
    }
    static func plain(_ value: Double) -> String { value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value) }

    /// The values the plugin receives, in declared order, from checked agent arguments (defaults where none given).
    func values(from arguments: LensWorksAgentArguments) throws -> [Double] {
        try parameters.map { parameter in
            switch parameter.kind {
            case .number: return try arguments.double(parameter.name) ?? parameter.defaultValue
            case .integer: return try arguments.integer(parameter.name).map(Double.init) ?? parameter.defaultValue
            case .boolean: return try arguments.bool(parameter.name).map { $0 ? 1 : 0 } ?? parameter.defaultValue
            case .choice:
                guard let chosen = try arguments.string(parameter.name) else { return parameter.defaultValue }
                guard let position = parameter.choices.firstIndex(of: chosen) else { throw LensWorksCommandRefusal(reason: "\(parameter.name) must be one of: " + parameter.choices.joined(separator: ", ") + ".") }
                return Double(position)
            }
        }
    }
    /// Whether `values` is one value per parameter, each finite and inside its declared range.
    func admits(_ values: [Double]) -> Bool {
        values.count == parameters.count && zip(parameters, values).allSatisfy { parameter, value in
            guard value.isFinite else { return false }
            switch parameter.kind {
            case .number: return (parameter.minimum!...parameter.maximum!).contains(value)
            case .integer: return (parameter.minimum!...parameter.maximum!).contains(value) && value == value.rounded()
            case .boolean: return value == 0 || value == 1
            case .choice: return value == value.rounded() && (0..<Double(parameter.choices.count)).contains(value)
            }
        }
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
