//
//  PomodoroStatsStore.swift
//  boringNotch
//
//  Created by Nikola Trajkovic on 17/11/2026.
//

import AppKit
import Defaults
import Foundation

/// Work done on one calendar day. Only work periods count; breaks never do.
struct PomodoroDayRecord: Codable, Hashable, Defaults.Serializable {
    var cycles: Int = 0
    var workSeconds: TimeInterval = 0

    static let empty = PomodoroDayRecord()

    init(cycles: Int = 0, workSeconds: TimeInterval = 0) {
        self.cycles = cycles
        self.workSeconds = workSeconds
    }

    /// Tolerates missing keys, so adding a field later can't make the saved
    /// history undecodable (Defaults would silently fall back to an empty
    /// history and the next write would erase it).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cycles = try container.decodeIfPresent(Int.self, forKey: .cycles) ?? 0
        workSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .workSeconds) ?? 0
    }

    var isEmpty: Bool { cycles == 0 && workSeconds == 0 }
}

/// Per-day Pomodoro history, persisted in Defaults. Weeks, months and years
/// are sums of days, computed on demand.
///
/// Kept separate from PomodoroManager so a recorded work period only
/// redraws the views that show statistics, not the whole notch.
@MainActor
final class PomodoroStatsStore: ObservableObject {
    static let shared = PomodoroStatsStore()

    /// Keyed by local calendar day ("2026-11-17"), so a timezone change
    /// doesn't shift past days.
    @Published private(set) var history: [String: PomodoroDayRecord]
    /// Today's record, for the notch. Rolls over to empty at midnight.
    @Published private(set) var today: PomodoroDayRecord = .empty

    private var todayKey = ""
    private var observers: [NSObjectProtocol] = []

    /// Gregorian, local time zone, weeks starting on Monday regardless of
    /// the system setting. Built once and rebuilt on time zone changes,
    /// since summing a year looks it up for every day.
    private(set) static var calendar = makeCalendar()

    private static func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar
    }

    private init() {
        history = Defaults[.pomodoroHistory]
        refreshToday()

        // "Today" must change at midnight even if nothing is recorded:
        // while running across midnight, after waking from sleep, and when
        // the clock or time zone changes.
        let center = NotificationCenter.default
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == .NSSystemTimeZoneDidChange {
                        Self.calendar = Self.makeCalendar()
                    }
                    self?.refreshToday()
                }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshToday() }
        })
    }

    static func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func refreshToday() {
        let saved = Defaults[.pomodoroHistory]
        if saved != history {
            history = saved
        }
        let key = Self.dayKey(for: Date())
        let record = history[key] ?? .empty
        if key != todayKey || record != today {
            todayKey = key
            today = record
        }
    }

    /// Adds one finished (or skipped) work period to the day it ended on.
    func recordWorkPeriod(seconds: TimeInterval, endedAt date: Date) {
        // Start from what's saved now, not from this process's copy: another
        // running instance of the app may have recorded in the meantime, and
        // writing our stale copy back would erase its entries.
        var latest = Defaults[.pomodoroHistory]
        let key = Self.dayKey(for: date)
        var record = latest[key] ?? .empty
        record.cycles += 1
        record.workSeconds += max(0, seconds)
        latest[key] = record
        Defaults[.pomodoroHistory] = latest
        history = latest
        refreshToday()
    }

    func clearHistory() {
        history = [:]
        Defaults[.pomodoroHistory] = [:]
        refreshToday()
    }

    func record(for date: Date) -> PomodoroDayRecord {
        history[Self.dayKey(for: date)] ?? .empty
    }

    /// Sum of all days in `interval` (end exclusive).
    func total(in interval: DateInterval) -> PomodoroDayRecord {
        let calendar = Self.calendar
        var total = PomodoroDayRecord.empty
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            let record = record(for: day)
            total.cycles += record.cycles
            total.workSeconds += record.workSeconds
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return total
    }

    /// "1h 25m", "25m", "1h" or "0m", localized. Whole minutes only,
    /// rounded down, so a period isn't credited with a minute it didn't run.
    static func durationText(_ seconds: TimeInterval) -> String {
        wholeMinutes(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    /// The same duration spelled out for VoiceOver ("1 hour, 25 minutes"),
    /// so "25m" isn't read as "25 metres".
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        wholeMinutes(seconds).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    private static func wholeMinutes(_ seconds: TimeInterval) -> Duration {
        .seconds(Int(max(0, seconds) / 60) * 60)
    }
}
