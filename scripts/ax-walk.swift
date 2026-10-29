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

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: ax-walk <pid> dump|click <surface-or-name>\n".utf8))
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
default:
    FileHandle.standardError.write(Data("unknown command\n".utf8))
    exit(64)
}
