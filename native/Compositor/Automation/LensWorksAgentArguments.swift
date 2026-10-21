import CoreGraphics
import Foundation

/// The arguments an agent passed for one command, checked against the command's registered parameters. Every
/// accessor refuses a value of the wrong shape; a name the command does not declare was refused before this exists.
struct LensWorksAgentArguments {
    let id: LensWorksCommandID
    let values: [String: Any]
    /// The path arguments, resolved to the real file inside a granted folder each one reaches.
    var paths: [String: [URL]] = [:]

    static let textLimit = 16_384

    private func refusal(_ name: String, _ shape: String) -> LensWorksCommandRefusal { .init(reason: "\(name) must be \(shape).") }
    func has(_ name: String) -> Bool { if let value = values[name] { !(value is NSNull) } else { false } }

    /// A JSON number that is not a boolean (JSONSerialization bridges both to NSNumber).
    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }
    func double(_ name: String) throws -> Double? {
        guard has(name) else { return nil }
        guard let value = Self.number(values[name])?.doubleValue, value.isFinite else { throw refusal(name, "a finite number") }
        return value
    }
    func integer(_ name: String) throws -> Int? {
        guard has(name) else { return nil }
        guard let number = Self.number(values[name]), number.doubleValue.isFinite, number.doubleValue == number.doubleValue.rounded(),
              abs(number.doubleValue) < 9e15 else { throw refusal(name, "a whole number") }
        return number.intValue
    }
    func bool(_ name: String) throws -> Bool? {
        guard has(name) else { return nil }
        guard let number = values[name] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw refusal(name, "true or false") }
        return number.boolValue
    }
    func string(_ name: String) throws -> String? {
        guard has(name) else { return nil }
        guard let value = values[name] as? String, value.utf8.count <= Self.textLimit, !value.contains("\0") else {
            throw refusal(name, "a string of at most \(Self.textLimit) bytes")
        }
        return value
    }
    func strings(_ name: String) throws -> [String]? {
        guard has(name) else { return nil }
        if let one = values[name] as? String { return [one] }
        guard let list = values[name] as? [String], list.count <= 1024, list.allSatisfy({ $0.utf8.count <= Self.textLimit }) else {
            throw refusal(name, "a list of at most 1,024 strings")
        }
        return list
    }
    func uuid(_ name: String) throws -> UUID? {
        guard let text = try string(name) else { return nil }
        guard let id = UUID(uuidString: text) else {
            if name == "layer" || name == "primary" { throw LensWorksCommandRefusal(reason: "\(text.prefix(64)) is not a layer id.") }
            throw refusal(name, "a UUID")
        }
        return id
    }
    func uuids(_ name: String) throws -> [UUID]? {
        try strings(name)?.map {
            guard let id = UUID(uuidString: $0) else { throw LensWorksCommandRefusal(reason: "\($0.prefix(64)) is not a layer id.") }
            return id
        }
    }
    func color(_ name: String) throws -> PaletteColor? {
        guard let text = try string(name) else { return nil }
        guard text.count == 7, text.hasPrefix("#"), text.dropFirst().allSatisfy(\.isHexDigit), let color = PaletteColor(hex: text) else {
            throw refusal(name, "an sRGB color written #RRGGBB")
        }
        return color
    }
    func object(_ name: String) throws -> [String: Any]? {
        guard has(name) else { return nil }
        guard let value = values[name] as? [String: Any] else { throw refusal(name, "an object") }
        return value
    }
    func required<T>(_ name: String, _ value: T?) throws -> T {
        guard let value else { throw LensWorksCommandRefusal(reason: "\(id.rawValue) needs \(name).") }
        return value
    }
    func url(_ name: String) throws -> URL { try required(name, paths[name]?.first) }

    /// Checks `values` against the command's registered parameters: no undeclared name, every required one present,
    /// each of its declared type, range and choices.
    static func check(_ values: [String: Any], for descriptor: LensWorksCommandDescriptor) throws -> LensWorksAgentArguments {
        try LensWorksAgentTools.rejectUnknown(values, allowed: descriptor.parameters.map(\.name), in: descriptor.id.rawValue)
        guard isBounded(values) else {
            throw LensWorksCommandRefusal(reason: "Every number in the arguments must be finite, and lists and objects at most \(nestingLimit) levels deep.")
        }
        let arguments = LensWorksAgentArguments(id: descriptor.id, values: values)
        for parameter in descriptor.parameters {
            let name = parameter.name
            guard arguments.has(name) else {
                if parameter.required { throw LensWorksCommandRefusal(reason: "\(descriptor.id.rawValue) needs \(name): \(parameter.description)") }
                continue
            }
            var numeric: Double?
            switch parameter.type {
            case .uuid: _ = try arguments.uuid(name)
            case .uuidArray: _ = try arguments.uuids(name)
            case .optionalBoolean, .boolean: _ = try arguments.bool(name)
            // The app's own admission words the range refusal for a 0–1 value, as it does for the menus.
            case .unitInterval:
                guard arguments.values[name] is NSNumber, (try? arguments.double(name)) != nil else { throw LensWorksCommandRefusal(reason: "\(name) must be a number from 0 through 1.") }
            case .exposure, .number: numeric = try arguments.double(name)
            case .cursor, .rating, .integer: numeric = try arguments.integer(name).map(Double.init)
            case .layerName, .catalogCopyName, .variant, .reference, .text, .path: _ = try arguments.string(name)
            case .color: _ = try arguments.color(name)
            case .referenceArray, .pathArray: _ = try arguments.strings(name)
            case .choice:
                let value = try arguments.string(name) ?? ""
                guard parameter.choices?.contains(value) != false else {
                    throw LensWorksCommandRefusal(reason: "\(name) must be one of: " + (parameter.choices ?? []).joined(separator: ", ") + ".")
                }
            case .expectedVersion:
                let expected = try arguments.object(name) ?? [:]
                try LensWorksAgentTools.rejectUnknown(expected, allowed: LensWorksAgentTools.expectedProperties, in: name)
                // A value of the wrong type is refused: it must never read as "no guard given".
                let guarded = LensWorksAgentArguments(id: descriptor.id, values: expected)
                if guarded.has("variantId"), (try? guarded.string("variantId")) == nil { throw LensWorksCommandRefusal(reason: "\(name).variantId must be a string.") }
                if guarded.has("revision"), (try? guarded.integer("revision")) == nil { throw LensWorksCommandRefusal(reason: "\(name).revision must be a whole number.") }
            case .settings: _ = try arguments.object(name)
            }
            if let numeric {
                let low = parameter.minimum ?? (parameter.type == .rating ? 0 : nil)
                let high = parameter.maximum ?? (parameter.type == .rating ? 5 : nil)
                if let low, numeric < low { throw LensWorksCommandRefusal(reason: "\(name) must be at least \(Self.plain(low)).") }
                if let high, numeric > high { throw LensWorksCommandRefusal(reason: "\(name) must be at most \(Self.plain(high)).") }
            }
        }
        return arguments
    }
    /// The deepest lists and objects an argument may nest.
    static let nestingLimit = 8
    /// Whether every number anywhere in `value` is finite and nothing nests deeper than `nestingLimit`. A number
    /// that is not finite cannot be written back as JSON, and nothing an agent sends is trusted to be.
    static func isBounded(_ value: Any, depth: Int = 0) -> Bool {
        switch value {
        case let object as [String: Any]: return depth < nestingLimit && object.values.allSatisfy { isBounded($0, depth: depth + 1) }
        case let list as [Any]: return depth < nestingLimit && list.allSatisfy { isBounded($0, depth: depth + 1) }
        case let number as NSNumber: return number.doubleValue.isFinite
        default: return true
        }
    }
    static func plain(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
}

