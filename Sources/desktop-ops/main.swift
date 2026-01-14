import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct CLIError: Error {
    let code: String
    let message: String
}

let rawArgs = Array(CommandLine.arguments.dropFirst())
var jsonOutput = false
var args: [String] = []

for arg in rawArgs {
    if arg == "--json" {
        jsonOutput = true
    } else {
        args.append(arg)
    }
}

func writeStdErr(_ text: String) {
    if let data = (text + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

func emitJSON(_ object: Any) {
    guard JSONSerialization.isValidJSONObject(object) else {
        writeStdErr("Internal error: JSON serialization failed")
        exit(1)
    }
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    } catch {
        writeStdErr("Internal error: JSON encoding failed")
        exit(1)
    }
}

func emitSuccess(data: Any? = nil) {
    if jsonOutput {
        var payload: [String: Any] = ["success": true]
        if let data = data {
            payload["data"] = data
        } else {
            payload["data"] = NSNull()
        }
        emitJSON(payload)
    } else {
        print("OK")
    }
}

func emitError(code: String, message: String) -> Never {
    if jsonOutput {
        emitJSON([
            "success": false,
            "error": code,
            "message": message
        ])
    } else {
        writeStdErr("Error (\(code)): \(message)")
    }
    exit(1)
}

func printUsage() -> Never {
    let text = """
    Usage:
      desktop-ops snapshot [--json]
      desktop-ops click <ref> [--json]
      desktop-ops set-value <ref> <text> [--json]
      desktop-ops focus <ref> [--json]
      desktop-ops press <key> [--json]
      desktop-ops run <recipe.json> [--json]
    """
    if jsonOutput {
        emitError(code: "ExecutionError", message: "Invalid arguments")
    } else {
        writeStdErr(text)
        exit(1)
    }
}

func ensureAccessibility() -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

func copyAttribute(_ element: AXUIElement, _ attribute: String) -> Any? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success, let unwrapped = value else { return nil }
    return unwrapped
}

func copyActionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    let error = AXUIElementCopyActionNames(element, &names)
    guard error == .success, let array = names as? [String] else { return [] }
    return array
}

func firstStringAttribute(_ element: AXUIElement, _ attributes: [String]) -> String? {
    for attr in attributes {
        if let value = copyAttribute(element, attr) {
            if let str = value as? String, !str.isEmpty {
                return str
            }
        }
    }
    return nil
}

func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
    if let value = copyAttribute(element, attribute) {
        if let boolValue = value as? Bool { return boolValue }
        if let numberValue = value as? NSNumber { return numberValue.boolValue }
    }
    return nil
}

func axValueToJSON(_ value: AXValue) -> [String: Any] {
    switch AXValueGetType(value) {
    case .cgPoint:
        var point = CGPoint.zero
        AXValueGetValue(value, .cgPoint, &point)
        return ["type": "point", "x": Double(point.x), "y": Double(point.y)]
    case .cgSize:
        var size = CGSize.zero
        AXValueGetValue(value, .cgSize, &size)
        return ["type": "size", "w": Double(size.width), "h": Double(size.height)]
    case .cgRect:
        var rect = CGRect.zero
        AXValueGetValue(value, .cgRect, &rect)
        return [
            "type": "rect",
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "w": Double(rect.size.width),
            "h": Double(rect.size.height)
        ]
    case .cfRange:
        var range = CFRange()
        AXValueGetValue(value, .cfRange, &range)
        return ["type": "range", "location": range.location, "length": range.length]
    default:
        return ["type": "unknown", "value": String(describing: value)]
    }
}

func toJSONValue(_ value: Any) -> Any {
    if value is NSNull { return value }
    if let str = value as? String { return str }
    if let num = value as? NSNumber { return num }
    if let boolVal = value as? Bool { return boolVal }
    if let axVal = value as? AXValue { return axValueToJSON(axVal) }
    if let arr = value as? [Any] { return arr.map { toJSONValue($0) } }
    if let dict = value as? [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            out[k] = toJSONValue(v)
        }
        return out
    }
    return String(describing: value)
}

struct SnapshotContext {
    let appName: String?
    let pid: pid_t
    let windowTitle: String?
    let windowRole: String?
    let root: AXUIElement
}

