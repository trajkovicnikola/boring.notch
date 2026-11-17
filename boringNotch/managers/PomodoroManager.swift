//
//  PomodoroManager.swift
//  boringNotch
//
//  Created by Nikola Trajkovic on 14/11/2026.
//

import AppKit
import Defaults
import Foundation
import SwiftUI
import UserNotifications

enum PomodoroPhase {
    case work
    case shortBreak
    case longBreak

    var title: String {
        switch self {
        case .work: String(localized: "WORK")
        case .shortBreak: String(localized: "BREAK")
        case .longBreak: String(localized: "LONG BREAK")
        }
    }
}

/// The sound played when a phase ends: the bundled alarm or a macOS alert sound.
enum PomodoroSound: String, CaseIterable, Defaults.Serializable {
    case alarm
    case glass = "Glass"
    case ping = "Ping"
    case hero = "Hero"
    case submarine = "Submarine"
    case purr = "Purr"

    var title: String {
        switch self {
        case .alarm: String(localized: "Alarm")
        default: rawValue
        }
    }
}

/// Drives the Pomodoro cycle independently of any view, so the timer keeps
/// running while the notch is closed or another tab is shown.
///
/// The source of truth is a `ContinuousClock` deadline: it keeps counting
/// while the Mac sleeps and is unaffected by wall-clock changes, so remaining
/// time can't drift and nothing is counted in ticks. A single task sleeps
/// until the deadline.
@MainActor
final class PomodoroManager: NSObject, ObservableObject {
    static let shared = PomodoroManager()

    static let alarmSoundFileName = "pomodoro_alarm"
    static let alarmSoundFileExtension = "mp3"

    /// A phase that ended longer ago than this (i.e. while the Mac was
    /// asleep) only gets a notification — no alarm, no notch popping open.
    private static let staleCompletionThreshold: Duration = .seconds(60)
    nonisolated private static let notificationIdentifier = "pomodoro.phaseFinished"
    // Categories for a finished phase whose successor waits to be started.
    nonisolated private static let nextBreakCategory = "pomodoro.nextBreak"
    nonisolated private static let nextWorkCategory = "pomodoro.nextWork"
    nonisolated private static let startAction = "pomodoro.start"
    nonisolated private static let skipAction = "pomodoro.skip"
    nonisolated private static let phaseIDKey = "phaseID"

    @Published private(set) var phase: PomodoroPhase = .work
    /// Identifies the current phase instance, so a notification's Start/Skip
    /// can tell whether it still refers to the phase that's waiting.
    private var phaseID = UUID()
    @Published private(set) var isRunning = false {
        didSet {
            if isRunning != oldValue { updateIdleState() }
        }
    }
    /// Like `MusicManager.isPlayerIdle`: false while running, true once the
    /// timer has been paused or stopped for `waitInterval`. Drives whether the
    /// closed-notch activity is shown.
    @Published private(set) var isTimerIdle = true
    /// Wall-clock estimate of the deadline while running, so views can align
    /// their ticks to it. Re-derived when the system clock changes.
    @Published private(set) var endDate: Date?
    /// Set while paused mid-phase.
    @Published private(set) var pausedRemaining: TimeInterval?
    /// Work periods finished in the current cycle; reset after a long break.
    @Published private(set) var completedWorkSessions = 0
    /// Short "phase finished" message, shown in the tab for a few seconds.
    @Published private(set) var completionMessage: String?
    @Published private(set) var notificationAuthorization: UNAuthorizationStatus = .notDetermined

    /// Set while running; the phase ends at this instant.
    private var deadline: ContinuousClock.Instant?
    /// Locked in when a phase starts so editing the settings mid-phase
    /// doesn't make the ring jump; nil while the phase hasn't started.
    private var startedPhaseDuration: TimeInterval?

    private var phaseEndTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var completionMessageTask: Task<Void, Never>?
    private var systemObservers: [NSObjectProtocol] = []
    /// When the Mac last went to sleep, and the last full sleep it woke
    /// from, so statistics can tell whether a work period ran out asleep.
    private var sleepStartedAt: ContinuousClock.Instant?
    private var lastSleep: ClosedRange<ContinuousClock.Instant>?
    private let audioPlayer = AudioPlayer()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()

