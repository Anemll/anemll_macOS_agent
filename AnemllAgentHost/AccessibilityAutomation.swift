import Foundation
import AppKit
import ApplicationServices

enum AccessibilityAutomation {
    enum Error: Swift.Error, LocalizedError {
        case permissionRequired
        case applicationNotFound
        case elementNotFound
        case unsupportedAction(String)
        case operationFailed(AXError)

        var errorDescription: String? {
            switch self {
            case .permissionRequired: "Accessibility permission is required"
            case .applicationNotFound: "Target application was not found"
            case .elementNotFound: "Matching accessibility element was not found"
            case .unsupportedAction(let action): "Unsupported accessibility action: \(action)"
            case .operationFailed(let error): "Accessibility operation failed: \(error.rawValue)"
            }
        }
    }

    struct Query: Sendable {
        var pid: pid_t?
        var app: String?
        var role: String?
        var title: String?
        var identifier: String?
        var maxDepth: Int = 8
        var maxElements: Int = 500
    }

    static func snapshot(query: Query) throws -> [String: Any] {
        guard AXIsProcessTrusted() else { throw Error.permissionRequired }
        let targetPID = try resolvePID(pid: query.pid, app: query.app)
        let application = AXUIElementCreateApplication(targetPID)
        let maxDepth = min(max(query.maxDepth, 0), AutomationLimits.maximumAccessibilityDepth)
        let maxElements = min(max(query.maxElements, 1), AutomationLimits.maximumAccessibilityElements)

        var queue: [(element: AXUIElement, depth: Int, path: [Int])] = [(application, 0, [])]
        var output: [[String: Any]] = []
        var visited = 0
        var queueIndex = 0

        while queueIndex < queue.count && visited < maxElements {
            let current = queue[queueIndex]
            queueIndex += 1
            visited += 1

            let info = elementInfo(current.element, depth: current.depth, path: current.path)
            if matches(info: info, query: query) {
                output.append(info)
            }

            guard current.depth < maxDepth else { continue }
            for (index, child) in children(of: current.element).enumerated() {
                queue.append((child, current.depth + 1, current.path + [index]))
            }
        }

        return [
            "ok": true,
            "pid": Int(targetPID),
            "count": output.count,
            "visited": visited,
            "truncated": queueIndex < queue.count,
            "elements": output
        ]
    }

    static func perform(query: Query, action: String, value: String? = nil) throws -> [String: Any] {
        guard AXIsProcessTrusted() else { throw Error.permissionRequired }
        let targetPID = try resolvePID(pid: query.pid, app: query.app)
        let application = AXUIElementCreateApplication(targetPID)
        guard let element = findElement(root: application, query: query) else {
            throw Error.elementNotFound
        }

        let normalizedAction = action.lowercased().replacingOccurrences(of: "-", with: "_")
        let result: AXError
        switch normalizedAction {
        case "press", "click":
            result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        case "confirm":
            result = AXUIElementPerformAction(element, kAXConfirmAction as CFString)
        case "cancel":
            result = AXUIElementPerformAction(element, kAXCancelAction as CFString)
        case "increment":
            result = AXUIElementPerformAction(element, kAXIncrementAction as CFString)
        case "decrement":
            result = AXUIElementPerformAction(element, kAXDecrementAction as CFString)
        case "show_menu":
            result = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
        case "focus":
            result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        case "set_value":
            guard let value else { throw AutomationValidationError("set_value requires value") }
            try AutomationLimits.validateText(value)
            result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        default:
            throw Error.unsupportedAction(action)
        }

        guard result == .success else { throw Error.operationFailed(result) }
        return [
            "ok": true,
            "pid": Int(targetPID),
            "action": normalizedAction,
            "element": elementInfo(element, depth: 0, path: [])
        ]
    }

    static func elementExists(query: Query) throws -> Bool {
        guard AXIsProcessTrusted() else { throw Error.permissionRequired }
        let targetPID = try resolvePID(pid: query.pid, app: query.app)
        return findElement(root: AXUIElementCreateApplication(targetPID), query: query) != nil
    }

