//
//  PomodoroView.swift
//  boringNotch
//
//  Created by Nikola Trajkovic on 14/11/2026.
//

import Defaults
import SwiftUI

struct PomodoroView: View {
    @ObservedObject private var pomodoro = PomodoroManager.shared
    @Default(.pomodoroSessionsBeforeLongBreak) private var sessionsBeforeLongBreak
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let ringSize: CGFloat = 96
    private let ringLineWidth: CGFloat = 5

    var body: some View {
        VStack(spacing: 6) {
            // Always the same TimelineView, so starting or pausing doesn't
            // swap view identity; only the schedule changes.
            TimelineView(PomodoroTickSchedule(endDate: pomodoro.isRunning ? pomodoro.endDate : nil)) { _ in
                ring
            }
            // Hangs off the ring's leading edge without taking part in the
            // layout, so the ring, dots and controls stay exactly centred.
            .overlay(alignment: .leading) {
                PomodoroTodayStats()
                    .fixedSize()
                    .alignmentGuide(.leading) { $0[.trailing] + 36 }
            }
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            if let message = pomodoro.completionMessage {
                Text(message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 170, alignment: .leading)
                    .padding(.trailing, 12)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.smooth, value: pomodoro.completionMessage)
    }

    // MARK: - Ring

    private var ring: some View {
        let progress = pomodoro.progress
        let remainingSeconds = Int(pomodoro.remainingTime.rounded(.up))

        return ZStack {
            // Light enough to read as a timer even at 0% progress.
            Circle()
                .stroke(Color.gray.opacity(0.35), lineWidth: ringLineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.effectiveAccent, style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(pausedOpacity)
                .animation(ringAnimation, value: progress)

            VStack(spacing: 4) {
                Text(Duration.seconds(remainingSeconds), format: .time(pattern: .minuteSecond(padMinuteToLength: 2)))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    // Dimmed while paused, so a stopped timer reads differently
                    // from a running one at a glance.
                    .opacity(pausedOpacity)

                Text(pomodoro.phase.title)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.gray)

                sessionDots
            }
        }
        .frame(width: ringSize, height: ringSize)
        .contentShape(Circle())
        // Restarting the whole cycle discards progress, so it isn't one
        // stray click away next to Start.
        .contextMenu {
            Button("Reset Cycle") {
                pomodoro.resetCycle()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(pomodoro.phase.title))
        .accessibilityValue(accessibilityValue(remainingSeconds: remainingSeconds))
        .accessibilityAction(named: Text("Reset Cycle")) {
            pomodoro.resetCycle()
        }
    }

    private var pausedOpacity: Double {
        pomodoro.isPaused ? 0.5 : 1
    }

    private var ringAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return pomodoro.isRunning ? .linear(duration: 1) : .smooth
    }

    /// One dot per work period in the cycle, filled for the finished ones.
    private var sessionDots: some View {
        HStack(spacing: 3) {
            // Filled for finished periods, an outline for the rest — shape as
            // well as brightness, and the outline stays clearly visible.
            ForEach(0..<sessionCount, id: \.self) { index in
                Circle()
                    .fill(index < completedSessions ? Color.white : Color.clear)
                    .overlay {
                        Circle().strokeBorder(index < completedSessions ? Color.white : Color.gray, lineWidth: 1)
                    }
                    .frame(width: 5, height: 5)
            }
        }
    }

    private var sessionCount: Int {
        max(1, sessionsBeforeLongBreak)
    }

    private var completedSessions: Int {
        min(pomodoro.completedWorkSessions, sessionCount)
    }

    /// The ring reads as one VoiceOver element: phase, then e.g.
    /// "24 minutes, 59 seconds remaining, 2 of 4 work periods completed".
    private func accessibilityValue(remainingSeconds: Int) -> Text {
        let remaining = Duration.seconds(remainingSeconds)
            .formatted(.units(allowed: [.minutes, .seconds], width: .wide))
        if pomodoro.isPaused {
            return Text("Paused, \(remaining) remaining, \(completedSessions) of \(sessionCount) work periods completed")
        }
        return Text("\(remaining) remaining, \(completedSessions) of \(sessionCount) work periods completed")
    }

    // MARK: - Controls

    /// Same size and symbol family for all three; Start/Pause stands out by
    /// style (white) rather than size, the secondary actions stay gray.
    private var controls: some View {
        HStack(spacing: 12) {
            HoverButton(icon: "arrow.counterclockwise.circle.fill", iconColor: .gray, scale: .medium) {
                pomodoro.reset()
            }
            .accessibilityLabel(Text("Reset"))
            .help("Reset")

            HoverButton(icon: pomodoro.isRunning ? "pause.circle.fill" : "play.circle.fill", iconColor: .white, scale: .medium) {
                pomodoro.toggle()
            }
            .accessibilityLabel(pomodoro.isRunning ? Text("Pause") : Text("Start"))
            .help(pomodoro.isRunning ? Text("Pause") : Text("Start"))

            HoverButton(icon: "forward.end.circle.fill", iconColor: .gray, scale: .medium) {
                pomodoro.skip()
            }
            .accessibilityLabel(Text("Skip"))
            .help("Skip to Next Phase")
        }
        .imageScale(.large)
    }
}

/// Today's work statistics, shown beside the ring. Observes only the stats
/// store, so it redraws when a work period is recorded, not every tick.
private struct PomodoroTodayStats: View {
    @ObservedObject private var stats = PomodoroStatsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // "Sessions", not "cycles": in this app a cycle is the whole run of
            // work periods up to the long break.
            item("Sessions today", value: "\(stats.today.cycles)")
            item(
                "Work time",
                value: PomodoroStatsStore.durationText(stats.today.workSeconds),
                spokenValue: PomodoroStatsStore.spokenDuration(stats.today.workSeconds)
            )
        }
        .accessibilityElement(children: .combine)
        .onAppear {
            stats.refreshToday()
        }
    }

    private func item(_ title: LocalizedStringKey, value: String, spokenValue: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.gray)
            // Quieter than the countdown (22 pt) so the timer stays the focus.
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .accessibilityLabel(spokenValue ?? value)
        }
    }
}

/// Ticks once a second while running, aligned to the end date so the
/// displayed second flips exactly when the rounded-up remaining time changes.
/// The first tick is never later than the timeline's start. When stopped it
/// yields a single entry, so an idle ring isn't redrawn every second.
struct PomodoroTickSchedule: TimelineSchedule {
    let endDate: Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard let endDate else {
            return AnySequence(CollectionOfOne(startDate))
        }
        let secondsUntilEnd = endDate.timeIntervalSince(startDate)
        let firstTick = endDate.addingTimeInterval(-secondsUntilEnd.rounded(.up))
        return AnySequence(sequence(first: firstTick) { $0.addingTimeInterval(1) })
    }
}

#Preview {
    PomodoroView()
        .frame(width: 640, height: 150)
        .background(.black)
}