/// JSON schemas for the agent, generated from the registry's parameters: the registry is the one description.
enum LensWorksAgentSchema {
    static func schema(for parameter: LensWorksCommandParameter, command: LensWorksCommandID) -> [String: Any] {
        var schema: [String: Any]
        switch parameter.type {
        case .uuid: schema = ["type": "string", "format": "uuid"]
        case .uuidArray: schema = ["type": "array", "items": ["type": "string", "format": "uuid"]]
        case .optionalBoolean: schema = ["type": ["boolean", "null"]]
        case .boolean: schema = ["type": "boolean"]
        case .unitInterval: schema = ["type": "number", "minimum": 0, "maximum": 1]
        case .exposure, .number: schema = ["type": "number"]
        case .cursor, .integer: schema = ["type": "integer"]
        case .rating: schema = ["type": "integer", "minimum": 0, "maximum": 5]
        case .layerName: schema = ["type": "string", "minLength": 1]
        case .catalogCopyName: schema = ["type": "string", "minLength": 1, "maxLength": 1024]
        case .variant, .reference, .text: schema = ["type": "string"]
        case .color: schema = ["type": "string", "pattern": "^#[0-9A-Fa-f]{6}$"]
        case .path: schema = ["type": "string", "maxLength": LensWorksGrantedFolders.pathLimit]
        case .referenceArray: schema = ["type": "array", "items": ["type": "string"]]
        case .pathArray: schema = ["type": "array", "minItems": 1, "items": ["type": "string", "maxLength": LensWorksGrantedFolders.pathLimit]]
        case .choice: schema = ["type": "string", "enum": parameter.choices ?? []]
        case .expectedVersion:
            schema = ["type": "object", "properties": ["variantId": ["type": "string"], "revision": ["type": "integer"]], "additionalProperties": false]
        case .settings: schema = LensWorksAgentSettings.schema(for: command)
        }
        if let minimum = parameter.minimum { schema["minimum"] = minimum }
        if let maximum = parameter.maximum { schema["maximum"] = maximum }
        schema["description"] = parameter.description
        return schema
    }
    /// The JSON schema of a command's arguments.
    static func inputSchema(_ id: LensWorksCommandID) -> [String: Any] {
        let descriptor = LensWorksCommandRegistry.descriptor(id)
        guard descriptor.agent.isRunnable else { return ["type": "object", "properties": [String: Any](), "additionalProperties": false] }
        var properties: [String: Any] = [:]
        for parameter in descriptor.parameters { properties[parameter.name] = schema(for: parameter, command: id) }
        return ["type": "object", "properties": properties, "required": descriptor.parameters.filter(\.required).map(\.name), "additionalProperties": false]
    }
}

