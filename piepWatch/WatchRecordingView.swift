import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct WatchRecordingView: View {
    let recorder: WatchAudioRecorder

    var body: some View {
        TabView {
            recordingPage
            sessionsPage
        }
        .tabViewStyle(.page)
    }

    private var recordingPage: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.2), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: recorder.progress)
                    .stroke(
                        recorder.isRecording ? .red : .accentColor,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Button {
                    recorder.toggleRecording()
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 68, height: 68)
                        .background(
                            recorder.isRecording ? Color.red : Color.accentColor,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    recorder.isRecording ? "Aufnahme stoppen" : "Aufnahme starten"
                )
            }
            .frame(width: 92, height: 92)

            Text(recorder.durationText)
                .font(.title3.monospacedDigit().weight(.semibold))

            Text(recorder.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if recorder.queuedTransferCount > 0 {
                Label("\(recorder.queuedTransferCount) in Warteschlange", systemImage: "tray.and.arrow.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
    }

    private var sessionsPage: some View {
        NavigationStack {
            Group {
                if recorder.sessions.isEmpty {
                    ContentUnavailableView(
                        "Keine Sessions",
                        systemImage: "list.bullet.rectangle"
                    )
                } else {
                    List(recorder.sessions) { session in
                        NavigationLink {
                            WatchSessionDetailView(session: session)
                        } label: {
                            WatchSessionRow(session: session)
                        }
                    }
                }
            }
            .navigationTitle("Historie")
        }
        .onAppear {
            recorder.requestSessionHistory()
        }
    }
}

struct WatchSessionRow: View {
    let session: WatchSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.sourceLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
                Spacer()
                Text(session.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
            Text(session.dateText)
                .font(.headline)
                .lineLimit(1)
            Text("\(session.durationText) · \(session.detections.count) Arten")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(session.locationText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        session.analysisStatusRawValue == "analyzing" ? .orange : .secondary
    }
}

struct WatchSessionDetailView: View {
    let session: WatchSessionSummary

    var body: some View {
        List {
            Section {
                LabeledContent("Quelle", value: session.sourceLabel)
                LabeledContent("Status", value: session.statusLabel)
                LabeledContent("Dauer", value: session.durationText)
                LabeledContent("Ort", value: session.locationText)
            }

            Section("Vögel") {
                if session.detections.isEmpty {
                    Text(
                        session.analysisStatusRawValue == "analyzing"
                            ? "Analyse läuft noch"
                            : "Keine Treffer"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(session.detections) { detection in
                        WatchDetectionRow(detection: detection)
                    }
                }
            }
        }
        .navigationTitle(session.sourceLabel)
    }
}

struct WatchDetectionRow: View {
    let detection: WatchSessionDetectionSummary

    var body: some View {
        HStack(spacing: 8) {
            WatchThumbnail(data: detection.thumbnailData)
            VStack(alignment: .leading, spacing: 2) {
                Text(detection.commonName)
                    .font(.headline)
                    .lineLimit(1)
                Text(detection.scientificName)
                    .font(.caption2)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(detection.count)x · \(Int(detection.confidence * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct WatchThumbnail: View {
    let data: Data?

    var body: some View {
        Group {
#if canImport(UIKit)
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
#else
            fallback
#endif
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var fallback: some View {
        Image(systemName: "bird.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
            .background(.thinMaterial)
    }
}
