import AppKit

// MARK: - Types

enum Prayer: String, CaseIterable, Hashable {
    case subuh, dzuhur, ashar, maghrib, isya

    var name: String {
        switch self {
        case .subuh: return "Subuh"
        case .dzuhur: return "Dzuhur"
        case .ashar: return "Ashar"
        case .maghrib: return "Maghrib"
        case .isya: return "Isya"
        }
    }

    var symbol: String {
        switch self {
        case .subuh: return "sunrise.fill"
        case .dzuhur: return "sun.max.fill"
        case .ashar: return "sun.min.fill"
        case .maghrib: return "sunset.fill"
        case .isya: return "moon.stars.fill"
        }
    }
}

struct PrayerTime: Equatable {
    var prayer: Prayer
    var time: Date
    var key: String { "\(prayer.rawValue)-\(Int(time.timeIntervalSince1970))" }
}

/// Shown in the island from 10 minutes before a prayer until 10 minutes after it (or "Oke").
struct PrayerAlert: Equatable {
    var prayer: Prayer
    var time: Date
    var isNow: Bool
    var key: String
}

struct PrayerCity: Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
    let utcOffset: Int   // WIB 7, WITA 8, WIT 9

    static let all: [PrayerCity] = [
        PrayerCity(name: "Jakarta", latitude: -6.2088, longitude: 106.8456, utcOffset: 7),
        PrayerCity(name: "Bogor", latitude: -6.5971, longitude: 106.8060, utcOffset: 7),
        PrayerCity(name: "Depok", latitude: -6.4025, longitude: 106.7942, utcOffset: 7),
        PrayerCity(name: "Tangerang", latitude: -6.1783, longitude: 106.6319, utcOffset: 7),
        PrayerCity(name: "Bekasi", latitude: -6.2383, longitude: 106.9756, utcOffset: 7),
        PrayerCity(name: "Bandung", latitude: -6.9175, longitude: 107.6191, utcOffset: 7),
        PrayerCity(name: "Semarang", latitude: -6.9667, longitude: 110.4167, utcOffset: 7),
        PrayerCity(name: "Yogyakarta", latitude: -7.7956, longitude: 110.3695, utcOffset: 7),
        PrayerCity(name: "Surabaya", latitude: -7.2575, longitude: 112.7521, utcOffset: 7),
        PrayerCity(name: "Malang", latitude: -7.9666, longitude: 112.6326, utcOffset: 7),
        PrayerCity(name: "Banda Aceh", latitude: 5.5483, longitude: 95.3238, utcOffset: 7),
        PrayerCity(name: "Medan", latitude: 3.5952, longitude: 98.6722, utcOffset: 7),
        PrayerCity(name: "Padang", latitude: -0.9471, longitude: 100.4172, utcOffset: 7),
        PrayerCity(name: "Pekanbaru", latitude: 0.5071, longitude: 101.4478, utcOffset: 7),
        PrayerCity(name: "Palembang", latitude: -2.9761, longitude: 104.7754, utcOffset: 7),
        PrayerCity(name: "Pontianak", latitude: -0.0263, longitude: 109.3425, utcOffset: 7),
        PrayerCity(name: "Denpasar", latitude: -8.6705, longitude: 115.2126, utcOffset: 8),
        PrayerCity(name: "Mataram", latitude: -8.5833, longitude: 116.1167, utcOffset: 8),
        PrayerCity(name: "Banjarmasin", latitude: -3.3186, longitude: 114.5944, utcOffset: 8),
        PrayerCity(name: "Balikpapan", latitude: -1.2379, longitude: 116.8529, utcOffset: 8),
        PrayerCity(name: "Samarinda", latitude: -0.5022, longitude: 117.1536, utcOffset: 8),
        PrayerCity(name: "Makassar", latitude: -5.1477, longitude: 119.4327, utcOffset: 8),
        PrayerCity(name: "Manado", latitude: 1.4748, longitude: 124.8421, utcOffset: 8),
        PrayerCity(name: "Ambon", latitude: -3.6954, longitude: 128.1814, utcOffset: 9),
        PrayerCity(name: "Jayapura", latitude: -2.5337, longitude: 140.7181, utcOffset: 9),
    ]

    static func named(_ name: String) -> PrayerCity {
        all.first { $0.name == name } ?? all[0]
    }
}

// MARK: - Calculation (offline)

