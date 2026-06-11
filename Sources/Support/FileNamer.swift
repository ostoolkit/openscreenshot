import Foundation

/// Expands filename templates, e.g.
/// "OpenScreenshot %y-%m-%d at %H.%M.%S" -> "OpenScreenshot 2026-06-10 at 14.03.22"
enum FileNamer {
    static func filename(template: String, date: Date = Date(), ext: String) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        var name = template
        name = name.replacingOccurrences(of: "%y", with: String(c.year ?? 0))
        name = name.replacingOccurrences(of: "%m", with: pad(c.month))
        name = name.replacingOccurrences(of: "%d", with: pad(c.day))
        name = name.replacingOccurrences(of: "%H", with: pad(c.hour))
        name = name.replacingOccurrences(of: "%M", with: pad(c.minute))
        name = name.replacingOccurrences(of: "%S", with: pad(c.second))
        return name + "." + ext
    }

    /// Returns a URL in `directory` that does not collide with an existing file.
    static func uniqueURL(directory: URL, filename: String) -> URL {
        var url = directory.appendingPathComponent(filename)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return url
    }
}
