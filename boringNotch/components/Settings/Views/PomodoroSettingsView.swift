//
//  PomodoroSettingsView.swift
//  boringNotch
//
//  Created by Nikola Trajkovic on 14/11/2026.
//

import Defaults
import SwiftUI

struct PomodoroSettingsView: View {
    @ObservedObject private var pomodoro = PomodoroManager.shared
    @Default(.pomodoroWorkMinutes) private var workMinutes
    @Default(.pomodoroShortBreakMinutes) private var shortBreakMinutes
    @Default(.pomodoroLongBreakMinutes) private var longBreakMinutes
    @Default(.pomodoroSessionsBeforeLongBreak) private var sessionsBeforeLongBreak
    @Default(.showPomodoroTab) private var showPomodoroTab
    @Default(.compactMode) private var compactMode
    @Default(.pomodoroSystemNotification) private var systemNotification
    @Default(.pomodoroPlaySound) private var playSound
    @Default(.pomodoroSound) private var sound

    private var notificationsDenied: Bool {
        systemNotification && pomodoro.notificationAuthorization == .denied
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showPomodoroTab) {
                    Text("Show Pomodoro tab in notch")
                }
                Defaults.Toggle(key: .showPomodoroInClosedNotch) {
                    Text("Show timer next to closed notch")
                }
            } header: {
                Text("General")
            }

            Section {
                numberRow("Work", value: $workMinutes, in: 1...120, unit: "min")
                numberRow("Short break", value: $shortBreakMinutes, in: 1...60, unit: "min")
                numberRow("Long break", value: $longBreakMinutes, in: 1...90, unit: "min")
                numberRow("Work periods before long break", value: $sessionsBeforeLongBreak, in: 1...8)
            } header: {
                Text("Timer")
            } footer: {
                Text("Duration changes apply from the next phase that starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .pomodoroAutoStartNextPhase) {
                    Text("Automatically start next phase")
                }
                Defaults.Toggle(key: .pomodoroSystemNotification) {
                    Text("Show notification")
                }
                if notificationsDenied {
                    HStack {
                        Text("Notifications are turned off for boring.notch in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Defaults.Toggle(key: .pomodoroOpenNotchOnFinish) {
                    Text("Open notch on Pomodoro tab")
                }
                .disabled(!showPomodoroTab || compactMode)
                Defaults.Toggle(key: .pomodoroPlaySound) {
                    Text("Play sound")
                }
                if playSound {
                    HStack {
                        Picker("Sound", selection: $sound) {
                            ForEach(PomodoroSound.allCases, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        Button("Preview", systemImage: "play.fill") {
                            pomodoro.play(sound)
                        }
                        .labelStyle(.iconOnly)
                        .help("Preview Sound")
                    }
                }
            } header: {
                Text("When a phase ends")
            } footer: {
                Text(phaseEndFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PomodoroStatisticsSection()
        }
        .tint(.effectiveAccent)
        .navigationTitle("Pomodoro")
        .task {
            await pomodoro.refreshNotificationAuthorization()
            // Re-read when coming back from System Settings.
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await pomodoro.refreshNotificationAuthorization()
            }
        }
        .onChange(of: systemNotification) { _, isEnabled in
            guard isEnabled else { return }
            Task { await pomodoro.requestNotificationAuthorizationIfNeeded() }
        }
        .onDisappear {
            pomodoro.stopAlarm()
        }
    }

    private var phaseEndFooter: LocalizedStringKey {
        if !showPomodoroTab || compactMode {
            return "Opening the notch needs the Pomodoro tab, which is hidden or unavailable in compact mode. Any timer control silences the sound."
        }
        return "Any timer control silences the sound."
    }

    /// A stepper paired with a field, so large changes don't take dozens of
    /// clicks. Typed values are clamped to the stepper's range.
    private func numberRow(
        _ title: LocalizedStringKey,
        value: Binding<Int>,
        in range: ClosedRange<Int>,
        unit: LocalizedStringKey? = nil
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 48)
            if let unit {
                Text(unit)
                    .foregroundStyle(.secondary)
            }
            Stepper(title, value: value, in: range)
                .labelsHidden()
        }
        .onChange(of: value.wrappedValue) { _, newValue in
            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
            if clamped != newValue {
                value.wrappedValue = clamped
            }
        }
    }
}
