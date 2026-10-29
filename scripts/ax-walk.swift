import ApplicationServices
import CoreGraphics
import Foundation

private let targetRoles: Set<String> = [
    "AXButton",
    "AXCheckBox",
    "AXSlider",
    "AXTextField",
    "AXPopUpButton",
    "AXMenuButton",
]

private func axString(_ element: AXUIElement, _ attribute: String) -> String {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return ""
    }
    return value as? String ?? ""
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let children = value as? [AXUIElement]
    else {
        return []
    }
    return children
}

private func walk(
    _ element: AXUIElement,
    depth: Int,
    surface: String,
    inScrollBar: Bool,
    unnamed: inout [String],
    scanned: inout Int
) {
    guard depth <= 12 else { return }
    scanned += 1
    let role = axString(element, kAXRoleAttribute as String)
    let name = axString(element, kAXTitleAttribute as String)
    let description = axString(element, kAXDescriptionAttribute as String)
    let insideScrollBar = inScrollBar || role == "AXScrollBar"
    if targetRoles.contains(role), !insideScrollBar, name.isEmpty, description.isEmpty {
        unnamed.append("\(surface) role=\(role)")
    }
    for child in axChildren(element) {
        walk(
            child,
            depth: depth + 1,
            surface: surface,
            inScrollBar: insideScrollBar,
            unnamed: &unnamed,
            scanned: &scanned
        )
    }
}

private func windows(of pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement]
    else {
        return []
    }
    return windows
}

private func dumpUnnamed(pid: pid_t, surface: String) {
    let wins = windows(of: pid)
    guard !wins.isEmpty else {
        FileHandle.standardError.write(Data("\(surface): no windows\n".utf8))
        exit(2)
    }
    var unnamed: [String] = []
    var scanned = 0
    for window in wins {
        walk(window, depth: 0, surface: surface, inScrollBar: false, unnamed: &unnamed, scanned: &scanned)
    }
    if scanned == 0 {
        FileHandle.standardError.write(Data("no UI elements scanned\n".utf8))
        exit(3)
    }
    print("SCANNED \(scanned)")
    for line in unnamed {
        print(line)
    }
}