func getSnapshotContext() throws -> SnapshotContext {
    guard ensureAccessibility() else {
        throw CLIError(code: "ExecutionError", message: "Accessibility permission is required")
    }
    guard let app = NSWorkspace.shared.frontmostApplication else {
        throw CLIError(code: "ExecutionError", message: "Unable to determine frontmost application")
    }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)

    var windowElement: AXUIElement?
    if let focused = copyAttribute(appElement, kAXFocusedWindowAttribute as String) as? AXUIElement {
        windowElement = focused
    } else if let windows = copyAttribute(appElement, kAXWindowsAttribute as String) as? [AXUIElement],
              let first = windows.first {
        windowElement = first
    }

    let windowTitle = windowElement.flatMap {
        firstStringAttribute($0, [kAXTitleAttribute as String, kAXDescriptionAttribute as String])
    }
    let windowRole = windowElement.flatMap {
        firstStringAttribute($0, [kAXRoleAttribute as String])
    }

    return SnapshotContext(
        appName: app.localizedName,
        pid: app.processIdentifier,
        windowTitle: windowTitle,
        windowRole: windowRole,
        root: windowElement ?? appElement
    )
}

func refString(from path: [Int]) -> String {
    return "n" + path.map(String.init).joined(separator: ".")
}

func buildNode(_ element: AXUIElement, path: [Int]) -> [String: Any] {
    let ref = refString(from: path)
    let role = firstStringAttribute(element, [kAXRoleAttribute as String])
    let name = firstStringAttribute(element, [
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXLabelValueAttribute as String,
        kAXIdentifierAttribute as String
    ])
    let value = copyAttribute(element, kAXValueAttribute as String).map { toJSONValue($0) } ?? NSNull()
    let enabled = boolAttribute(element, kAXEnabledAttribute as String).map { $0 as Any } ?? NSNull()
    let actions = copyActionNames(element)

    var childrenNodes: [Any] = []
    if let children = copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
        for (idx, child) in children.enumerated() {
            let childPath = path + [idx]
            childrenNodes.append(buildNode(child, path: childPath))
        }
    }

    return [
        "ref": ref,
        "role": role ?? NSNull(),
        "name": name ?? NSNull(),
        "value": value,
        "enabled": enabled,
        "actions": actions,
        "children": childrenNodes
    ]
}

func elementForRef(_ ref: String, root: AXUIElement) -> AXUIElement? {
    guard ref.hasPrefix("n") else { return nil }
    let raw = ref.dropFirst()
    let parts = raw.split(separator: ".")
    let indices = parts.compactMap { Int($0) }
    guard !indices.isEmpty, indices[0] == 0 else { return nil }
    var current = root
    for index in indices.dropFirst() {
        guard let children = copyAttribute(current, kAXChildrenAttribute as String) as? [AXUIElement],
              index >= 0, index < children.count else {
            return nil
        }
        current = children[index]
    }
    return current
}

func handleSnapshot() throws -> [String: Any] {
    let context = try getSnapshotContext()
    let tree = buildNode(context.root, path: [0])
    let windowInfo: [String: Any] = [
        "title": context.windowTitle ?? NSNull(),
        "role": context.windowRole ?? NSNull()
    ]
    return [
        "app": [
            "name": context.appName ?? NSNull(),
            "pid": context.pid
        ],
        "window": windowInfo,
        "tree": tree
    ]
}

func handleClick(ref: String) throws {
    let context = try getSnapshotContext()
    guard let element = elementForRef(ref, root: context.root) else {
        throw CLIError(code: "NotFound", message: "ref \(ref) not found")
    }
    let actions = copyActionNames(element)
    guard actions.contains(kAXPressAction as String) else {
        throw CLIError(code: "NotActionable", message: "ref \(ref) does not support click")
    }
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else {
        throw CLIError(code: "ExecutionError", message: "click failed for ref \(ref)")
    }
}

func handleFocus(ref: String) throws {
    let context = try getSnapshotContext()
    guard let element = elementForRef(ref, root: context.root) else {
        throw CLIError(code: "NotFound", message: "ref \(ref) not found")
    }
    let result = AXUIElementSetAttributeValue(
        element,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    )
    guard result == .success else {
        throw CLIError(code: "NotActionable", message: "ref \(ref) cannot be focused")
    }
}

func handleSetValue(ref: String, text: String) throws {
    let context = try getSnapshotContext()
    guard let element = elementForRef(ref, root: context.root) else {
        throw CLIError(code: "NotFound", message: "ref \(ref) not found")
    }
    let result = AXUIElementSetAttributeValue(
        element,
        kAXValueAttribute as CFString,
        text as CFTypeRef
    )
    guard result == .success else {
        throw CLIError(code: "NotActionable", message: "ref \(ref) cannot accept value")
    }
}