/// The `settings` object of a dialog command. Each is the dialog's own Codable settings type: its default value is
/// the schema, an agent's object overrides only the keys it names, and a key the type does not have is refused.
enum LensWorksAgentSettings {
    /// The top-level `FilterSettings` keys each filter reads.
    static func keys(_ kind: FilterKind) -> [String] {
        switch kind {
        case .gaussianBlur: ["radius"]
        case .motionBlur: ["angle", "distance"]
        case .addNoise: ["amount", "gaussian", "monochromatic"]
        case .vignette: ["vignetteAmount", "vignetteColor", "vignetteMidpoint", "vignetteRoundness", "vignetteFeather", "vignetteHighlights"]
        case .bloomGlow: ["bloomAmount", "bloomRadius"]
        case .dither: ["dither"]
        case .tonalContrast: ["tonalAmount", "tonalRadius", "tonalShadows", "tonalMidtones", "tonalHighlights"]
        case .lensCorrection: ["distortion"]
        case .cameraRaw: ["cameraRaw"]
        case .removeBackground: ["backgroundQuality", "refineEdges", "matteContrast", "shiftEdge"]
        case .contentAwareFill: []
        case .curves: ["curves"]
        case .exposure: ["exposure"]
        case .gradientMap: ["gradientMap"]
        case .grain: ["grain"]
        case .blackWhite: ["blackWhite"]
        case .colorBalance: ["colorBalance"]
        }
    }
    /// The `LayerEffects` key each effect is stored under.
    static func key(_ kind: LayerEffectKind) -> String {
        switch kind {
        case .stroke: "stroke"
        case .shadow: "shadow"
        case .colorOverlay: "colorOverlay"
        case .innerShadow: "innerShadow"
        case .outerGlow: "outerGlow"
        case .innerGlow: "innerGlow"
        }
    }