    private static func resolvePID(pid: pid_t?, app: String?) throws -> pid_t {
        if let pid {
            guard pid > 0 else { throw Error.applicationNotFound }
            return pid
        }
        guard let app, !app.isEmpty else { throw Error.applicationNotFound }
        let applications = NSWorkspace.shared.runningApplications
        guard let match = applications.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains(app)
            || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(app)
        }) else {
            throw Error.applicationNotFound
        }
        return match.processIdentifier
    }

    private static func findElement(root: AXUIElement, query: Query) -> AXUIElement? {
        let maxDepth = min(max(query.maxDepth, 0), AutomationLimits.maximumAccessibilityDepth)
        let maxElements = min(max(query.maxElements, 1), AutomationLimits.maximumAccessibilityElements)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        var queueIndex = 0

        while queueIndex < queue.count && visited < maxElements {
            let (element, depth) = queue[queueIndex]
            queueIndex += 1
            visited += 1
            if matches(info: elementInfo(element, depth: depth, path: []), query: query) {
                return element
            }
            if depth < maxDepth {
                queue.append(contentsOf: children(of: element).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private static func matches(info: [String: Any], query: Query) -> Bool {
        if let role = query.role,
           !string(info["role"], contains: role) { return false }
        if let title = query.title,
           !string(info["title"], contains: title)
           && !string(info["label"], contains: title)
           && !string(info["value"], contains: title) { return false }
        if let identifier = query.identifier,
           !string(info["identifier"], contains: identifier) { return false }
        return true
    }

    private static func string(_ raw: Any?, contains needle: String) -> Bool {
        guard let value = raw as? String else { return false }
        return value.localizedCaseInsensitiveContains(needle)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else {
            return []
        }
        return children
    }

    private static func elementInfo(_ element: AXUIElement, depth: Int, path: [Int]) -> [String: Any] {
        var info: [String: Any] = ["depth": depth, "path": path]
        copyString(element, attribute: kAXRoleAttribute, key: "role", into: &info)
        copyString(element, attribute: kAXSubroleAttribute, key: "subrole", into: &info)
        copyString(element, attribute: kAXTitleAttribute, key: "title", into: &info)
        copyString(element, attribute: kAXDescriptionAttribute, key: "label", into: &info)
        copyString(element, attribute: kAXIdentifierAttribute, key: "identifier", into: &info)
        copyBoolean(element, attribute: kAXEnabledAttribute, key: "enabled", into: &info)
        copyBoolean(element, attribute: kAXFocusedAttribute, key: "focused", into: &info)

        if info["role"] as? String != "AXSecureTextField" {
            copyScalarValue(element, attribute: kAXValueAttribute, key: "value", into: &info)
        }

        if let frame = frame(of: element) {
            info["frame"] = [
                "x": Double(frame.origin.x),
                "y": Double(frame.origin.y),
                "w": Double(frame.width),
                "h": Double(frame.height)
            ]
        }

        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success,
           let actions = names as? [String], !actions.isEmpty {
            info["actions"] = actions
        }
        return info
    }

    private static func copyString(
        _ element: AXUIElement,
        attribute: String,
        key: String,
        into info: inout [String: Any]
    ) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let string = value as? String, !string.isEmpty
        else { return }
        info[key] = String(string.prefix(500))
    }

    private static func copyBoolean(
        _ element: AXUIElement,
        attribute: String,
        key: String,
        into info: inout [String: Any]
    ) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let boolean = value as? Bool
        else { return }
        info[key] = boolean
    }

    private static func copyScalarValue(
        _ element: AXUIElement,
        attribute: String,
        key: String,
        into info: inout [String: Any]
    ) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else { return }
        if let string = value as? String {
            info[key] = String(string.prefix(500))
        } else if let number = value as? NSNumber {
            info[key] = number
        }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }
}