let keyMap: [String: CGKeyCode] = [
    "a": CGKeyCode(kVK_ANSI_A),
    "b": CGKeyCode(kVK_ANSI_B),
    "c": CGKeyCode(kVK_ANSI_C),
    "d": CGKeyCode(kVK_ANSI_D),
    "e": CGKeyCode(kVK_ANSI_E),
    "f": CGKeyCode(kVK_ANSI_F),
    "g": CGKeyCode(kVK_ANSI_G),
    "h": CGKeyCode(kVK_ANSI_H),
    "i": CGKeyCode(kVK_ANSI_I),
    "j": CGKeyCode(kVK_ANSI_J),
    "k": CGKeyCode(kVK_ANSI_K),
    "l": CGKeyCode(kVK_ANSI_L),
    "m": CGKeyCode(kVK_ANSI_M),
    "n": CGKeyCode(kVK_ANSI_N),
    "o": CGKeyCode(kVK_ANSI_O),
    "p": CGKeyCode(kVK_ANSI_P),
    "q": CGKeyCode(kVK_ANSI_Q),
    "r": CGKeyCode(kVK_ANSI_R),
    "s": CGKeyCode(kVK_ANSI_S),
    "t": CGKeyCode(kVK_ANSI_T),
    "u": CGKeyCode(kVK_ANSI_U),
    "v": CGKeyCode(kVK_ANSI_V),
    "w": CGKeyCode(kVK_ANSI_W),
    "x": CGKeyCode(kVK_ANSI_X),
    "y": CGKeyCode(kVK_ANSI_Y),
    "z": CGKeyCode(kVK_ANSI_Z),
    "0": CGKeyCode(kVK_ANSI_0),
    "1": CGKeyCode(kVK_ANSI_1),
    "2": CGKeyCode(kVK_ANSI_2),
    "3": CGKeyCode(kVK_ANSI_3),
    "4": CGKeyCode(kVK_ANSI_4),
    "5": CGKeyCode(kVK_ANSI_5),
    "6": CGKeyCode(kVK_ANSI_6),
    "7": CGKeyCode(kVK_ANSI_7),
    "8": CGKeyCode(kVK_ANSI_8),
    "9": CGKeyCode(kVK_ANSI_9),
    "-": CGKeyCode(kVK_ANSI_Minus),
    "=": CGKeyCode(kVK_ANSI_Equal),
    "[": CGKeyCode(kVK_ANSI_LeftBracket),
    "]": CGKeyCode(kVK_ANSI_RightBracket),
    ";": CGKeyCode(kVK_ANSI_Semicolon),
    "'": CGKeyCode(kVK_ANSI_Quote),
    ",": CGKeyCode(kVK_ANSI_Comma),
    ".": CGKeyCode(kVK_ANSI_Period),
    "/": CGKeyCode(kVK_ANSI_Slash),
    "\\": CGKeyCode(kVK_ANSI_Backslash),
    "`": CGKeyCode(kVK_ANSI_Grave),
    "space": CGKeyCode(kVK_Space),
    "tab": CGKeyCode(kVK_Tab),
    "enter": CGKeyCode(kVK_Return),
    "return": CGKeyCode(kVK_Return),
    "escape": CGKeyCode(kVK_Escape),
    "esc": CGKeyCode(kVK_Escape),
    "backspace": CGKeyCode(kVK_Delete),
    "delete": CGKeyCode(kVK_ForwardDelete),
    "left": CGKeyCode(kVK_LeftArrow),
    "right": CGKeyCode(kVK_RightArrow),
    "up": CGKeyCode(kVK_UpArrow),
    "down": CGKeyCode(kVK_DownArrow),
    "home": CGKeyCode(kVK_Home),
    "end": CGKeyCode(kVK_End),
    "pageup": CGKeyCode(kVK_PageUp),
    "pagedown": CGKeyCode(kVK_PageDown),
    "f1": CGKeyCode(kVK_F1),
    "f2": CGKeyCode(kVK_F2),
    "f3": CGKeyCode(kVK_F3),
    "f4": CGKeyCode(kVK_F4),
    "f5": CGKeyCode(kVK_F5),
    "f6": CGKeyCode(kVK_F6),
    "f7": CGKeyCode(kVK_F7),
    "f8": CGKeyCode(kVK_F8),
    "f9": CGKeyCode(kVK_F9),
    "f10": CGKeyCode(kVK_F10),
    "f11": CGKeyCode(kVK_F11),
    "f12": CGKeyCode(kVK_F12)
]

