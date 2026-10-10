import AppKit
import CoreGraphics
import Foundation
import SelectionCore

// studylens-helper serve --owner-pid <pid>
//
// Newline-delimited JSON over stdin/stdout. Requests are handled sequentially on the main actor
// while the main run loop stays alive for NSWorkspace activation notifications.
// Only protocol responses go to stdout; diagnostics go to stderr.

func logError(_ message: String) {
    FileHandle.standardError.write(Data(("studylens-helper: " + message + "\n").utf8))
}

func usage() -> Never {
    logError("usage: studylens-helper serve --owner-pid <pid>")
    exit(64)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "serve" else { usage() }
var ownerPID: pid_t?
var argIndex = 1
while argIndex < arguments.count {
    switch arguments[argIndex] {
    case "--owner-pid":
        guard argIndex + 1 < arguments.count, let pid = Int32(arguments[argIndex + 1]), pid > 0 else { usage() }
        ownerPID = pid
        argIndex += 2
    default:
        usage()
    }
}
guard let ownerPID else { usage() }

// A dead parent must not kill us with SIGPIPE mid-write; we exit on EPIPE instead.
signal(SIGPIPE, SIG_IGN)

struct Response: Encodable {
    let id: Int
    let ok: Bool
    var text: String?
    var granted: Bool?
    var error: String?
}

func send(_ response: Response) {
    guard var data = try? JSONEncoder().encode(response) else { return }
    data.append(0x0A)
    data.withUnsafeBytes { buffer in
        guard var pointer = buffer.baseAddress else { return }
        var remaining = buffer.count
        while remaining > 0 {
            let written = write(STDOUT_FILENO, pointer, remaining)
            if written < 0 {
                if errno == EINTR { continue }
                exit(0) // stdout closed: owner is gone.
            }
            remaining -= written
            pointer += written
        }
    }
}

/// Extracts an integral `id`, rejecting booleans and fractional numbers.
func requestID(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    guard double.rounded() == double, abs(double) < 9_007_199_254_740_992 else { return nil }
    return number.intValue
}

@MainActor
func handle(line: String, service: SelectedTextService) async {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let request = object as? [String: Any] else {
        send(Response(id: 0, ok: false, error: "badRequest"))
        return
    }
    guard let id = requestID(request["id"]), let cmd = request["cmd"] as? String else {
        send(Response(id: requestID(request["id"]) ?? 0, ok: false, error: "badRequest"))
        return
    }
    switch cmd {
    case "ping":
        send(Response(id: id, ok: true))
    case "selectedText":
        let prompt = (request["prompt"] as? Bool) ?? false
        do {
            let text = try await service.readSelectedText(promptForPermission: prompt)
            send(Response(id: id, ok: true, text: text))
        } catch let error as SelectedTextError {
            send(Response(id: id, ok: false, error: error.code))
        } catch {
            // Only cancellation can land here; report it as "no selection" rather than crashing.
            send(Response(id: id, ok: false, error: SelectedTextError.noSelection.code))
        }
    case "screenAccess":
        let request = (request["request"] as? Bool) ?? false
        var granted = CGPreflightScreenCaptureAccess()
        if !granted, request { granted = CGRequestScreenCaptureAccess() }
        send(Response(id: id, ok: true, granted: granted))
    default:
        send(Response(id: id, ok: false, error: "badRequest"))
    }
}

let (lines, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)

// Read stdin on a background thread so the main run loop stays free for notifications.
let reader = Thread {
    while let line = readLine(strippingNewline: true) {
        continuation.yield(line)
    }
    continuation.finish()
}
reader.name = "studylens-helper.stdin"
reader.start()

Task { @MainActor in
    let service = SelectedTextService(ownerPID: ownerPID)
    for await line in lines {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        await handle(line: line, service: service)
    }
    exit(0)
}

dispatchMain()