    static func json<T: Encodable>(_ value: T) -> [String: Any] {
        ((try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    /// A JSON schema describing `value`'s shape: the keys it has and the type of each.
    static func describe(_ value: Any) -> [String: Any] {
        switch value {
        case let object as [String: Any]:
            return ["type": "object", "properties": object.mapValues(describe), "additionalProperties": false]
        case let list as [Any]:
            return list.first.map { ["type": "array", "items": describe($0)] } ?? ["type": "array"]
        case let number as NSNumber:
            return ["type": CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number"]
        case is String: return ["type": "string"]
        default: return [:]
        }
    }

    /// The settings object an agent passes for one filter: the filter's own keys. A filter whose settings are one
    /// group (Curves, Exposure, Camera Raw…) takes that group's keys directly.
    static func filterBase(_ kind: FilterKind, _ settings: FilterSettings = FilterSettings()) -> [String: Any] {
        let all = json(settings), names = keys(kind)
        if names.count == 1, let group = all[names[0]] as? [String: Any] { return group }
        return all.filter { names.contains($0.key) }
    }
    /// `settings` with an agent's overrides for `kind` applied.
    static func filterMerged(_ kind: FilterKind, _ settings: FilterSettings, _ overrides: [String: Any]?) throws -> FilterSettings {
        guard let overrides, !overrides.isEmpty else { return settings }
        var all = json(settings)
        let names = keys(kind), base = filterBase(kind, settings)
        if let stray = overrides.keys.sorted().first(where: { base[$0] == nil }) {
            throw LensWorksCommandRefusal(reason: "Unknown setting “\(stray.prefix(64))” for \(kind.rawValue). " + (base.isEmpty ? "It takes no settings." : "Its settings are: " + base.keys.sorted().joined(separator: ", ") + "."))
        }
        let changed = try overlay(base, overrides)
        if names.count == 1, all[names[0]] is [String: Any] { all[names[0]] = changed } else { all.merge(changed) { $1 } }
        let merged: FilterSettings = try decoded(all)
        try check(kind, merged)
        return merged
    }
    static let outside = "settings holds a value outside what that setting accepts."
    /// Refuses settings the filter's dialog could never produce: a value its sliders clamp or repair (so the
    /// settings differ from their normalized form), or a curve, mixer or guide list of a shape the renderer does
    /// not expect. Decoding alone admits these; the renderer indexes fixed-size lists without checking.
    static func check(_ kind: FilterKind, _ settings: FilterSettings) throws {
        let valid: Bool
        switch kind {
        case .curves: valid = settings.curves.isValid
        case .blackWhite: valid = settings.blackWhite.isValid
        case .colorBalance: valid = settings.colorBalance.isValid
        case .exposure: valid = settings.exposure.isValid
        case .gradientMap: valid = settings.gradientMap.isValid
        case .grain: valid = settings.grain.isValid
        case .cameraRaw:
            let raw = settings.cameraRaw
            valid = raw.isValid && [raw.mixer.hue, raw.mixer.saturation, raw.mixer.luminance].allSatisfy { $0.count == CameraRawMixerSettings.names.count }
        default: valid = true
        }
        guard valid, NSDictionary(dictionary: filterBase(kind, settings)).isEqual(to: filterBase(kind, settings.normalized)) else {
            throw LensWorksCommandRefusal(reason: outside)
        }
    }
    /// Refuses Levels settings the dialog could never produce: the renderer indexes all four channel ranges.
    static func check(_ settings: LevelsSettings) throws {
        guard settings.ranges.count == LevelsChannel.allCases.count, settings.ranges.allSatisfy({ $0 == $0.normalized }) else {
            throw LensWorksCommandRefusal(reason: outside)
        }
    }
    /// Levels settings with an agent's overrides applied.
    static func levelsMerged(_ base: LevelsSettings, _ overrides: [String: Any]?) throws -> LevelsSettings {
        let merged = try merged(base, overrides)
        try check(merged)
        return merged
    }
    private static func decoded<T: Decodable>(_ object: [String: Any]) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object)) }
        catch { throw LensWorksCommandRefusal(reason: "settings could not be read: a value is outside what that setting accepts.") }
    }