func keyCode(for key: String) -> CGKeyCode? {
    let normalized = key.lowercased()
    if let code = keyMap[normalized] {
        return code
    }
    if normalized.count == 1, let code = keyMap[String(normalized)] {
        return code
    }
    return nil
}

func handlePress(key: String) throws {
    guard ensureAccessibility() else {
        throw CLIError(code: "ExecutionError", message: "Accessibility permission is required")
    }
    guard let code = keyCode(for: key) else {
        throw CLIError(code: "NotActionable", message: "Unknown key: \(key)")
    }
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw CLIError(code: "ExecutionError", message: "Unable to create event source")
    }
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
        throw CLIError(code: "ExecutionError", message: "Unable to create key events")
    }
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

func handleRun(path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    let json = try JSONSerialization.jsonObject(with: data)
    guard let steps = json as? [[String: Any]] else {
        throw CLIError(code: "ExecutionError", message: "Recipe must be a JSON array of objects")
    }

    var results: [[String: Any]] = []

    for (index, step) in steps.enumerated() {
        guard let cmd = step["cmd"] as? String else {
            throw CLIError(code: "ExecutionError", message: "Recipe step \(index) missing cmd")
        }
        do {
            switch cmd {
            case "snapshot":
                let snap = try handleSnapshot()
                results.append(["cmd": cmd, "success": true, "data": snap])
            case "click":
                guard let ref = step["ref"] as? String else {
                    throw CLIError(code: "ExecutionError", message: "Recipe step \(index) missing ref")
                }
                try handleClick(ref: ref)
                results.append(["cmd": cmd, "success": true, "data": NSNull()])
            case "set_value", "set-value":
                guard let ref = step["ref"] as? String else {
                    throw CLIError(code: "ExecutionError", message: "Recipe step \(index) missing ref")
                }
                guard let value = step["value"] as? String else {
                    throw CLIError(code: "ExecutionError", message: "Recipe step \(index) missing value")
                }
                try handleSetValue(ref: ref, text: value)
                results.append(["cmd": cmd, "success": true, "data": NSNull()])
            case "focus":
                guard let ref = step["ref"] as? String else {
                    throw CLIError(code: "ExecutionError", message: "Recipe step \(index) missing ref")
                }
                try handleFocus(ref: ref)
                results.append(["cmd": cmd, "success": true, "data": NSNull()])
            case "press":
                guard let key = step["key"] as? String else {
                    throw CLIError(code: "ExecutionError", message: "Recipe step \(index) missing key")
                }
                try handlePress(key: key)
                results.append(["cmd": cmd, "success": true, "data": NSNull()])
            default:
                throw CLIError(code: "ExecutionError", message: "Unknown cmd: \(cmd)")
            }
        } catch let error as CLIError {
            let failure: [String: Any] = [
                "cmd": cmd,
                "success": false,
                "error": error.code,
                "message": error.message
            ]
            results.append(failure)
            throw CLIError(code: error.code, message: error.message)
        }
    }

    return ["steps": results]
}

guard let command = args.first else {
    printUsage()
}

do {
    switch command {
    case "snapshot":
        let data = try handleSnapshot()
        if jsonOutput {
            emitSuccess(data: data)
        } else {
            let app = (data["app"] as? [String: Any])?["name"] as? String ?? "UnknownApp"
            let window = (data["window"] as? [String: Any])?["title"] as? String ?? "UnknownWindow"
            print("Snapshot: \(app) - \(window)")
        }
    case "click":
        guard args.count >= 2 else { printUsage() }
        try handleClick(ref: args[1])
        emitSuccess(data: ["cmd": "click", "ref": args[1]])
    case "set-value":
        guard args.count >= 3 else { printUsage() }
        let ref = args[1]
        let text = args.dropFirst(2).joined(separator: " ")
        try handleSetValue(ref: ref, text: text)
        emitSuccess(data: ["cmd": "set-value", "ref": ref])
    case "focus":
        guard args.count >= 2 else { printUsage() }
        try handleFocus(ref: args[1])
        emitSuccess(data: ["cmd": "focus", "ref": args[1]])
    case "press":
        guard args.count >= 2 else { printUsage() }
        try handlePress(key: args[1])
        emitSuccess(data: ["cmd": "press", "key": args[1]])
    case "run":
        guard args.count >= 2 else { printUsage() }
        let result = try handleRun(path: args[1])
        emitSuccess(data: result)
    default:
        printUsage()
    }
} catch let error as CLIError {
    emitError(code: error.code, message: error.message)
} catch {
    emitError(code: "ExecutionError", message: error.localizedDescription)
}