/// Prayer times with the parameters Kemenag RI uses: Subuh at 20° and Isya at 18° below the
/// horizon, Ashar when a shadow equals its object's length plus the noon shadow (Syafi'i),
/// 2 minutes of ihtiyat (3 for Dzuhur), rounded up to the minute.
/// Checked against the Bimas Islam schedule for Jakarta, 1 and 30 October 2026: identical.
enum PrayerCalculator {
    static func times(for date: Date, city: PrayerCity) -> [PrayerTime] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: city.utcOffset * 3600) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let midnight = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return [] }

        let minutes = rawMinutes(year: year, month: month, day: day,
                                 latitude: city.latitude, longitude: city.longitude,
                                 utcOffset: Double(city.utcOffset))
        return Prayer.allCases.compactMap { prayer -> PrayerTime? in
            guard let value = minutes[prayer], value.isFinite else { return nil }
            let ihtiyat: Double = prayer == .dzuhur ? 3 : 2
            let rounded = (value + ihtiyat).rounded(.up)
            return PrayerTime(prayer: prayer, time: midnight.addingTimeInterval(rounded * 60))
        }
    }

    /// Minutes after local midnight, before ihtiyat.
    private static func rawMinutes(year: Int, month: Int, day: Int,
                                   latitude: Double, longitude: Double,
                                   utcOffset: Double) -> [Prayer: Double] {
        let jd = julianDay(year: year, month: month, day: day) - longitude / (15.0 * 24.0)

        func midDay(_ t: Double) -> Double {
            fix(12.0 - sunPosition(jd + t).equation, 24.0)
        }
        func sunAngleTime(_ angle: Double, _ t: Double, beforeNoon: Bool) -> Double {
            let declination = sunPosition(jd + t).declination
            let noon = midDay(t)
            let cosine = (-dsin(angle) - dsin(declination) * dsin(latitude)) / (dcos(declination) * dcos(latitude))
            let offset = dacos(cosine) / 15.0
            return noon + (beforeNoon ? -offset : offset)
        }
        func asrTime(_ factor: Double, _ t: Double) -> Double {
            let declination = sunPosition(jd + t).declination
            let angle = -dacot(factor + dtan(abs(latitude - declination)))
            return sunAngleTime(angle, t, beforeNoon: false)
        }

        let hours: [Prayer: Double] = [
            .subuh: sunAngleTime(20.0, 5.0 / 24.0, beforeNoon: true),
            .dzuhur: midDay(12.0 / 24.0),
            .ashar: asrTime(1.0, 13.0 / 24.0),
            .maghrib: sunAngleTime(1.0, 18.0 / 24.0, beforeNoon: false),
            .isya: sunAngleTime(18.0, 18.0 / 24.0, beforeNoon: false),
        ]
        return hours.mapValues { ($0 + utcOffset - longitude / 15.0) * 60.0 }
    }

    private static func sunPosition(_ jd: Double) -> (declination: Double, equation: Double) {
        let d = jd - 2451545.0
        let g = fix(357.529 + 0.98560028 * d, 360.0)
        let q = fix(280.459 + 0.98564736 * d, 360.0)
        let l = fix(q + 1.915 * dsin(g) + 0.020 * dsin(2.0 * g), 360.0)
        let e = 23.439 - 0.00000036 * d
        let rightAscension = datan2(dcos(e) * dsin(l), dcos(l)) / 15.0
        let equation = q / 15.0 - fix(rightAscension, 24.0)
        let declination = dasin(dsin(e) * dsin(l))
        return (declination, equation)
    }

    private static func julianDay(year: Int, month: Int, day: Int) -> Double {
        var y = Double(year)
        var m = Double(month)
        if month <= 2 {
            y -= 1
            m += 12
        }
        let a = (y / 100.0).rounded(.down)
        let b = 2.0 - a + (a / 4.0).rounded(.down)
        return (365.25 * (y + 4716.0)).rounded(.down) + (30.6001 * (m + 1.0)).rounded(.down)
            + Double(day) + b - 1524.5
    }

    private static func fix(_ value: Double, _ mod: Double) -> Double {
        let result = value - mod * (value / mod).rounded(.down)
        return result < 0 ? result + mod : result
    }

    private static func dsin(_ d: Double) -> Double { sin(d * .pi / 180.0) }
    private static func dcos(_ d: Double) -> Double { cos(d * .pi / 180.0) }
    private static func dtan(_ d: Double) -> Double { tan(d * .pi / 180.0) }
    private static func dasin(_ x: Double) -> Double { asin(x) * 180.0 / .pi }
    private static func dacos(_ x: Double) -> Double { acos(x) * 180.0 / .pi }
    private static func datan2(_ y: Double, _ x: Double) -> Double { atan2(y, x) * 180.0 / .pi }
    private static func dacot(_ x: Double) -> Double { atan(1.0 / x) * 180.0 / .pi }
}

// MARK: - Countdown

@MainActor
final class PrayerMonitor {
    private let model: IslandModel
    private var computedKey = ""
    private var schedule: [PrayerTime] = []   // today + tomorrow
    private var chimedKey = ""

    init(model: IslandModel) {
        self.model = model
    }

    /// Called once a second.
    func tick(now: Date = Date()) {
        guard model.prayerEnabled else {
            if model.prayerAlert != nil { model.prayerAlert = nil }
            return
        }

        let city = PrayerCity.named(model.prayerCityName)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: city.utcOffset * 3600) ?? .current
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        let dayKey = "\(city.name)|\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
        if dayKey != computedKey {
            computedKey = dayKey
            let today = PrayerCalculator.times(for: now, city: city)
            let tomorrow = PrayerCalculator.times(for: now.addingTimeInterval(86_400), city: city)
            schedule = today + tomorrow
            model.prayerTimes = today
        }

        let next = schedule.first { $0.time > now }
        if model.nextPrayer != next { model.nextPrayer = next }

        var alert: PrayerAlert?
        for item in schedule where now >= item.time.addingTimeInterval(-600) && now < item.time.addingTimeInterval(600) {
            if item.key != model.dismissedPrayerKey {
                alert = PrayerAlert(prayer: item.prayer, time: item.time, isNow: now >= item.time, key: item.key)
            }
            break
        }

        if let alert = alert, alert.isNow, chimedKey != alert.key {
            chimedKey = alert.key
            NSSound(named: "Glass")?.play()
        }
        if model.prayerAlert != alert { model.prayerAlert = alert }
    }
}

// MARK: - Formatting

enum Countdown {
    /// "1 j 20 m" for an hour or more, otherwise "9:41".
    static func text(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        if seconds >= 3600 {
            return "\(seconds / 3600) j \((seconds % 3600) / 60) m"
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