    /// Hue/Saturation as an agent passes it: the sliders of one color range.
    static let hueKeys = ["range", "hue", "saturation", "lightness", "colorize", "invertRange"]
    static var hueSchema: [String: Any] {
        ["type": "object", "additionalProperties": false, "properties": [
            "range": ["type": "string", "enum": ColorRange.allCases.map(\.rawValue), "description": "The color range the sliders change; defaults to Master."],
            "hue": ["type": "number", "minimum": -180, "maximum": 180], "saturation": ["type": "number", "minimum": -100, "maximum": 100],
            "lightness": ["type": "number", "minimum": -100, "maximum": 100], "colorize": ["type": "boolean"], "invertRange": ["type": "boolean"]]]
    }
    static func hueMerged(_ base: HueSaturationSettings, _ overrides: [String: Any]?) throws -> HueSaturationSettings {
        guard let overrides, !overrides.isEmpty else { return base }
        if let stray = overrides.keys.sorted().first(where: { !hueKeys.contains($0) }) {
            throw LensWorksCommandRefusal(reason: "Unknown setting “\(stray.prefix(64))” for Hue/Saturation. Its settings are: " + hueKeys.sorted().joined(separator: ", ") + ".")
        }
        let arguments = LensWorksAgentArguments(id: .hueSaturation, values: overrides)
        var settings = base
        if let name = try arguments.string("range") {
            guard let range = ColorRange(rawValue: name) else { throw LensWorksCommandRefusal(reason: "range must be one of: " + ColorRange.allCases.map(\.rawValue).joined(separator: ", ") + ".") }
            settings.range = range
        }
        func value(_ name: String, _ limit: Double) throws -> Double? {
            guard let value = try arguments.double(name) else { return nil }
            guard abs(value) <= limit else { throw LensWorksCommandRefusal(reason: "\(name) must be from \(Int(-limit)) through \(Int(limit)).") }
            return value
        }
        if let hue = try value("hue", 180) { settings.hue = hue }
        if let saturation = try value("saturation", 100) { settings.saturation = saturation }
        if let lightness = try value("lightness", 100) { settings.lightness = lightness }
        if let colorize = try arguments.bool("colorize") { settings.colorize = colorize }
        if let invert = try arguments.bool("invertRange") { settings.invertRange = invert }
        return settings
    }

