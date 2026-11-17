//
//  PomodoroStatisticsSection.swift
//  boringNotch
//
//  Created by Nikola Trajkovic on 17/11/2026.
//

import Charts
import SwiftUI

/// Pomodoro history by day, week, month or year, at the bottom of
/// Settings → Pomodoro. Everything is summed from the per-day records while
/// this view is on screen.
struct PomodoroStatisticsSection: View {
    @ObservedObject private var stats = PomodoroStatsStore.shared
    @State private var scope: Scope = .week
    /// Any date inside the period being shown.
    @State private var anchor = Date()
    @State private var isConfirmingClear = false

    enum Scope: CaseIterable, Identifiable {
        case day, week, month, year

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .day: "Day"
            case .week: "Week"
            case .month: "Month"
            case .year: "Year"
            }
        }

        var component: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
        }
    }

    private struct Bar: Identifiable {
        let date: Date
        let workSeconds: TimeInterval
        let cycles: Int
        var id: Date { date }
    }

    private var calendar: Calendar { PomodoroStatsStore.calendar }

    private var interval: DateInterval {
        calendar.dateInterval(of: scope.component, for: anchor)
            ?? DateInterval(start: calendar.startOfDay(for: anchor), duration: 86_400)
    }

    private var isCurrentPeriod: Bool {
        interval.contains(Date())
    }

    var body: some View {
        let interval = interval
        // One pass over the days: the bars, and the totals summed from them.
        let bars = scope == .day ? [] : bars(for: interval)
        let total = scope == .day
            ? stats.total(in: interval)
            : PomodoroDayRecord(
                cycles: bars.reduce(0) { $0 + $1.cycles },
                workSeconds: bars.reduce(0) { $0 + $1.workSeconds }
            )

        Section {
            Picker("Period", selection: $scope) {
                ForEach(Scope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                periodButton("Previous", systemImage: "chevron.left") { move(by: -1) }
                Spacer()
                Text(periodTitle(interval))
                    .font(.headline)
                Spacer()
                periodButton("Next", systemImage: "chevron.right") { move(by: 1) }
                    .disabled(isCurrentPeriod)
            }

            HStack(spacing: 32) {
                bigNumber("Sessions", value: "\(total.cycles)", isEmpty: total.isEmpty)
                bigNumber(
                    "Work time",
                    value: PomodoroStatsStore.durationText(total.workSeconds),
                    spokenValue: PomodoroStatsStore.spokenDuration(total.workSeconds),
                    isEmpty: total.isEmpty
                )
                Spacer()
            }

            if total.isEmpty {
                Text("No sessions yet. Finish or skip a work period in the Pomodoro tab and it will show up here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else if scope != .day {
                chart(bars, in: interval)
            }

            HStack {
                Spacer()
                Button("Clear History", role: .destructive) {
                    isConfirmingClear = true
                }
                .buttonStyle(.borderless)
                .foregroundStyle(stats.history.isEmpty ? Color.secondary : Color.red)
                .disabled(stats.history.isEmpty)
            }
        } header: {
            Text("Statistics")
        } footer: {
            Text("Clear History deletes all Pomodoro statistics. This can't be undone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Clear all Pomodoro history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                stats.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: - Pieces

    /// Chevron with a comfortable 28×28 pt hit area (the glyph alone is
    /// only ~8 pt wide).
    private func periodButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
    }

    private func bigNumber(_ title: LocalizedStringKey, value: String, spokenValue: String? = nil, isEmpty: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            // An empty period's zeros recede instead of pulling the eye.
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isEmpty ? .secondary : .primary)
                .accessibilityLabel(spokenValue ?? value)
        }
        .accessibilityElement(children: .combine)
    }

    private var barUnit: Calendar.Component {
        scope == .year ? .month : .day
    }

    private func chart(_ bars: [Bar], in interval: DateInterval) -> some View {
        let unit = barUnit
        // Labels only at the start of each bar: a stride would also put one
        // on the domain's end boundary, i.e. an extra label for the next
        // week/month/year hanging past the last bar.
        let dates = bars.map(\.date)
        let labelDates = scope == .month
            ? dates.enumerated().filter { $0.offset % 5 == 0 }.map(\.element)
            : dates

        let ticks = Self.minuteTicks(upTo: (bars.map(\.workSeconds).max() ?? 0) / 60)

        return Chart(bars) { bar in
            BarMark(
                x: .value("Date", bar.date, unit: unit),
                y: .value("Work time", bar.workSeconds / 60)
            )
            .foregroundStyle(Color.effectiveAccent)
            .accessibilityLabel(barLabel(bar.date))
            .accessibilityValue(PomodoroStatsStore.spokenDuration(bar.workSeconds))
        }
        .chartYScale(domain: 0...(ticks.last ?? 1))
        .chartXScale(domain: interval.start...interval.end)
        .chartXAxis {
            AxisMarks(values: labelDates) { _ in
                switch scope {
                case .week:
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                case .month:
                    AxisValueLabel(format: .dateTime.day(), centered: true)
                default:
                    AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        Text(PomodoroStatsStore.durationText(minutes * 60))
                    }
                }
            }
        }
        .environment(\.calendar, calendar)
        .frame(height: 160)
        .padding(.vertical, 4)
    }

    /// Y-axis ticks in whole, "round" minutes (1, 2, 5, 10, 15, 30 min, 1, 2,
    /// 4, 8 h …), about four of them, so labels never repeat the way
    /// Charts' fractional ticks did once rounded to minutes ("0m 0m 1m").
    private static func minuteTicks(upTo maxMinutes: Double) -> [Double] {
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 240, 480, 960]
        let step = steps.first { maxMinutes / $0 <= 4 } ?? 1_920
        let count = max(1, Int((maxMinutes / step).rounded(.up)))
        return (0...count).map { Double($0) * step }
    }

    private func barLabel(_ date: Date) -> String {
        switch scope {
        case .year: date.formatted(.dateTime.month(.wide))
        default: date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
    }

    private func bars(for interval: DateInterval) -> [Bar] {
        var bars: [Bar] = []
        var start = interval.start
        while start < interval.end {
            guard let next = calendar.date(byAdding: barUnit, value: 1, to: start) else { break }
            let total = stats.total(in: DateInterval(start: start, end: min(next, interval.end)))
            bars.append(Bar(date: start, workSeconds: total.workSeconds, cycles: total.cycles))
            start = next
        }
        return bars
    }

    // MARK: - Navigation

    private func move(by step: Int) {
        guard let moved = calendar.date(byAdding: scope.component, value: step, to: anchor) else { return }
        // Never step into a future period.
        anchor = min(moved, Date())
    }

    private func periodTitle(_ interval: DateInterval) -> String {
        switch scope {
        case .day:
            return interval.start.formatted(.dateTime.day().month(.abbreviated).year())
        case .week:
            let lastDay = interval.end.addingTimeInterval(-1)
            let sameYear = calendar.isDate(interval.start, equalTo: Date(), toGranularity: .year)
                && calendar.isDate(lastDay, equalTo: Date(), toGranularity: .year)
            let style = sameYear
                ? Date.IntervalFormatStyle().day().month(.abbreviated)
                : Date.IntervalFormatStyle().day().month(.abbreviated).year()
            return (interval.start..<lastDay).formatted(style)
        case .month:
            return interval.start.formatted(.dateTime.month(.wide).year())
        case .year:
            return interval.start.formatted(.dateTime.year())
        }
    }
}
