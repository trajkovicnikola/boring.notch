//
//  SpotifyController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class SpotifyController: MediaControllerProtocol {
    func setFavorite(_ favorite: Bool) async {
        // Placeholder
    }

    // MARK: - Properties
    @Published private var playbackState: PlaybackState = PlaybackState(
        bundleIdentifier: MediaAppBundleID.spotify
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        return true
    }

    var supportsFavorite: Bool { false }

    private var notificationTask: Task<Void, Never>?

    // Constant for time between command and update
    private let commandUpdateDelay: Duration = .milliseconds(25)

    private var lastArtworkURL: String?
    private var artworkFetchTask: Task<Void, Never>?
    /// The artwork URL currently being downloaded, if any.
    private var pendingArtworkURL: String?

    // Spotify can report the previous track's player position right after a
    // track change and sends no further notification once it settles, so a
    // single delayed re-read picks up the real position of the new track.
    private let trackChangeSettleDelay: Duration = .milliseconds(500)
    private var trackChangeRefreshTask: Task<Void, Never>?

    init() {
        setupPlaybackStateChangeObserver()
        Task {
            if isActive() {
                await updatePlaybackInfo()
            }
        }
    }

    private func setupPlaybackStateChangeObserver() {
        notificationTask = Task { @Sendable [weak self] in
            for await _ in AppleScriptControllerSupport.playerInfoNotifications(named: "com.spotify.client.PlaybackStateChanged") {
                await self?.updatePlaybackInfo()
            }
        }
    }

    deinit {
        notificationTask?.cancel()
        artworkFetchTask?.cancel()
        trackChangeRefreshTask?.cancel()
    }

    // MARK: - Protocol Implementation
    func play() async { await executeCommand("play") }
    func pause() async { await executeCommand("pause") }
    func togglePlay() async { await executeCommand("playpause") }
    func nextTrack() async { await executeCommand("next track") }
    func previousTrack() async {
        await executeAndRefresh("previous track")
    }

    func seek(to time: Double) async {
        await executeAndRefresh("set player position to \(time)")
    }

    func toggleShuffle() async {
        await executeAndRefresh("set shuffling to not shuffling")
    }

    func toggleRepeat() async {
        await executeAndRefresh("set repeating to not repeating")
    }

    func setVolume(_ level: Double) async {
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        await executeCommand("set sound volume to \(volumePercentage)")
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == playbackState.bundleIdentifier }
    }

    func updatePlaybackInfo() async {
        guard let descriptor = try? await fetchPlaybackInfoAsync() else { return }
        guard descriptor.numberOfItems >= 10 else { return }

        let isPlaying = descriptor.atIndex(1)?.booleanValue ?? false
        let currentTrack = descriptor.atIndex(2)?.stringValue ?? "Unknown"
        let currentTrackArtist = descriptor.atIndex(3)?.stringValue ?? "Unknown"
        let currentTrackAlbum = descriptor.atIndex(4)?.stringValue ?? "Unknown"
        let currentTime = descriptor.atIndex(5)?.doubleValue ?? 0
        let duration = (descriptor.atIndex(6)?.doubleValue ?? 0)/1000
        let isShuffled = descriptor.atIndex(7)?.booleanValue ?? false
        let isRepeating = descriptor.atIndex(8)?.booleanValue ?? false
        let volumePercentage = descriptor.atIndex(9)?.int32Value ?? 50
        let artworkURL = descriptor.atIndex(10)?.stringValue ?? ""

        var state = PlaybackState(
            bundleIdentifier: MediaAppBundleID.spotify,
            isPlaying: isPlaying,
            title: currentTrack,
            artist: currentTrackArtist,
            album: currentTrackAlbum,
            currentTime: currentTime,
            duration: duration,
            playbackRate: 1,
            isShuffled: isShuffled,
            repeatMode: isRepeating ? .all : .off,
            lastUpdated: Date(),
            artwork: nil,
            volume: Double(volumePercentage) / 100.0
        )

        if artworkURL == lastArtworkURL, let existingArtwork = self.playbackState.artwork {
            state.artwork = existingArtwork
        }

        let trackChanged = !self.playbackState.title.isEmpty
            && (currentTrack != self.playbackState.title || currentTrackArtist != self.playbackState.artist)

    playbackState = state

        if trackChanged {
            trackChangeRefreshTask?.cancel()
            trackChangeRefreshTask = Task { [weak self, trackChangeSettleDelay] in
                try? await Task.sleep(for: trackChangeSettleDelay)
                guard !Task.isCancelled else { return }
                await self?.updatePlaybackInfo()
            }
        }

        if !artworkURL.isEmpty, let url = URL(string: artworkURL) {
            guard artworkURL != lastArtworkURL || state.artwork == nil else { return }
            // Already downloading this artwork (e.g. the follow-up read after
            // a track change): let that fetch finish instead of restarting it.
            guard artworkURL != pendingArtworkURL else { return }
            artworkFetchTask?.cancel()
            pendingArtworkURL = artworkURL

            artworkFetchTask = Task {
                do {
                    let data = try await ImageService.shared.fetchImageData(from: url)

                    await MainActor.run { [weak self] in
                        guard let self, !Task.isCancelled, self.pendingArtworkURL == artworkURL else { return }
                        // Merge into the latest state rather than the one this
                        // fetch started from: a newer read may have corrected
                        // the playback position in the meantime.
                        var updatedState = self.playbackState
                        updatedState.artwork = data
                        self.playbackState = updatedState
                        self.lastArtworkURL = artworkURL
                        self.pendingArtworkURL = nil
                        self.artworkFetchTask = nil
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.pendingArtworkURL == artworkURL else { return }
                        self.pendingArtworkURL = nil
                        self.artworkFetchTask = nil
                    }
                }
            }
        }
    }

// MARK: - Private Methods

    private func executeCommand(_ command: String) async {
        await AppleScriptControllerSupport.executeCommand(command, appName: "Spotify")
    }

    private func executeAndRefresh(_ command: String) async {
        await executeCommand(command)
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    private func fetchPlaybackInfoAsync() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Spotify"
            set isRunning to true
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackPosition to player position
                set trackDuration to duration of current track
                set shuffleState to shuffling
                set repeatState to repeating
                set currentVolume to sound volume
                set artworkURL to artwork url of current track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatState, currentVolume, artworkURL}
            on error
                return {false, "Unknown", "Unknown", "Unknown", 0, 0, false, false, 50, ""}
            end try
        end tell
        """

        return try await AppleScriptHelper.execute(script)
    }
}
