import Dispatch
import Foundation
import Darwin

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("usage: WatchdogE2EHelper <heartbeat-path> <term-marker-path>\n", stderr)
    exit(64)
}

let heartbeatURL = URL(fileURLWithPath: arguments[1])
let termMarkerURL = URL(fileURLWithPath: arguments[2])

private final class HeartbeatState: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64 = 0

    func next() -> UInt64 {
        lock.withLock {
            counter &+= 1
            return counter
        }
    }
}

private let heartbeatState = HeartbeatState()

@discardableResult
func write(_ value: String, to url: URL) -> Bool {
    do {
        try Data(value.utf8).write(to: url, options: .atomic)
        return true
    } catch {
        fputs("write failed: \(error.localizedDescription)\n", stderr)
        return false
    }
}

func heartbeat() {
    guard write("\(heartbeatState.next())\n", to: heartbeatURL) else { exit(1) }
}

signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    _ = write("term\n", to: termMarkerURL)
    exit(0)
}
termSource.resume()

heartbeat()
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
timer.setEventHandler(handler: heartbeat)
timer.resume()

dispatchMain()