    /// The settings an agent passes for an adjustment layer: the same object its kind's dialog command takes.
    static func adjustmentBase(_ kind: AdjustmentKind) -> [String: Any]? {
        switch kind {
        case .invert: nil
        case .levels: json(LevelsSettings())
        case .hsv: nil
        default: kind.filterKind.map { filterBase($0) }
        }
    }
    static func adjustmentMerged(_ adjustment: LayerAdjustment, _ overrides: [String: Any]?) throws -> LayerAdjustment {
        guard let overrides, !overrides.isEmpty else { return adjustment }
        var value = adjustment
        switch adjustment.kind {
        case .invert: throw LensWorksCommandRefusal(reason: "An Invert adjustment has no settings.")
        case .levels: value.levels = try levelsMerged(adjustment.levels, overrides)
        case .hsv: value.hsvSettings = try hueMerged(adjustment.resolvedHSV, overrides)
        default:
            guard let kind = adjustment.kind.filterKind else { throw LensWorksCommandRefusal(reason: "That adjustment has no settings.") }
            var settings = FilterSettings()
            settings.curves = adjustment.curves; settings.exposure = adjustment.exposure; settings.gradientMap = adjustment.gradientMap
            settings.grain = adjustment.grain; settings.blackWhite = adjustment.blackWhite; settings.colorBalance = adjustment.colorBalance
            settings.radius = adjustment.gaussianRadius; settings.angle = adjustment.resolvedMotionAngle; settings.distance = adjustment.resolvedMotionDistance
            settings.amount = adjustment.resolvedNoiseAmount; settings.gaussian = adjustment.resolvedNoiseGaussian; settings.monochromatic = adjustment.resolvedNoiseMonochromatic
            settings = try filterMerged(kind, settings, overrides)
            switch adjustment.kind {
            case .curves: value.curves = settings.curves
            case .exposure: value.exposure = settings.exposure
            case .gradientMap: value.gradientMap = settings.gradientMap
            case .grain: value.grain = settings.grain
            case .blackWhite: value.blackWhite = settings.blackWhite
            case .colorBalance: value.colorBalance = settings.colorBalance
            case .gaussianBlur: value.gaussianRadius = settings.radius
            case .motionBlur: value.resolvedMotionAngle = settings.angle; value.resolvedMotionDistance = settings.distance
            case .addNoise: value.resolvedNoiseAmount = settings.amount; value.resolvedNoiseGaussian = settings.gaussian; value.resolvedNoiseMonochromatic = settings.monochromatic
            default: break
            }
        }
        return value
    }

    /// The effects with every kind present, so the schema shows each effect's keys.
    private static var everyEffect: LayerEffects {
        LayerEffects(stroke: StrokeEffect(), shadow: ShadowEffect(), colorOverlay: ColorOverlayEffect(), innerShadow: InnerShadowEffect(),
                     outerGlow: OuterGlowEffect(), innerGlow: InnerGlowEffect())
    }
    /// A settings schema that depends on the command's `kind`: each kind's own object, by kind.
    private static func byKind(_ schemas: [String: [String: Any]]) -> [String: Any] {
        ["type": "object", "x-settingsByKind": schemas,
         "x-settings": "The object for the kind passed in `kind`: " + schemas.keys.sorted().map { kind in
            kind + " {" + ((schemas[kind]?["properties"] as? [String: Any])?.keys.sorted().joined(separator: ", ") ?? "") + "}" }.joined(separator: "; ") + "."]
    }
    static var hueDefaults: [String: Any] { ["range": ColorRange.master.rawValue, "hue": 0, "saturation": 0, "lightness": 0, "colorize": false, "invertRange": false] }
    /// The default settings object of each kind a dialog command takes ("" when the command has one kind): what its
    /// schema describes, and what an agent's object is laid over.
    static func defaults(for id: LensWorksCommandID) -> [String: [String: Any]] {
        func filters(_ kinds: [FilterKind]) -> [String: [String: Any]] { Dictionary(uniqueKeysWithValues: kinds.map { ($0.rawValue, filterBase($0)) }) }
        switch id {
        case .curves: return ["": filterBase(.curves)]
        case .levels: return ["": json(LevelsSettings())]
        case .hueSaturation: return ["": hueDefaults]
        case .imageAdjustment: return filters(LensWorksCommandRegistry.imageAdjustmentKinds)
        case .filter: return filters(LensWorksCommandRegistry.filterMenuKinds)
        case .newAdjustment, .editAdjustment:
            return Dictionary(uniqueKeysWithValues: AdjustmentKind.allCases.map { ($0.rawValue, $0 == .hsv ? hueDefaults : adjustmentBase($0) ?? [:]) })
        case .addEffect:
            let effects = json(everyEffect)
            return Dictionary(uniqueKeysWithValues: LayerEffectKind.allCases.map { ($0.rawValue, effects[key($0)] as? [String: Any] ?? [:]) })
        default: return [:]
        }
    }
    static func schema(for id: LensWorksCommandID) -> [String: Any] {
        let all = defaults(for: id)
        func schema(_ kind: String) -> [String: Any] {
            id == .hueSaturation || kind == AdjustmentKind.hsv.rawValue && id != .filter ? hueSchema : describe(all[kind] ?? [:])
        }
        if all.isEmpty { return ["type": "object"] }
        return all.count == 1 && all[""] != nil ? schema("") : byKind(Dictionary(uniqueKeysWithValues: all.keys.map { ($0, schema($0)) }))
    }