        // The continuous clock covers sleep, but the sleeping task may only
        // run some time after wake; check right away instead.
        systemObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleepStartedAt = .now
            }
        })
        systemObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let start = self.sleepStartedAt {
                    self.lastSleep = start...ContinuousClock.now
                    self.sleepStartedAt = nil
                }
                self.checkForPhaseEnd()
            }
        })

        // The deadline itself doesn't move with the wall clock, but the
        // `endDate` views align to does.
        systemObservers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshEndDate()
            }
        })

        Task {
            await refreshNotificationAuthorization()
        }
    }

    // MARK: - Derived state

    var phaseDuration: TimeInterval {
        startedPhaseDuration ?? configuredDuration(for: phase)
    }

    /// Stopped mid-phase (as opposed to not started yet).
    var isPaused: Bool {
        !isRunning && pausedRemaining != nil
    }

    var remainingTime: TimeInterval {
        if let deadline {
            return max(0, Self.seconds(deadline - .now))
        }
        return pausedRemaining ?? phaseDuration
    }

    /// 0 at the start of the phase, 1 when it ends.
    var progress: Double {
        let total = phaseDuration
        guard total > 0 else { return 0 }
        return min(max(1 - remainingTime / total, 0), 1)
    }

    // MARK: - Controls

    func toggle() {
        isRunning ? pause() : start()
    }

    func start() {
        stopAlarm()
        guard !isRunning else { return }
        run(until: .now + .seconds(pausedRemaining ?? phaseDuration))
    }

    func pause() {
        stopAlarm()
        guard isRunning else { return }
        let remaining = remainingTime
        stopTimer()
        pausedRemaining = remaining
    }

    /// Returns the current phase to its full duration.
    func reset() {
        stopAlarm()
        stopTimer()
        pausedRemaining = nil
        startedPhaseDuration = nil
    }

    /// Starts over from the first work period, clearing completed sessions.
    func resetCycle() {
        reset()
        completedWorkSessions = 0
        phase = .work
        phaseID = UUID()
    }

    /// Finishes the current phase early and moves on. A skipped work period
    /// counts as completed — skipping means "I'm done" — so it fills its dot
    /// and can earn the long break. Keeps going if the timer was running and
    /// auto-start is on, same as when a phase ends by itself.
    func skip() {
        stopAlarm()
        // A phase that already ran out (e.g. during sleep, before the wake
        // check ran) has ended on its own: finish it as such instead of
        // crediting it as worked time and then skipping the next phase too.
        if isRunning, let deadline, deadline <= .now {
            finishPhase(endedAt: deadline)
            return
        }
        let wasRunning = isRunning
        // Only a work period that was actually started counts; skipping one
        // that never ran (e.g. from a notification) isn't work done.
        if phase == .work && (isRunning || isPaused) {
            // Only the time actually worked; paused time never ran down.
            PomodoroStatsStore.shared.recordWorkPeriod(seconds: phaseDuration - remainingTime, endedAt: Date())
        }
        advance(afterCompleting: true)
        if wasRunning && Defaults[.pomodoroAutoStartNextPhase] {
            start()
        }
    }

    // MARK: - Phase transitions

    private func configuredDuration(for phase: PomodoroPhase) -> TimeInterval {
        let minutes: Int
        switch phase {
        case .work: minutes = Defaults[.pomodoroWorkMinutes]
        case .shortBreak: minutes = Defaults[.pomodoroShortBreakMinutes]
        case .longBreak: minutes = Defaults[.pomodoroLongBreakMinutes]
        }
        return TimeInterval(max(1, minutes) * 60)
    }

    private func run(until newDeadline: ContinuousClock.Instant) {
        Task {
            _ = await requestNotificationAuthorizationIfNeeded()
        }

        startedPhaseDuration = phaseDuration
        deadline = newDeadline
        pausedRemaining = nil
        isRunning = true
        refreshEndDate()
        schedulePhaseEnd()
    }

    private func stopTimer() {
        phaseEndTask?.cancel()
        deadline = nil
        endDate = nil
        isRunning = false
    }

    private func refreshEndDate() {
        guard let deadline else { return }
        endDate = Date().addingTimeInterval(Self.seconds(deadline - .now))
    }

    private func schedulePhaseEnd() {
        phaseEndTask?.cancel()
        guard let deadline else { return }
        phaseEndTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.checkForPhaseEnd()
        }
    }

    private func checkForPhaseEnd() {
        guard isRunning, let deadline else { return }
        if deadline <= .now {
            finishPhase(endedAt: deadline)
        } else {
            schedulePhaseEnd()
        }
    }

    private func finishPhase(endedAt deadline: ContinuousClock.Instant) {
        var lastPhaseEnd = deadline
        var finishedPhase = phase
        recordIfWorkEndedAwake(phase, duration: phaseDuration, endedAt: deadline)
        advance(afterCompleting: true)

        if Defaults[.pomodoroAutoStartNextPhase] {
            // Each auto-started phase began when the previous one ended, so
            // after a long sleep, replay the phases that would have run in
            // the meantime to keep the cycle in step with real time.
            var nextPhaseEnd = lastPhaseEnd + .seconds(configuredDuration(for: phase))
            while nextPhaseEnd <= .now {
                lastPhaseEnd = nextPhaseEnd
                finishedPhase = phase
                recordIfWorkEndedAwake(phase, duration: configuredDuration(for: phase), endedAt: nextPhaseEnd)
                advance(afterCompleting: true)
                nextPhaseEnd = lastPhaseEnd + .seconds(configuredDuration(for: phase))
            }
            run(until: nextPhaseEnd)
        }

        let isStale = ContinuousClock.now - lastPhaseEnd > Self.staleCompletionThreshold
        announceCompletion(of: finishedPhase, next: phase, isStale: isStale)
    }

    /// Statistics count a work period that ran out only if it ended while
    /// the Mac was awake: periods that ended during the last sleep are left
    /// out, and so is anything handled long after its end (stale) in case a
    /// sleep notification was missed.
    private func recordIfWorkEndedAwake(_ phase: PomodoroPhase, duration: TimeInterval, endedAt end: ContinuousClock.Instant) {
        guard phase == .work else { return }
        if let sleep = sleepStartedAt.map({ $0...ContinuousClock.now }) ?? lastSleep, sleep.contains(end) {
            return
        }
        let sinceEnd = ContinuousClock.now - end
        guard sinceEnd <= Self.staleCompletionThreshold else { return }
        let endDate = Date().addingTimeInterval(-Self.seconds(sinceEnd))
        PomodoroStatsStore.shared.recordWorkPeriod(seconds: duration, endedAt: endDate)
    }

    private func advance(afterCompleting completed: Bool) {
        switch phase {
        case .work:
            let sessionsBeforeLongBreak = max(1, Defaults[.pomodoroSessionsBeforeLongBreak])
            if completed {
                completedWorkSessions += 1
            }
            // Only a finished work period can earn the long break, even if
            // the setting was lowered below the count mid-cycle.
            phase = completed && completedWorkSessions >= sessionsBeforeLongBreak ? .longBreak : .shortBreak
        case .shortBreak:
            phase = .work
        case .longBreak:
            completedWorkSessions = 0
            phase = .work
        }

        stopTimer()
        pausedRemaining = nil
        startedPhaseDuration = nil
        phaseID = UUID()
    }

    // MARK: - Completion feedback

    private func announceCompletion(of finishedPhase: PomodoroPhase, next nextPhase: PomodoroPhase, isStale: Bool) {
        let message = Self.completionMessage(finished: finishedPhase, next: nextPhase)
        // Opens even over fullscreen apps: the user wants the phase change
        // to be impossible to miss.
        let opensNotch = !isStale
            && Defaults[.pomodoroOpenNotchOnFinish]
            && Self.canShowPomodoroTab

        if Defaults[.pomodoroSystemNotification] {
            // When the notch already shows it, the notification only needs
            // to land quietly in Notification Center, not as a second banner.
            postNotification(message: message, next: nextPhase, isPassive: opensNotch)
        }

        guard !isStale else { return }
        showCompletionMessage(message)

        if opensNotch {
            NotchUIEventBus.events.send(.openNotch(view: .pomodoro))
        }
        if Defaults[.pomodoroPlaySound] {
            play(Defaults[.pomodoroSound])
        }
    }

    /// The tab only exists when enabled, and compact mode has no tabs.
    static var canShowPomodoroTab: Bool {
        Defaults[.showPomodoroTab] && !Defaults[.compactMode]
    }

    private func updateIdleState() {
        idleTask?.cancel()
        if isRunning {
            isTimerIdle = false
        } else {
            idleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                guard !Task.isCancelled, let self else { return }
                withAnimation {
                    self.isTimerIdle = !self.isRunning
                }
            }
        }
    }

    // MARK: - Sound

    /// Plays a sound once, e.g. to preview it from settings.
    func play(_ sound: PomodoroSound) {
        switch sound {
        case .alarm:
            audioPlayer.play(fileName: Self.alarmSoundFileName, fileExtension: Self.alarmSoundFileExtension)
        default:
            audioPlayer.play(systemSoundNamed: sound.rawValue)
        }
    }

    /// Any interaction with the timer silences a still-ringing alarm.
    func stopAlarm() {
        audioPlayer.stop()
    }

    private static func completionMessage(finished: PomodoroPhase, next: PomodoroPhase) -> String {
        switch (finished, next) {
        case (.work, .longBreak):
            String(localized: "You completed a full cycle — time for a well-deserved long break.")
        case (.work, _):
            String(localized: "You crushed this work period — time for a well-deserved rest.")
        case (.shortBreak, _), (.longBreak, _):
            String(localized: "Time to head back to work — let's go!")
        }
    }

    private func showCompletionMessage(_ message: String) {
        completionMessageTask?.cancel()
        completionMessage = message
        completionMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.completionMessage = nil
        }
    }

    // MARK: - Notifications

    func refreshNotificationAuthorization() async {
        notificationAuthorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Prompts if the user hasn't decided yet (the system only ever prompts
    /// once), and reports whether notifications can be delivered.
    @discardableResult
    func requestNotificationAuthorizationIfNeeded() async -> Bool {
        guard Defaults[.pomodoroSystemNotification] else { return false }

        await refreshNotificationAuthorization()
        if notificationAuthorization == .notDetermined {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            } catch {
                Log.notifications.error("Pomodoro notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
            await refreshNotificationAuthorization()
        }

        return notificationAuthorization == .authorized || notificationAuthorization == .provisional
    }

    private func registerNotificationCategories() {
        let skip = UNNotificationAction(identifier: Self.skipAction, title: String(localized: "Skip"))
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.nextBreakCategory,
                actions: [UNNotificationAction(identifier: Self.startAction, title: String(localized: "Start Break")), skip],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.nextWorkCategory,
                actions: [UNNotificationAction(identifier: Self.startAction, title: String(localized: "Start Work")), skip],
                intentIdentifiers: []
            )
        ])
    }

    private func postNotification(message: String, next nextPhase: PomodoroPhase, isPassive: Bool) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Pomodoro")
        content.body = message
        // The alarm sound is played (or not) by the app itself, per settings.
        content.sound = nil
        content.interruptionLevel = isPassive ? .passive : .active
        // Start/Skip actions only make sense while the next phase waits.
        if !isRunning {
            content.categoryIdentifier = nextPhase == .work ? Self.nextWorkCategory : Self.nextBreakCategory
        }

        content.userInfo = [Self.phaseIDKey: phaseID.uuidString]

        let request = UNNotificationRequest(identifier: Self.notificationIdentifier, content: content, trigger: nil)
        Task {
            // Notifications may have been enabled mid-phase, after start()
            // last asked; a denied state is surfaced in Pomodoro settings.
            guard await requestNotificationAuthorizationIfNeeded() else { return }
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                Log.notifications.error("Pomodoro notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleNotificationResponse(actionIdentifier: String, phaseID notifiedPhaseID: String?) {
        stopAlarm()
        // Start/Skip only apply while the announced phase is still waiting
        // untouched — not once it was started, paused, or moved past.
        let isAnnouncedPhaseWaiting = notifiedPhaseID == phaseID.uuidString && isRunning == false && pausedRemaining == nil
        switch actionIdentifier {
        case Self.startAction:
            if isAnnouncedPhaseWaiting { start() }
        case Self.skipAction:
            if isAnnouncedPhaseWaiting { skip() }
        default:
            guard Self.canShowPomodoroTab else { return }
            NotchUIEventBus.events.send(.openNotch(view: .pomodoro))
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

extension PomodoroManager: UNUserNotificationCenterDelegate {
    /// Show the banner even while the app is active (e.g. Settings is open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// Clicking the notification brings up the Pomodoro tab; its actions
    /// start or skip the waiting phase.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == Self.notificationIdentifier else { return }
        let actionIdentifier = response.actionIdentifier
        let phaseID = response.notification.request.content.userInfo[Self.phaseIDKey] as? String
        await handleNotificationResponse(actionIdentifier: actionIdentifier, phaseID: phaseID)
    }
}
