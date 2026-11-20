// Run on a test Mac with a Liquid usage card open over a detailed picture. Start in another
// app. Give the test Pulse PID and a desktop rectangle (points) wholly inside the card,
// including its coloured bar but no live countdown, cursor, rounded edge or window shadow.
// swift Checks/LiquidFocusCheck.swift <pid> <x,y,width,height>
import AppKit
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]),
      let pulse = NSRunningApplication(processIdentifier: pid),
      let other = NSWorkspace.shared.frontmostApplication, other != pulse else {
    fail("Start in another app and supply the test Pulse PID and card interior rectangle.")
}
let rectangle = CommandLine.arguments[2]
let fields = rectangle.split(separator: ",").compactMap { Int($0) }
guard fields.count == 4, fields[2] > 0, fields[3] > 0 else { fail("Invalid screen rectangle.") }
let region = CGRect(x: fields[0], y: fields[1], width: fields[2], height: fields[3])

func pixels(with app: NSRunningApplication) throws -> Data {
    _ = app.activate()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
    guard NSWorkspace.shared.frontmostApplication == app else { throw CheckError.focus }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    guard windows.contains(where: { window in
        guard window[kCGWindowOwnerPID as String] as? Int32 == pid,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
        return frame.contains(region)
    }) else { throw CheckError.cardClosed }
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: url) }
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-R" + rectangle, url.path]
    try capture.run()
    capture.waitUntilExit()
    guard capture.terminationStatus == 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let data = image.dataProvider?.data else { throw CheckError.capture }
    return data as Data
}

enum CheckError: Error { case focus, cardClosed, capture }
do {
    let active = try pixels(with: pulse)
    let inactive = try pixels(with: other)
    guard active == inactive else { fail("Liquid card interior changed when Pulse lost focus.") }
    print("Liquid card interior matched with Pulse active and inactive.")
} catch {
    _ = other.activate()
    fail("Could not check the open card: \(error)")
}
