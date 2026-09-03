import AVFoundation
import SwiftUI

struct Banners: View {
    @Environment(AppStore.self) private var store
    @State private var installError: String?
    @State private var micStatus = Permissions.microphoneStatus()

    var body: some View {
        VStack(spacing: 6) {
            if !DriverClient.isInstalled {
                banner(icon: "exclamationmark.triangle.fill", tint: .orange,
                       text: "The Where Sound Meet audio driver is not installed. Virtual devices need it.") {
                    Button("Install Driver…") { install() }
                }
            } else if let err = store.engine.driverError {
                banner(icon: "exclamationmark.triangle.fill", tint: Theme.red, text: err) {
                    Button("Retry") { store.retryDriver() }
                }
            }
            if let msg = store.installMessage {
                banner(icon: "info.circle.fill", tint: Theme.teal, text: msg) {
                    Button("Dismiss") { store.installMessage = nil }
                }
            }
            if let installError {
                banner(icon: "xmark.octagon.fill", tint: Theme.red, text: installError) {
                    Button("Dismiss") { self.installError = nil }
                }
            }
            if micStatus == .denied || micStatus == .restricted {
                banner(icon: "mic.slash.fill", tint: Theme.red, text: "Microphone access is denied. Input device sources will be silent.") {
                    Button("Open Settings") { Permissions.openMicrophoneSettings() }
                }
            }
            if let id = store.selectedID, let err = store.engine.errors[id] {
                banner(icon: "waveform.slash", tint: Theme.red, text: err) {
                    Button("Audio Capture Settings") { Permissions.openAudioCaptureSettings() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, store.engine.driverError == nil && DriverClient.isInstalled && installError == nil ? 0 : 8)
        .task {
            if micStatus == .notDetermined { _ = await Permissions.requestMicrophone(); micStatus = Permissions.microphoneStatus() }
        }
    }

    private func banner<A: View>(icon: String, tint: Color, text: String, @ViewBuilder action: () -> A) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).lineLimit(2)
            Spacer()
            action()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(tint.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }

    private func install() {
        do {
            try DriverClient.installDriver()
            installError = nil
            store.retryDriver()
        } catch {
            installError = error.localizedDescription
        }
    }
}