private func clickNamed(pid: pid_t, wanted: String) {
    func matches(_ element: AXUIElement) -> Bool {
        let name = axString(element, kAXTitleAttribute as String)
        let description = axString(element, kAXDescriptionAttribute as String)
        let value = axString(element, kAXValueAttribute as String)
        let identifier = axString(element, "AXIdentifier")
        return name == wanted || description == wanted || value == wanted || identifier == wanted
    }

    func search(_ element: AXUIElement, row: AXUIElement?, depth: Int) -> AXUIElement? {
        guard depth <= 12 else { return nil }
        let role = axString(element, kAXRoleAttribute as String)
        let currentRow = role == "AXRow" ? element : row
        if matches(element) {
            return currentRow ?? element
        }
        for child in axChildren(element) {
            if let found = search(child, row: currentRow, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    func findOutline(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 12 else { return nil }
        if axString(element, kAXRoleAttribute as String) == "AXOutline" {
            return element
        }
        for child in axChildren(element) {
            if let found = findOutline(child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    func clickPoint(_ element: AXUIElement) {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            return
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        let point = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
           let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        } else {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    }

    for window in windows(of: pid) {
        if let match = search(window, row: nil, depth: 0) {
            if let outline = findOutline(window, depth: 0) {
                AXUIElementSetAttributeValue(
                    outline,
                    kAXSelectedRowsAttribute as CFString,
                    [match] as CFArray
                )
            }
            AXUIElementPerformAction(match, kAXPressAction as CFString)
            clickPoint(match)
            return
        }
    }
    FileHandle.standardError.write(Data("sidebar item not found: \(wanted)\n".utf8))
    exit(4)
}


private func axNumber(_ element: AXUIElement, _ attribute: String) -> String {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
    if let number = value as? NSNumber { return number.stringValue }
    return value as? String ?? ""
}

private func axFrame(_ element: AXUIElement) -> String {
    var positionValue: AnyObject?
    var sizeValue: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
    else { return "" }
    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return "\(Int(origin.x)),\(Int(origin.y)) \(Int(size.width))x\(Int(size.height))"
}

/// Print `identifier<TAB>role<TAB>label<TAB>value<TAB>frame` for every element whose
/// AXIdentifier starts with `prefix` (all windows, depth ≤ 16). Labels are the
/// accessibility description/title; values are AXValue when present.
private func listLabels(pid: pid_t, prefix: String) {
    var printed = 0
    func visit(_ element: AXUIElement, depth: Int) {
        guard depth <= 16 else { return }
        let identifier = axString(element, "AXIdentifier")
        if identifier.hasPrefix(prefix) {
            let role = axString(element, kAXRoleAttribute as String)
            var label = axString(element, kAXDescriptionAttribute as String)
            if label.isEmpty { label = axString(element, kAXTitleAttribute as String) }
            let value = axNumber(element, kAXValueAttribute as String)
            print([identifier, role, label, value, axFrame(element)].joined(separator: "\t"))
            printed += 1
        }
        for child in axChildren(element) {
            visit(child, depth: depth + 1)
        }
    }
    for window in windows(of: pid) {
        visit(window, depth: 0)
    }
    if printed == 0 {
        FileHandle.standardError.write(Data("no element with identifier prefix \(prefix)\n".utf8))
        exit(5)
    }
}

/// AXPress the first element whose AXIdentifier equals `identifier` (no synthetic
/// mouse events, so the user's cursor is untouched).
private func pressIdentifier(pid: pid_t, identifier: String) {
    func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 16 else { return nil }
        if axString(element, "AXIdentifier") == identifier { return element }
        for child in axChildren(element) {
            if let found = find(child, depth: depth + 1) { return found }
        }
        return nil
    }
    for window in windows(of: pid) {
        if let match = find(window, depth: 0) {
            let result = AXUIElementPerformAction(match, kAXPressAction as CFString)
            guard result == .success else {
                FileHandle.standardError.write(Data("AXPress failed (\(result.rawValue)) for \(identifier)\n".utf8))
                exit(6)
            }
            return
        }
    }
    FileHandle.standardError.write(Data("element not found: \(identifier)\n".utf8))
    exit(4)
}

/// Print the status item's accessibility description without pressing it.
private func extrasLabel(pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &value) == .success else {
        FileHandle.standardError.write(Data("no AXExtrasMenuBar for pid \(pid)\n".utf8))
        exit(5)
    }
    // swiftlint:disable:next force_cast
    let bar = value as! AXUIElement
    guard let item = axChildren(bar).first else {
        FileHandle.standardError.write(Data("extras menu bar has no items\n".utf8))
        exit(5)
    }
    var label = axString(item, kAXDescriptionAttribute as String)
    if label.isEmpty { label = axString(item, kAXTitleAttribute as String) }
    print(label)
}

/// AXPress the app's menu bar status item (AXExtrasMenuBar) — opens the popover.
private func pressExtras(pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &value) == .success else {
        FileHandle.standardError.write(Data("no AXExtrasMenuBar for pid \(pid)\n".utf8))
        exit(5)
    }
    // swiftlint:disable:next force_cast
    let bar = value as! AXUIElement
    guard let item = axChildren(bar).first else {
        FileHandle.standardError.write(Data("extras menu bar has no items\n".utf8))
        exit(5)
    }
    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
    guard result == .success else {
        FileHandle.standardError.write(Data("AXPress on status item failed (\(result.rawValue))\n".utf8))
        exit(6)
    }
    print(axString(item, kAXDescriptionAttribute as String))
}

let args = CommandLine.arguments
guard args.count >= 3, args.count >= 4 || args[2] == "extras" || args[2] == "extras-label" else {
    FileHandle.standardError.write(Data("usage: ax-walk <pid> dump <surface> | click <name> | labels <identifier-prefix> | press <identifier> | extras | extras-label\n".utf8))
    exit(64)
}
guard let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("invalid pid\n".utf8))
    exit(64)
}
switch args[2] {
case "dump":
    dumpUnnamed(pid: pid, surface: args[3])
case "click":
    clickNamed(pid: pid, wanted: args[3])
case "labels":
    listLabels(pid: pid, prefix: args[3])
case "press":
    pressIdentifier(pid: pid, identifier: args[3])
case "extras":
    pressExtras(pid: pid)
case "extras-label":
    extrasLabel(pid: pid)
default:
    FileHandle.standardError.write(Data("unknown command\n".utf8))
    exit(64)
}
