//
//  PomodoroLiveActivity.swift
//  boringNotch
//
//  Created by Nikola Trajkovic on 14/11/2026.
//

import SwiftUI

/// The closed-notch Pomodoro activity: a small progress ring left of the
/// cutout and the remaining time right of it.
///
/// Both wings share one width so the black centre section stays centred on
/// the physical notch, the same way the music activity lines up.
struct PomodoroLiveActivity: View {
    @ObservedObject private var pomodoro = PomodoroManager.shared

    /// Height of the closed pill.
    let height: CGFloat
    /// Width of the black section covering the notch cutout.
    let centerWidth: CGFloat

    /// Fits "120:00" at the label's size; also used for the ring's wing.
    static let wingWidth: CGFloat = 44

    var body: some View {
        TimelineView(PomodoroTickSchedule(endDate: pomodoro.isRunning ? pomodoro.endDate : nil)) { _ in
            HStack(spacing: 0) {
                ring
                    .frame(width: Self.wingWidth, height: height)

                Rectangle()
                    .fill(.black)
                    .frame(width: centerWidth)

                Text(Duration.seconds(Int(pomodoro.remainingTime.rounded(.up))),
                     format: .time(pattern: .minuteSecond(padMinuteToLength: 2)))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .opacity(pomodoro.isPaused ? 0.5 : 1)
                    .frame(width: Self.wingWidth, height: height)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Pomodoro, \(pomodoro.phase.title)"))
    }

    private var ring: some View {
        let size = max(0, height - 12)
        let lineWidth: CGFloat = 2.5

        return ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.35), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: pomodoro.progress)
                .stroke(Color.effectiveAccent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(pomodoro.isPaused ? 0.5 : 1)
        }
        .frame(width: size, height: size)
    }
}