    /// `base` with the keys `overrides` names replaced, recursively. A key `base` does not have, or a value of
    /// another JSON type, is refused: a misspelled setting must never silently do nothing.
    static func overlay(_ base: [String: Any], _ overrides: [String: Any], path: String = "settings") throws -> [String: Any] {
        var result = base
        for (key, value) in overrides {
            let place = path + "." + key
            guard let existing = base[key] else {
                throw LensWorksCommandRefusal(reason: "Unknown setting “\(place.prefix(96))”. Its settings are: " + base.keys.sorted().joined(separator: ", ") + ".")
            }
            switch (existing, value) {
            case (let old as [String: Any], let new as [String: Any]): result[key] = try overlay(old, new, path: place)
            case (let old as [Any], let new as [Any]):
                // A list the dialog fixes the length of (a range or curve per channel, a value per color family)
                // keeps that length; the few it lets grow are bounded. Either way each element has the shape of
                // the list's own, so nothing foreign rides inside one.
                if growingLists.contains(key) {
                    guard new.count <= listLimit else { throw LensWorksCommandRefusal(reason: "\(place.prefix(96)) must list at most \(listLimit) values.") }
                } else if new.count != old.count {
                    throw LensWorksCommandRefusal(reason: "\(place.prefix(96)) must list exactly \(old.count) values.")
                }
                if let template = old.first, !new.allSatisfy({ matches($0, template) }) {
                    throw LensWorksCommandRefusal(reason: "\(place.prefix(96)) has the wrong type for that setting.")
                }
                result[key] = new
            case (let old as NSNumber, let new as NSNumber):
                guard (CFGetTypeID(old) == CFBooleanGetTypeID()) == (CFGetTypeID(new) == CFBooleanGetTypeID()), new.doubleValue.isFinite else {
                    throw LensWorksCommandRefusal(reason: "\(place.prefix(96)) must be \(CFGetTypeID(old) == CFBooleanGetTypeID() ? "true or false" : "a finite number").")
                }
                result[key] = new
            case (is String, let new as String): result[key] = new
            default: throw LensWorksCommandRefusal(reason: "\(place.prefix(96)) has the wrong type for that setting.")
            }
        }
        return result
    }

    /// The lists a dialog lets grow: Camera Raw's point curves, point colors and upright guides. Every other list in
    /// a settings object has the length of its default, so a new one is fixed until it is named here.
    static let growingLists: Set<String> = ["rgb", "red", "green", "blue", "points", "guides"]
    /// The most values a growing list, or a curve inside a fixed one, may carry.
    static let listLimit = 32
    /// Whether `value` has the JSON shape of `template`: the same type, an object's keys all among the template's,
    /// and a nested list bounded with elements of the template's own shape.
    static func matches(_ value: Any, _ template: Any) -> Bool {
        switch (template, value) {
        case (let old as [String: Any], let new as [String: Any]):
            return new.allSatisfy { key, value in old[key].map { matches(value, $0) } ?? false }
        case (let old as [Any], let new as [Any]):
            return new.count <= listLimit && (old.first.map { template in new.allSatisfy { matches($0, template) } } ?? true)
        case (let old as NSNumber, let new as NSNumber):
            return (CFGetTypeID(old) == CFBooleanGetTypeID()) == (CFGetTypeID(new) == CFBooleanGetTypeID()) && new.doubleValue.isFinite
        case (is String, is String): return true
        default: return false
        }
    }

    /// `base` with `overrides` applied, decoded back into the settings type.
    static func merged<T: Codable>(_ base: T, _ overrides: [String: Any]?) throws -> T {
        guard let overrides, !overrides.isEmpty else { return base }
        return try decoded(try overlay(json(base), overrides))
    }
}
