import Foundation

/// "1:05.3"
func clock(_ s: Double) -> String {
    let t = max(0, s)
    let m = Int(t) / 60
    let rest = t - Double(m * 60)
    return String(format: "%d:%04.1f", m, rest)
}

/// Reads "1:05.3", "65.3" or "1:05".
func parseClock(_ s: String) -> Double? {
    let parts = s.trimmed.split(separator: ":").map(String.init)
    if parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) { return m * 60 + sec }
    if parts.count == 1, let sec = Double(parts[0]) { return sec }
    return nil
}
