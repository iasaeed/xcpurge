/// Human-readable byte sizes (`1.2 MB`), deterministic and locale-independent.
enum ByteFormatter {
    static func string(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes), unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        if unit == 0 { return "\(bytes) B" }
        let rounded = (value * 10).rounded() / 10
        return "\(rounded) \(units[unit])"
    }
}
