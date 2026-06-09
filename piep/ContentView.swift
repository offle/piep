//
//  ContentView.swift
//  piep
//
//  Created by Ole on 02.06.26.
//

import SwiftUI
import SwiftData
import AVFoundation
import Combine
import MapKit
import UIKit
import UniformTypeIdentifiers

@MainActor
private final class BirdNameSpeaker: NSObject, AVSpeechSynthesizerDelegate {

    static let shared = BirdNameSpeaker()
    static let didSpeakNotification = Notification.Name("BirdNameSpeakerDidSpeak")
    static var isRecording = false
    static var pauseRecordingForSpeech: (() -> Void)?
    static var resumeRecordingAfterSpeech: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var speechContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(germanName: String, scientificName: String) {
        Task {
            await speakWithRecordingPause(
                germanName: germanName,
                scientificName: scientificName
            )
        }
    }

    private func speakWithRecordingPause(
        germanName: String,
        scientificName: String
    ) async {
        let shouldPauseRecording = Self.isRecording
        if shouldPauseRecording {
            Self.pauseRecordingForSpeech?()
        }
        defer {
            if shouldPauseRecording {
                Self.resumeRecordingAfterSpeech?()
            }
        }

        configureAudioSessionForSpeech()
        synthesizer.stopSpeaking(at: .immediate)
        postDidSpeakNotification(germanName)

        let germanUtterance = AVSpeechUtterance(string: germanName)
        germanUtterance.voice = AVSpeechSynthesisVoice(language: "de-DE")
        germanUtterance.rate = AVSpeechUtteranceDefaultSpeechRate
        await speak(germanUtterance)
    }

    private func configureAudioSessionForSpeech() {
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [
                    .allowAirPlay,
                    .allowBluetoothHFP,
                    .allowBluetoothA2DP,
                    .defaultToSpeaker,
                    .duckOthers,
                ]
            )
            try session.overrideOutputAudioPort(.speaker)
            try session.setActive(true)
        } catch {
            postDidSpeakNotification("Audio-Ausgabe nicht verfügbar")
        }
    }

    private func speak(_ utterance: AVSpeechUtterance) async {
        await withCheckedContinuation { continuation in
            speechContinuation?.resume()
            speechContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.finishSpeech()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.finishSpeech()
        }
    }

    private func finishSpeech() {
        speechContinuation?.resume()
        speechContinuation = nil
    }

    private func postDidSpeakNotification(_ name: String) {
        NotificationCenter.default.post(
            name: Self.didSpeakNotification,
            object: nil,
            userInfo: ["name": name]
        )
    }
}

private extension View {

    func speaksBirdName(germanName: String, scientificName: String) -> some View {
        onLongPressGesture {
            Task { @MainActor in
                BirdNameSpeaker.shared.speak(
                    germanName: germanName,
                    scientificName: scientificName
                )
            }
        }
    }
}

// MARK: - View Model

@Observable
@MainActor
final class BirdListeningViewModel {

    // MARK: Published State
    var isListening = false
    var detections: [BirdDetection] = []
    var isProcessing = false
    var audioLevel: Float = 0
    var isModelLoaded = false
    var errorMessage: String?
    var isLocationFilterEnabled = true
    var audioBufferSamples = 0
    var tapCount = 0
    var analysisCount = 0
    var skippedAnalysisCount = 0
    var lastAnalysisMessage = "Noch keine Analyse"
    var lastAudioFormat = "Audio noch nicht gestartet"
    var microphonePermission = "unbekannt"
    var lastTopCandidates: [BirdDetection] = []
    var recentDetectionEvents: [RecentBirdDetection] = []
    var activeSession: BirdSession?
    var displayedSession: BirdSession?
    var recentAnalysisDurations: [TimeInterval] = []
    var lastPreprocessingMessage = "Noch keine Audio-Vorverarbeitung"
    var detectionFlashTokens: [String: Int] = [:]

    let analysisChunkDuration: TimeInterval = 3.0
    let analysisInterval: TimeInterval = 1.0

    // MARK: Dependencies
    let locationManager = LocationManager()

    // MARK: Private
    private var classifier: BirdNETClassifier?
    private let audioInput = AudioInputController()
    private var analysisTimer: Timer?
    private var hasAppliedLocationFilter = false
    private var activeModelContext: ModelContext?
    private var isAudioPausedForSpeech = false
    private var locationNameTask: Task<Void, Never>?
    private var locationNameResolutionSessionID: UUID?

    var audioBufferFill: Double {
        min(Double(audioBufferSamples) / Double(BirdNETClassifier.chunkSamples), 1)
    }

    var audioBufferSeconds: Double {
        Double(audioBufferSamples) / 48_000
    }

    var averageRecentAnalysisDuration: TimeInterval? {
        guard !recentAnalysisDurations.isEmpty else { return nil }
        return recentAnalysisDurations.reduce(0, +)
            / Double(recentAnalysisDurations.count)
    }

    // MARK: - Lifecycle

    func loadModel() {
        updateMicrophonePermission()
        guard classifier == nil else { return }
        Task.detached { [weak self] in
            let c = BirdNETClassifier()
            await MainActor.run {
                self?.classifier = c
                self?.isModelLoaded = true
            }
        }
    }

    // MARK: - Listening Control

    func toggleListening(modelContext: ModelContext) {
        if isListening {
            stopListening(modelContext: modelContext)
        } else {
            startListening(modelContext: modelContext)
        }
    }

    private func startListening(modelContext: ModelContext) {
        guard classifier != nil else {
            errorMessage = "Modell wird noch geladen…"
            return
        }

        updateMicrophonePermission()

        // Request location for range filtering
        locationManager.requestLocation()
        hasAppliedLocationFilter = false

        do {
            try startAudioInput()

            let sessionLocation = currentLocationCoordinates()
            let listeningSession = BirdSession(
                latitude: sessionLocation?.latitude,
                longitude: sessionLocation?.longitude
            )
            modelContext.insert(listeningSession)
            activeSession = listeningSession
            displayedSession = listeningSession
            activeModelContext = modelContext
            BirdNameSpeaker.isRecording = true
            BirdNameSpeaker.pauseRecordingForSpeech = { [weak self] in
                self?.pauseAudioForSpeech()
            }
            BirdNameSpeaker.resumeRecordingAfterSpeech = { [weak self] in
                self?.resumeAudioAfterSpeech()
            }
            if let sessionLocation {
                resolveLocationName(
                    for: listeningSession,
                    latitude: sessionLocation.latitude,
                    longitude: sessionLocation.longitude
                )
            }

            isListening = true
            isAudioPausedForSpeech = false
            detections = []
            lastTopCandidates = []
            recentDetectionEvents = []
            recentAnalysisDurations = []
            lastPreprocessingMessage = "Sammle Audio"
            audioBufferSamples = 0
            tapCount = 0
            analysisCount = 0
            skippedAnalysisCount = 0
            lastAnalysisMessage = "Sammle 3 Sekunden Audio"
            errorMessage = nil

            scheduleAnalysisTimer()
        } catch {
            errorMessage = "Mikrofon-Fehler: \(error.localizedDescription)"
        }
    }

    func stopListening(modelContext: ModelContext) {
        analysisTimer?.invalidate()
        analysisTimer = nil
        audioInput.stop()
        isListening = false
        isAudioPausedForSpeech = false
        isProcessing = false
        audioLevel = 0
        audioBufferSamples = 0
        lastAnalysisMessage = "Gestoppt"
        lastPreprocessingMessage = "Gestoppt"
        hasAppliedLocationFilter = false
        locationNameTask?.cancel()
        locationNameTask = nil
        locationNameResolutionSessionID = nil
        activeSession?.endedAt = Date()
        displayedSession = activeSession ?? displayedSession
        try? modelContext.save()
        activeSession = nil
        activeModelContext = nil
        BirdNameSpeaker.isRecording = false
        BirdNameSpeaker.pauseRecordingForSpeech = nil
        BirdNameSpeaker.resumeRecordingAfterSpeech = nil
    }

    private func startAudioInput() throws {
        lastAudioFormat = try audioInput.start { [weak self] stats in
            Task { @MainActor in
                self?.audioLevel = stats.level
                self?.audioBufferSamples = stats.bufferedSamples
                self?.tapCount = stats.tapCount
            }
        }
    }

    private func scheduleAnalysisTimer() {
        analysisTimer?.invalidate()
        analysisTimer = Timer.scheduledTimer(
            withTimeInterval: analysisInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.analyzeCurrentBuffer()
            }
        }
    }

    private func pauseAudioForSpeech() {
        guard isListening, !isAudioPausedForSpeech else { return }
        isAudioPausedForSpeech = true
        analysisTimer?.invalidate()
        analysisTimer = nil
        audioInput.stop()
        audioLevel = 0
        audioBufferSamples = 0
        lastAnalysisMessage = "Sprachausgabe: Aufnahme pausiert"
    }

    private func resumeAudioAfterSpeech() {
        guard isListening, isAudioPausedForSpeech else { return }
        do {
            try startAudioInput()
            isAudioPausedForSpeech = false
            lastAnalysisMessage = "Sammle 3 Sekunden Audio"
            scheduleAnalysisTimer()
        } catch {
            errorMessage = "Mikrofon-Fehler: \(error.localizedDescription)"
        }
    }

    private func currentLocationCoordinates() -> (latitude: Double, longitude: Double)? {
        guard let latitude = locationManager.latitude,
              let longitude = locationManager.longitude
        else {
            return nil
        }

        return (latitude, longitude)
    }

    private func updateMicrophonePermission() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            microphonePermission = "erlaubt"
        case .denied:
            microphonePermission = "verweigert"
        case .undetermined:
            microphonePermission = "nicht gefragt"
        @unknown default:
            microphonePermission = "unbekannt"
        }
    }

    // MARK: - Inference

    private func analyzeCurrentBuffer() {
        guard let classifier, !isProcessing else { return }

        if let lat = locationManager.latitude,
           let lon = locationManager.longitude
        {
            updateActiveSessionLocation(latitude: lat, longitude: lon)
        }

        // Apply location filter once when location becomes available
        if !hasAppliedLocationFilter,
           let lat = locationManager.latitude,
           let lon = locationManager.longitude
        {
            updateActiveSessionLocation(latitude: lat, longitude: lon)
            Task.detached {
                classifier.updateLocationFilter(latitude: lat, longitude: lon)
            }
            hasAppliedLocationFilter = true
        }

        guard let chunk = audioInput.extractChunk(
            size: BirdNETClassifier.chunkSamples
        ) else {
            skippedAnalysisCount += 1
            audioBufferSamples = audioInput.bufferedSampleCount
            lastAnalysisMessage = String(
                format: "Warte auf Audio: %.1f / 3.0 s",
                audioBufferSeconds
            )
            return  // Not enough audio data yet
        }

        isProcessing = true
        analysisCount += 1
        lastAnalysisMessage = "Analyse \(analysisCount) läuft"

        Task.detached { [weak self] in
            let threshold = AppSettings.confidenceThreshold
            let profiles = AppSettings.audioAnalysisProfiles
            let analysisStartedAt = Date()
            var preprocessingMessages: [String] = []
            var allCandidates: [BirdDetection] = []
            var analyzedProfileCount = 0

            for profile in profiles {
                let preprocessingResult = AudioPreprocessor.process(
                    chunk,
                    settings: profile.settings
                )
                preprocessingMessages.append(
                    "\(profile.label): \(Self.preprocessingMessage(metrics: preprocessingResult.metrics))"
                )

                guard preprocessingResult.shouldAnalyze else {
                    continue
                }

                analyzedProfileCount += 1
                allCandidates.append(contentsOf: classifier.classify(
                    audioSamples: preprocessingResult.samples,
                    minimumConfidence: 0.001
                ))
            }

            let preprocessingMessage = preprocessingMessages.joined(separator: " | ")

            guard analyzedProfileCount > 0 else {
                await MainActor.run {
                    guard let self else { return }
                    self.skippedAnalysisCount += 1
                    self.lastTopCandidates = []
                    self.detections = []
                    self.lastPreprocessingMessage = preprocessingMessage
                    self.lastAnalysisMessage =
                        "Analyse \(self.analysisCount): kein relevantes Band-Signal"
                    self.isProcessing = false
                }
                return
            }

            let candidates = Self.mergedDetectionsByBestConfidence(allCandidates)
            let analysisDuration = Date().timeIntervalSince(analysisStartedAt)
            let results = candidates.filter {
                $0.confidence >= threshold
            }
            await MainActor.run {
                guard let self else { return }
                self.recordAnalysisDuration(analysisDuration)
                self.lastTopCandidates = candidates
                self.detections = results
                self.lastPreprocessingMessage = preprocessingMessage
                self.recordRecentDetectionEvents(results)
                self.recordDetections(results)
                self.lastAnalysisMessage = results.isEmpty
                    ? "Analyse \(self.analysisCount): kein Treffer über \(Int(threshold * 100))%"
                    : "Analyse \(self.analysisCount): \(results.count) Treffer"
                self.isProcessing = false
            }
        }
    }

    nonisolated private static func preprocessingMessage(
        metrics: AudioPreprocessingMetrics
    ) -> String {
        String(
            format: "RMS %.4f · Band %.4f",
            metrics.inputRMS,
            metrics.bandRMS
        )
    }

    nonisolated private static func mergedDetectionsByBestConfidence(
        _ detections: [BirdDetection]
    ) -> [BirdDetection] {
        var bestBySpecies: [String: BirdDetection] = [:]

        for detection in detections {
            if let existing = bestBySpecies[detection.scientificName],
               existing.confidence >= detection.confidence
            {
                continue
            }

            bestBySpecies[detection.scientificName] = detection
        }

        return bestBySpecies.values.sorted { $0.confidence > $1.confidence }
    }

    private func recordAnalysisDuration(_ duration: TimeInterval) {
        recentAnalysisDurations.append(duration)
        if recentAnalysisDurations.count > 5 {
            recentAnalysisDurations.removeFirst(
                recentAnalysisDurations.count - 5
            )
        }
    }

    private func recordRecentDetectionEvents(_ detections: [BirdDetection]) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-60)
        recentDetectionEvents.removeAll { $0.detectedAt < cutoff }

        recentDetectionEvents.append(
            contentsOf: detections.map {
                RecentBirdDetection(detection: $0, detectedAt: now)
            }
        )

        recentDetectionEvents.sort {
            if $0.detectedAt != $1.detectedAt {
                return $0.detectedAt > $1.detectedAt
            }

            return $0.confidence > $1.confidence
        }
    }

    private func updateActiveSessionLocation(latitude: Double, longitude: Double) {
        guard let activeSession else { return }
        if activeSession.latitude == nil || activeSession.longitude == nil {
            activeSession.latitude = latitude
            activeSession.longitude = longitude
            resolveLocationName(
                for: activeSession,
                latitude: latitude,
                longitude: longitude
            )
        } else if activeSession.locationName?.isEmpty ?? true {
            resolveLocationName(
                for: activeSession,
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    private func resolveLocationName(
        for session: BirdSession,
        latitude: Double,
        longitude: Double
    ) {
        guard session.locationName?.isEmpty ?? true else { return }
        guard locationNameResolutionSessionID != session.id else { return }
        let sessionID = session.id
        locationNameResolutionSessionID = sessionID
        locationNameTask?.cancel()
        locationNameTask = Task { [weak self] in
            let name = await SessionLocationNameResolver.resolve(
                latitude: latitude,
                longitude: longitude
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.locationNameTask = nil
                self.locationNameResolutionSessionID = nil
                guard let name else { return }
                guard self.activeSession?.id == sessionID
                    || self.displayedSession?.id == sessionID
                else {
                    return
                }

                session.locationName = name
                try? self.activeModelContext?.save()
            }
        }
    }

    private func recordDetections(_ results: [BirdDetection]) {
        guard let activeSession, let activeModelContext else { return }

        for result in results {
            guard !result.isExcludedHumanSound else { continue }
            let detectedAt = Date()

            if let existing = activeSession.detections.first(where: {
                $0.scientificName == result.scientificName
            }) {
                let didIncrementCount = existing.merge(
                    confidence: result.confidence,
                    detectedAt: detectedAt,
                    countCooldown: 10
                )
                if didIncrementCount {
                    triggerDetectionFlash(for: result.scientificName)
                }
            } else {
                let species = birdSpecies(
                    for: result,
                    modelContext: activeModelContext
                )
                let observation = SessionSpeciesObservation(
                    species: species,
                    confidence: result.confidence,
                    detectedAt: detectedAt
                )
                observation.session = activeSession
                activeSession.observations.append(observation)
                triggerDetectionFlash(for: result.scientificName)
            }
        }

        try? activeModelContext.save()
    }

    private func triggerDetectionFlash(for scientificName: String) {
        detectionFlashTokens[scientificName, default: 0] += 1
    }

    private func birdSpecies(
        for detection: BirdDetection,
        modelContext: ModelContext
    ) -> BirdSpecies {
        let scientificName = detection.scientificName
        let descriptor = FetchDescriptor<BirdSpecies>(
            predicate: #Predicate { species in
                species.scientificName == scientificName
            }
        )

        if let existing = try? modelContext.fetch(descriptor).first {
            if existing.germanName != detection.germanName {
                existing.germanName = detection.germanName
            }
            return existing
        }

        let species = BirdSpecies(
            scientificName: detection.scientificName,
            germanName: detection.germanName
        )
        modelContext.insert(species)
        return species
    }
}

private extension BirdDetection {
    var isExcludedHumanSound: Bool {
        scientificName.hasPrefix("Human ")
            || germanName.hasPrefix("Mensch ")
    }
}

struct RecentBirdDetection: Identifiable {
    let id = UUID()
    let scientificName: String
    let germanName: String
    let confidence: Float
    let detectedAt: Date

    init(detection: BirdDetection, detectedAt: Date) {
        self.scientificName = detection.scientificName
        self.germanName = detection.germanName
        self.confidence = detection.confidence
        self.detectedAt = detectedAt
    }
}

struct BirdSpeakButton: View {

    let germanName: String
    let scientificName: String

    var body: some View {
        Button {
            Task { @MainActor in
                BirdNameSpeaker.shared.speak(
                    germanName: germanName,
                    scientificName: scientificName
                )
            }
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Name vorlesen")
    }
}

// MARK: - Main View

struct ContentView: View {

    @State private var viewModel = BirdListeningViewModel()
    @State private var spokenBirdName: String?
    @State private var speechFeedbackTask: Task<Void, Never>?
    @AppStorage(AppSettings.keepScreenOnWhileRecordingKey)
    private var keepScreenOnWhileRecording = AppSettings.defaultKeepScreenOnWhileRecording

    var body: some View {
        TabView {
            NavigationStack {
                ListeningView(viewModel: viewModel)
            }
                .tabItem {
                    Label("Zuhören", systemImage: "waveform")
                }

            SessionsView()
                .tabItem {
                    Label("Sessions", systemImage: "list.bullet.rectangle")
                }

            BirdOverviewView()
                .tabItem {
                    Label("Vögel", systemImage: "bird.fill")
                }

            BirdMapView()
                .tabItem {
                    Label("Karte", systemImage: "map.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Einstellungen", systemImage: "slider.horizontal.3")
                }
        }
        .onAppear {
            viewModel.loadModel()
            updateIdleTimerState()
        }
        .onChange(of: viewModel.isListening) { _, _ in
            updateIdleTimerState()
        }
        .onChange(of: keepScreenOnWhileRecording) { _, _ in
            updateIdleTimerState()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: BirdNameSpeaker.didSpeakNotification
            )
        ) { notification in
            guard let name = notification.userInfo?["name"] as? String else {
                return
            }
            showSpeechFeedback(name)
        }
        .overlay(alignment: .top) {
            if let spokenBirdName {
                SpeechFeedbackBanner(name: spokenBirdName)
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.28), value: spokenBirdName)
        .animation(.spring(duration: 0.28), value: viewModel.isListening)
    }

    private func showSpeechFeedback(_ name: String) {
        speechFeedbackTask?.cancel()
        spokenBirdName = name
        speechFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            spokenBirdName = nil
        }
    }

    private func updateIdleTimerState() {
        UIApplication.shared.isIdleTimerDisabled =
            keepScreenOnWhileRecording && viewModel.isListening
    }
}

struct SpeechFeedbackBanner: View {

    let name: String

    var body: some View {
        Label("Spricht: \(name)", systemImage: "speaker.wave.2.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            )
    }
}

@MainActor
private func cleanupOrphanedBirdSpecies(in modelContext: ModelContext) {
    let descriptor = FetchDescriptor<BirdSpecies>()
    guard let species = try? modelContext.fetch(descriptor) else {
        return
    }

    var didDeleteSpecies = false
    for item in species where item.relevantObservations.isEmpty {
        modelContext.delete(item)
        didDeleteSpecies = true
    }

    if didDeleteSpecies {
        try? modelContext.save()
    }
}

// MARK: - Listening View

struct ListeningView: View {

    @Bindable var viewModel: BirdListeningViewModel
    @Environment(\.modelContext) private var modelContext
    @State private var isDebugPresented = false
    @State private var isConfirmingDisplayedSessionDeletion = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            .ignoresSafeArea()

            VStack(spacing: 0) {
                listeningHeaderBar
                    .padding(.top, 8)

                detectionList
                    .padding(.top, 10)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
        .alert(
            "Fehler",
            isPresented: .init(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $isDebugPresented) {
            ListeningDebugView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Listening Header

    private var listeningHeaderBar: some View {
        HStack(spacing: 12) {
            listenButton

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    listeningStateDot
                    Text(primaryListeningText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(secondaryListeningText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if viewModel.displayedSession == nil || !viewModel.locationManager.hasLocation {
                    locationBadge
                }
            }

            Spacer(minLength: 0)

            if !viewModel.isModelLoaded {
                ProgressView()
                    .tint(.secondary)
            }

            VStack(spacing: 6) {
                Button {
                    isDebugPresented = true
                } label: {
                    Image(systemName: "questionmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(.regularMaterial)
                                .stroke(.quaternary, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Debug anzeigen")

                if canDeleteDisplayedSession {
                    Button(role: .destructive) {
                        isConfirmingDisplayedSessionDeletion = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0.95, green: 0.40, blue: 0.35))
                    .accessibilityLabel("Letzte Session löschen")
                    .popover(
                        isPresented: $isConfirmingDisplayedSessionDeletion,
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .top
                    ) {
                        DeleteDisplayedSessionPopover(
                            onCancel: {
                                isConfirmingDisplayedSessionDeletion = false
                            },
                            onDelete: {
                                deleteDisplayedSession()
                                isConfirmingDisplayedSessionDeletion = false
                            }
                        )
                        .presentationCompactAdaptation(.popover)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .stroke(.quaternary, lineWidth: 0.5)
        )
    }

    private var listeningStateDot: some View {
        ZStack {
            Circle()
                .fill(viewModel.isListening ? Color(red: 0.95, green: 0.22, blue: 0.18) : .secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            if viewModel.isListening {
                Circle()
                    .stroke(Color(red: 0.95, green: 0.22, blue: 0.18).opacity(0.45), lineWidth: 2)
                    .frame(
                        width: 16 + CGFloat(min(viewModel.audioLevel * 80, 10)),
                        height: 16 + CGFloat(min(viewModel.audioLevel * 80, 10))
                    )
            }
        }
        .frame(width: 20, height: 20)
    }

    private var primaryListeningText: String {
        if !viewModel.isModelLoaded {
            return "Modell wird geladen"
        }

        if let session = viewModel.displayedSession {
            let state = viewModel.isListening ? "Höre zu" : "Letzte Session"
            return "\(state) · \(session.locationDescription)"
        }

        return "Bereit"
    }

    private var secondaryListeningText: String {
        guard let session = viewModel.displayedSession else {
            return viewModel.isListening
                ? viewModel.lastAnalysisMessage
                : "Startet eine neue Session"
        }

        let duration = Self.durationFormatter.string(from: session.duration) ?? "0:00"
        let count = session.reviewedDetections.count
        let speciesText = count == 1 ? "1 Art" : "\(count) Arten"

        if viewModel.isListening {
            return "\(duration) · \(speciesText) · \(viewModel.lastAnalysisMessage)"
        }

        return "\(duration) · \(speciesText)"
    }

    private var canDeleteDisplayedSession: Bool {
        !viewModel.isListening && viewModel.displayedSession != nil
    }

    // MARK: - Location Badge

    private var locationBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: viewModel.locationManager.hasLocation
                  ? "location.fill" : "location.slash")
                .font(.system(size: 11))
            Text(viewModel.locationManager.statusMessage)
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(.thinMaterial)
                .stroke(.quaternary, lineWidth: 0.5)
        )
    }

    // MARK: - Listen Button

    private var listenButton: some View {
        Button(action: { viewModel.toggleListening(modelContext: modelContext) }) {
            ZStack {
                // Outer pulse rings (when listening)
                if viewModel.isListening {
                    PulseRing(delay: 0.0, size: 58)
                    PulseRing(delay: 0.6, size: 58)
                    PulseRing(delay: 1.2, size: 58)
                }

                // Audio level ring
                Circle()
                    .stroke(
                        viewModel.isListening
                            ? Color.accentColor
                            : .secondary.opacity(0.28),
                        lineWidth: viewModel.isListening
                            ? 3 + CGFloat(viewModel.audioLevel * 30) : 2
                    )
                    .frame(width: 56, height: 56)
                    .animation(
                        .easeOut(duration: 0.15),
                        value: viewModel.audioLevel
                    )

                // Inner circle
                Circle()
                    .fill(
                        viewModel.isListening
                            ? LinearGradient(
                                colors: [
                                    Color(red: 0.20, green: 0.65, blue: 0.40),
                                    Color.accentColor,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [
                                    .secondary.opacity(0.18),
                                    .secondary.opacity(0.08),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
                    .frame(width: 50, height: 50)

                // Icon
                Image(
                    systemName: viewModel.isListening
                        ? "waveform" : "mic.fill"
                )
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(viewModel.isListening ? .white : .primary)
                .symbolEffect(
                    .variableColor.iterative,
                    isActive: viewModel.isListening
                )
            }
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isModelLoaded)
        .opacity(viewModel.isModelLoaded ? 1 : 0.5)
    }

    // MARK: - Detection List

    private var detectionList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let session = viewModel.displayedSession {
                    ForEach(session.reviewedDetections.sortedForListening) { detection in
                        if let species = detection.species {
                            NavigationLink {
                                BirdSpeciesDetailView(species: species)
                            } label: {
                                SessionDetectionCard(
                                    detection: detection,
                                    flashToken: viewModel.detectionFlashTokens[
                                        detection.scientificName,
                                        default: 0
                                    ]
                                )
                            }
                            .buttonStyle(.plain)
                            .transition(.asymmetric(
                                    insertion: .move(edge: .bottom)
                                        .combined(with: .opacity),
                                    removal: .opacity
                                ))
                        } else {
                            SessionDetectionCard(
                                detection: detection,
                                flashToken: viewModel.detectionFlashTokens[
                                    detection.scientificName,
                                    default: 0
                                ]
                            )
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom)
                                        .combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    }

                } else {
                    ForEach(viewModel.detections) { detection in
                        DetectionCard(detection: detection)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom)
                                    .combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
            }
            .animation(.spring(duration: 0.4), value: viewModel.detections)
            .animation(
                .spring(duration: 0.4),
                value: viewModel.displayedSession?.detections.map(\.id) ?? []
            )
        }
        .scrollIndicators(.hidden)
    }

    private func deleteDisplayedSession() {
        guard !viewModel.isListening, let session = viewModel.displayedSession else {
            return
        }

        for detection in session.detections {
            modelContext.delete(detection)
        }
        modelContext.delete(session)
        try? modelContext.save()
        cleanupOrphanedBirdSpecies(in: modelContext)

        viewModel.displayedSession = nil
        viewModel.detections = []
        viewModel.lastTopCandidates = []
        viewModel.recentDetectionEvents = []
        viewModel.lastAnalysisMessage = "Session gelöscht"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()
}

struct DeleteDisplayedSessionPopover: View {

    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Letzte Session löschen?", systemImage: "trash")
                .font(.headline)

            Text("Die angezeigte Session und ihre Vogel-Liste werden entfernt.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Abbrechen", action: onCancel)
                    .buttonStyle(.bordered)

                Spacer()

                Button("Löschen", role: .destructive, action: onDelete)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.95, green: 0.40, blue: 0.35))
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

struct ListeningDebugView: View {

    let viewModel: BirdListeningViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    ProgressView(value: viewModel.audioBufferFill) {
                        Text("Buffer")
                    } currentValueLabel: {
                        Text(String(format: "%.1f s", viewModel.audioBufferSeconds))
                    }
                    .tint(Color(red: 0.20, green: 0.65, blue: 0.40))

                    LabeledContent("Pegel", value: String(format: "%.3f", viewModel.audioLevel))
                    LabeledContent("Mikrofon", value: viewModel.microphonePermission)
                    LabeledContent("Format", value: viewModel.lastAudioFormat)
                    LabeledContent("Preprocessing", value: viewModel.lastPreprocessingMessage)
                    LabeledContent("Taps", value: "\(viewModel.tapCount)")
                }

                Section("Analyse") {
                    LabeledContent(
                        "Chunklänge",
                        value: String(format: "%.0f s", viewModel.analysisChunkDuration)
                    )
                    LabeledContent(
                        "Analyse-Takt",
                        value: String(format: "%.0f s", viewModel.analysisInterval)
                    )
                    LabeledContent("Analysen", value: "\(viewModel.analysisCount)")
                    LabeledContent("Übersprungen", value: "\(viewModel.skippedAnalysisCount)")
                    LabeledContent(
                        "Ø letzte 5",
                        value: averageAnalysisDurationText
                    )
                    Text(viewModel.lastAnalysisMessage)
                        .foregroundStyle(.secondary)
                }

                if !viewModel.lastTopCandidates.isEmpty {
                    Section("Top roh") {
                        ForEach(viewModel.lastTopCandidates.prefix(5)) { detection in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(detection.germanName)
                                    Text(detection.scientificName)
                                        .font(.caption)
                                        .italic()
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(String(format: "%.1f%%", detection.confidence * 100))
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                Section("Letzte 60 Sekunden") {
                    if viewModel.recentDetectionEvents.isEmpty {
                        Text("Noch keine Treffer im Zeitfenster.")
                            .foregroundStyle(.secondary)
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            ForEach(viewModel.recentDetectionEvents) { event in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.germanName)
                                        Text(event.scientificName)
                                            .font(.caption)
                                            .italic()
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(String(format: "%.1f%%", event.confidence * 100))
                                            .monospacedDigit()
                                        Text(ageText(for: event, now: context.date))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var averageAnalysisDurationText: String {
        guard let duration = viewModel.averageRecentAnalysisDuration else {
            return "noch keine Daten"
        }

        return String(format: "%.2f s", duration)
    }

    private func ageText(for event: RecentBirdDetection, now: Date) -> String {
        let age = max(0, Int(now.timeIntervalSince(event.detectedAt).rounded()))
        return age == 1 ? "vor 1 s" : "vor \(age) s"
    }
}

private extension Array where Element == SessionBirdDetection {
    var sortedForDisplay: [SessionBirdDetection] {
        sorted {
            if $0.bestConfidence != $1.bestConfidence {
                return $0.bestConfidence > $1.bestConfidence
            }

            return $0.lastDetectedAt > $1.lastDetectedAt
        }
    }

    var sortedForListening: [SessionBirdDetection] {
        sorted {
            if $0.detectionCount != $1.detectionCount {
                return $0.detectionCount > $1.detectionCount
            }

            if $0.bestConfidence != $1.bestConfidence {
                return $0.bestConfidence > $1.bestConfidence
            }

            return $0.lastDetectedAt > $1.lastDetectedAt
        }
    }
}

// MARK: - Bird Map View

struct BirdMapView: View {

    @Query(sort: \BirdSession.startedAt, order: .reverse)
    private var sessions: [BirdSession]
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var selectedLocationPin: BirdMapLocationPin?

    var body: some View {
        NavigationStack {
            Group {
                if observations.isEmpty {
                    ContentUnavailableView(
                        "Keine Kartenpunkte",
                        systemImage: "map",
                        description: Text("Sessions mit Standort erscheinen hier.")
                    )
                } else {
                    Map(position: $cameraPosition) {
                        if shouldCluster {
                            ForEach(clusterPins) { pin in
                                Annotation("", coordinate: pin.coordinate) {
                                    Button {
                                        selectedLocationPin = pin.location
                                    } label: {
                                        BirdMapClusterBubble(pin: pin)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } else {
                            ForEach(speciesPins) { pin in
                                Annotation("", coordinate: pin.coordinate) {
                                    Button {
                                        selectedLocationPin = pin.location
                                    } label: {
                                        BirdMapSpeciesMarker(pin: pin)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .mapControls {
                        MapCompass()
                        MapScaleView()
                    }
                    .onAppear {
                        cameraPosition = initialCameraPosition
                    }
                    .onMapCameraChange(frequency: .onEnd) { context in
                        visibleRegion = context.region
                    }
                }
            }
            .navigationTitle("Karte")
            .sheet(item: $selectedLocationPin) { pin in
                BirdMapLocationDetailView(pin: pin)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var observations: [BirdMapObservation] {
        sessions.flatMap { session -> [BirdMapObservation] in
            guard let latitude = session.latitude,
                  let longitude = session.longitude
            else {
                return []
            }

            var seenSpecies = Set<String>()
            return session.visibleDetections.sortedForDisplay.compactMap { detection in
                guard seenSpecies.insert(detection.scientificName).inserted else {
                    return nil
                }

                return BirdMapObservation(
                    sessionID: session.id,
                    startedAt: session.startedAt,
                    coordinate: CLLocationCoordinate2D(
                        latitude: latitude,
                        longitude: longitude
                    ),
                    locationName: session.locationDescription,
                    species: detection.species,
                    scientificName: detection.scientificName,
                    germanName: detection.germanName,
                    confidence: detection.bestConfidence
                )
            }
        }
    }

    private var shouldCluster: Bool {
        guard let visibleRegion else {
            return observations.count > 12
        }

        return max(
            visibleRegion.span.latitudeDelta,
            visibleRegion.span.longitudeDelta
        ) > 0.25
    }

    private var speciesPins: [BirdMapSpeciesPin] {
        let grouped = Dictionary(grouping: observations) {
            Self.nearbyLocationKey(for: $0.coordinate)
        }

        return grouped.values.flatMap { observations in
            let sorted = Self.uniqueSpecies(from: observations).sorted {
                if $0.confidence != $1.confidence {
                    return $0.confidence > $1.confidence
                }

                return $0.germanName.localizedCaseInsensitiveCompare($1.germanName) == .orderedAscending
            }
            let center = Self.averageCoordinate(for: observations)
            let location = BirdMapLocationPin(
                id: Self.coordinateKey(center),
                coordinate: center,
                locationName: Self.locationName(from: observations),
                observations: sorted
            )

            return sorted.enumerated().map { index, observation in
                BirdMapSpeciesPin(
                    id: "\(location.id)-\(observation.scientificName)",
                    coordinate: Self.offsetCoordinate(
                        center,
                        index: index,
                        count: sorted.count
                    ),
                    observation: observation,
                    location: location
                )
            }
        }
        .sorted { $0.observation.startedAt > $1.observation.startedAt }
    }

    private var clusterPins: [BirdMapClusterPin] {
        guard !observations.isEmpty else { return [] }

        let span = visibleRegion?.span
        let cellSize = max(
            0.03,
            max(span?.latitudeDelta ?? 0.5, span?.longitudeDelta ?? 0.5) / 8
        )
        let grouped = Dictionary(grouping: observations) {
            Self.gridKey(for: $0.coordinate, cellSize: cellSize)
        }

        return grouped.values.map { observations in
            let species = Self.uniqueSpecies(from: observations).sorted {
                if $0.confidence != $1.confidence {
                    return $0.confidence > $1.confidence
                }

                return $0.germanName.localizedCaseInsensitiveCompare($1.germanName) == .orderedAscending
            }
            let coordinate = Self.averageCoordinate(for: observations)
            let location = BirdMapLocationPin(
                id: Self.coordinateKey(coordinate),
                coordinate: coordinate,
                locationName: Self.locationName(from: observations),
                observations: species
            )
            return BirdMapClusterPin(
                id: species.map(\.scientificName).sorted().joined(separator: "-")
                    + "-\(Self.coordinateKey(coordinate))",
                coordinate: coordinate,
                speciesCount: species.count,
                observationCount: species.count,
                location: location
            )
        }
        .sorted {
            if $0.speciesCount != $1.speciesCount {
                return $0.speciesCount > $1.speciesCount
            }

            return $0.observationCount > $1.observationCount
        }
    }

    private var initialCameraPosition: MapCameraPosition {
        guard !observations.isEmpty else {
            return .automatic
        }

        let latitudes = observations.map { $0.coordinate.latitude }
        let longitudes = observations.map { $0.coordinate.longitude }
        guard let minLat = latitudes.min(),
              let maxLat = latitudes.max(),
              let minLon = longitudes.min(),
              let maxLon = longitudes.max()
        else {
            return .automatic
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(0.04, (maxLat - minLat) * 1.8),
                longitudeDelta: max(0.04, (maxLon - minLon) * 1.8)
            )
        )
        return .region(region)
    }

    private static func coordinateKey(_ coordinate: CLLocationCoordinate2D) -> String {
        String(
            format: "%.5f-%.5f",
            coordinate.latitude,
            coordinate.longitude
        )
    }

    private static func nearbyLocationKey(for coordinate: CLLocationCoordinate2D) -> String {
        let cellSizeInMeters = 50.0
        let latitudeCellSize = cellSizeInMeters / 111_320.0
        let longitudeCellSize = cellSizeInMeters
            / (111_320.0 * max(0.2, cos(coordinate.latitude * .pi / 180)))
        let latitudeBucket = Int(floor(coordinate.latitude / latitudeCellSize))
        let longitudeBucket = Int(floor(coordinate.longitude / longitudeCellSize))
        return "\(latitudeBucket)-\(longitudeBucket)"
    }

    private static func gridKey(
        for coordinate: CLLocationCoordinate2D,
        cellSize: Double
    ) -> String {
        let latitudeBucket = Int(floor(coordinate.latitude / cellSize))
        let longitudeBucket = Int(floor(coordinate.longitude / cellSize))
        return "\(latitudeBucket)-\(longitudeBucket)"
    }

    private static func averageCoordinate(
        for observations: [BirdMapObservation]
    ) -> CLLocationCoordinate2D {
        let latitude = observations.map { $0.coordinate.latitude }.reduce(0, +)
            / Double(observations.count)
        let longitude = observations.map { $0.coordinate.longitude }.reduce(0, +)
            / Double(observations.count)
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private static func uniqueSpecies(
        from observations: [BirdMapObservation]
    ) -> [BirdMapObservation] {
        var bestBySpecies: [String: BirdMapObservation] = [:]

        for observation in observations {
            guard let existing = bestBySpecies[observation.scientificName] else {
                bestBySpecies[observation.scientificName] = observation
                continue
            }

            if observation.confidence > existing.confidence
                || (
                    observation.confidence == existing.confidence
                    && observation.startedAt > existing.startedAt
                )
            {
                bestBySpecies[observation.scientificName] = observation
            }
        }

        return Array(bestBySpecies.values)
    }

    private static func locationName(from observations: [BirdMapObservation]) -> String {
        observations
            .sorted { $0.startedAt > $1.startedAt }
            .map(\.locationName)
            .first { !$0.isEmpty } ?? "Fundort"
    }

    private static func offsetCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        index: Int,
        count: Int
    ) -> CLLocationCoordinate2D {
        guard count > 1 else {
            return coordinate
        }

        let maxRadiusInMeters = 45.0
        let radius = min(maxRadiusInMeters, 16.0 + Double(count) * 4.0)
        let angle = (2 * Double.pi * Double(index)) / Double(count)
        let northMeters = cos(angle) * radius
        let eastMeters = sin(angle) * radius
        let latitudeOffset = northMeters / 111_320.0
        let longitudeOffset = eastMeters
            / (111_320.0 * max(0.2, cos(coordinate.latitude * .pi / 180)))

        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + latitudeOffset,
            longitude: coordinate.longitude + longitudeOffset
        )
    }
}

struct BirdMapSpeciesMarker: View {

    let pin: BirdMapSpeciesPin

    var body: some View {
        BirdThumbnail(
            scientificName: pin.observation.scientificName,
            size: 56
        )
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
        )
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .stroke(.white.opacity(0.45), lineWidth: 0.5)
        )
    }
}

struct BirdMapLocationDetailView: View {

    let pin: BirdMapLocationPin
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(pin.observations) { observation in
                        if let species = observation.species {
                            NavigationLink {
                                BirdSpeciesDetailView(species: species)
                            } label: {
                                BirdMapSpeciesRow(observation: observation)
                            }
                        } else {
                            BirdMapSpeciesRow(observation: observation)
                        }
                    }
                } header: {
                    Text(pin.speciesCount == 1 ? "1 Art an diesem Ort" : "\(pin.speciesCount) Arten an diesem Ort")
                } footer: {
                    Text(coordinateText)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(pin.locationName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var coordinateText: String {
        String(
            format: "%.5f, %.5f",
            pin.coordinate.latitude,
            pin.coordinate.longitude
        )
    }
}

struct BirdMapSpeciesRow: View {

    let observation: BirdMapObservation

    var body: some View {
        HStack(spacing: 14) {
            BirdThumbnail(scientificName: observation.scientificName, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(observation.germanName)
                        .font(.headline)
                        .lineLimit(1)
                    BirdSpeakButton(
                        germanName: observation.germanName,
                        scientificName: observation.scientificName
                    )
                    .accessibilityLabel("\(observation.germanName) vorlesen")
                }
                Text(observation.scientificName)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text("\(Int(observation.confidence * 100))%")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct BirdMapClusterBubble: View {

    let pin: BirdMapClusterPin

    var body: some View {
        VStack(spacing: 2) {
            Text("\(pin.speciesCount)")
                .font(.headline.weight(.bold).monospacedDigit())
            Image(systemName: "bird.fill")
                .font(.caption)
        }
        .foregroundStyle(.white)
        .frame(width: 48, height: 48)
        .background(
            Circle()
                .fill(Color(red: 0.20, green: 0.65, blue: 0.40))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        )
        .overlay(
            Circle()
                .stroke(.white.opacity(0.8), lineWidth: 1)
        )
    }
}

struct BirdMapObservation: Identifiable {
    let sessionID: UUID
    let startedAt: Date
    let coordinate: CLLocationCoordinate2D
    let locationName: String
    let species: BirdSpecies?
    let scientificName: String
    let germanName: String
    let confidence: Float

    var id: String {
        "\(sessionID.uuidString)-\(scientificName)"
    }
}

struct BirdMapLocationPin: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let locationName: String
    let observations: [BirdMapObservation]

    var speciesCount: Int {
        Set(observations.map(\.scientificName)).count
    }

    var lastSeenAt: Date {
        observations.map(\.startedAt).max() ?? .distantPast
    }
}

struct BirdMapSpeciesPin: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let observation: BirdMapObservation
    let location: BirdMapLocationPin
}

struct BirdMapClusterPin: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let speciesCount: Int
    let observationCount: Int
    let location: BirdMapLocationPin
}

// MARK: - Settings View

struct SettingsView: View {

    @AppStorage(AppSettings.keepScreenOnWhileRecordingKey)
    private var keepScreenOnWhileRecording = AppSettings.defaultKeepScreenOnWhileRecording
    @AppStorage(AppSettings.birdImageMaximumCountKey)
    private var birdImageMaximumCount = AppSettings.defaultBirdImageMaximumCount
    @State private var isConfirmingCacheDeletion = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("piep", systemImage: "bird.fill")
                                .font(.headline)
                            Spacer()
                            Text(appVersionText)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Text(buildTimestampText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        LabeledContent("Autor", value: "Ole Wulff")
                        LabeledContent("Kontakt", value: "offlepoffle1@icloud.com")
                        LabeledContent("App-Lizenz", value: "MIT")
                        Link(destination: URL(string: "https://offle.github.io/piep/")!) {
                            Label("Kontakt und Support", systemImage: "link")
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    HStack {
                        Label("Standortfilter", systemImage: "location.fill")
                        Spacer()
                        Text("immer aktiv")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Der erkannte Standort wird automatisch genutzt, sobald iOS ihn liefert. Treffer werden dadurch auf lokal plausible Arten eingegrenzt.")
                }

                Section {
                    Toggle(isOn: $keepScreenOnWhileRecording) {
                        Label("Display bleibt an", systemImage: "iphone")
                    }
                } footer: {
                    Text("Solange eine Aufnahme aktiv ist, verhindert die App das automatische Sperren des Bildschirms.")
                }

                Section {
                    Stepper(
                        value: $birdImageMaximumCount,
                        in: AppSettings.minimumBirdImageMaximumCount...AppSettings.maximumBirdImageMaximumCount
                    ) {
                        LabeledContent(
                            "Bilder je Vogel",
                            value: "\(birdImageMaximumCount)"
                        )
                    }
                } footer: {
                    Text("In Detailansichten können bis zu 15 freie Bilder je Vogel geladen und lokal gecacht werden.")
                }

                Section {
                    NavigationLink {
                        AppIconSelectionView()
                    } label: {
                        Label("App Icon", systemImage: "app.badge")
                    }
                } footer: {
                    Text("Hier kannst du das App Icon wechseln.")
                }

                Section {
                    NavigationLink {
                        ExpertSettingsView()
                    } label: {
                        Label("Expert", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("Feinabstimmung für Threshold, Bandpass und Band-Energy-Gate.")
                }

                Section {
                    Button(role: .destructive) {
                        isConfirmingCacheDeletion = true
                    } label: {
                        Label("Bildercache löschen", systemImage: "trash")
                    }
                } footer: {
                    Text("Geladene Vogelbilder und deren Lizenz-Metadaten werden lokal entfernt und bei Bedarf neu geladen.")
                }

                Section("Lizenzen") {
                    NavigationLink {
                        ModelLicenseInfoView()
                    } label: {
                        Label("AI-Modell für Vogelstimmen", systemImage: "brain.head.profile")
                    }

                    NavigationLink {
                        AppLicenseInfoView()
                    } label: {
                        Label("App und Bildquellen", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .confirmationDialog(
                "Bildercache wirklich löschen?",
                isPresented: $isConfirmingCacheDeletion,
                titleVisibility: .visible
            ) {
                Button("Löschen", role: .destructive) {
                    BirdImageStore.shared.clearImageCache()
                }
                Button("Abbrechen", role: .cancel) { }
            } message: {
                Text("Die App lädt Vogelbilder danach erneut aus freien Quellen, sobald sie gebraucht werden.")
            }
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "1"
        return "v\(version) (\(build))"
    }

    private var buildTimestampText: String {
        (Bundle.main.object(forInfoDictionaryKey: "PiepBuildTimestamp") as? String)
            ?? "Build-Zeit unbekannt"
    }
}

struct AppIconSelectionView: View {

    @State private var selectedIconName: String?
    @State private var errorMessage: String?
    @State private var isChangingIcon = false
    @State private var titleTapCount = 0
    @AppStorage("isSecretAppIconUnlocked")
    private var isSecretAppIconUnlocked = false

    private var choices: [AppIconChoice] {
        AppIconChoice.visibleChoices(includeSecret: isSecretAppIconUnlocked)
    }

    var body: some View {
        List {
            Section {
                ForEach(choices) { choice in
                    Button {
                        setIcon(choice)
                    } label: {
                        AppIconChoiceRow(
                            choice: choice,
                            isSelected: selectedIconName == choice.alternateIconName,
                            isChanging: isChangingIcon
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isChangingIcon || !UIApplication.shared.supportsAlternateIcons)
                }
            } footer: {
                if UIApplication.shared.supportsAlternateIcons {
                    Text("iOS fragt beim Wechsel ggf. nach einer Bestätigung.")
                } else {
                    Text("Dieses Gerät unterstützt keine alternativen App Icons.")
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("App Icon")
                    .font(.headline)
                    .onTapGesture {
                        unlockSecretIconIfNeeded()
                    }
            }
        }
        .onAppear {
            selectedIconName = UIApplication.shared.alternateIconName
        }
        .alert(
            "Icon konnte nicht gewechselt werden",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func unlockSecretIconIfNeeded() {
        guard !isSecretAppIconUnlocked else {
            return
        }

        titleTapCount += 1
        if titleTapCount >= 10 {
            isSecretAppIconUnlocked = true
        }
    }

    private func setIcon(_ choice: AppIconChoice) {
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "Alternative App Icons werden auf diesem Gerät nicht unterstützt."
            return
        }

        guard selectedIconName != choice.alternateIconName else {
            return
        }

        isChangingIcon = true
        UIApplication.shared.setAlternateIconName(choice.alternateIconName) { error in
            Task { @MainActor in
                isChangingIcon = false
                if let error {
                    errorMessage = error.localizedDescription
                } else {
                    selectedIconName = UIApplication.shared.alternateIconName
                }
            }
        }
    }
}

struct AppIconChoiceRow: View {

    let choice: AppIconChoice
    let isSelected: Bool
    let isChanging: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(choice.previewImageName)
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.quaternary, lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(choice.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(choice.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isChanging {
                ProgressView()
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 5)
    }
}

struct AppIconChoice: Identifiable, Equatable {

    let id: String
    let title: String
    let subtitle: String
    let previewImageName: String
    let alternateIconName: String?
    let isSecret: Bool

    static let all: [AppIconChoice] = [
        AppIconChoice(
            id: "default",
            title: "Piep",
            subtitle: "Aktuelles Icon",
            previewImageName: "AppIconNewPreview",
            alternateIconName: nil,
            isSecret: false
        ),
        AppIconChoice(
            id: "classic",
            title: "Piep Classic",
            subtitle: "altes Icon",
            previewImageName: "AppIconClassicPreview",
            alternateIconName: "ClassicAppIcon",
            isSecret: false
        ),
        AppIconChoice(
            id: "img0019",
            title: "Piep 0019",
            subtitle: "Icon 0019",
            previewImageName: "AppIcon0019Preview",
            alternateIconName: "AppIcon0019",
            isSecret: true
        ),
    ]

    static func visibleChoices(includeSecret: Bool) -> [AppIconChoice] {
        all.filter { includeSecret || !$0.isSecret }
    }
}

struct ModelLicenseInfoView: View {

    var body: some View {
        List {
            Section("Verwendetes Modell") {
                LabeledContent("Name", value: "BirdNET")
                LabeledContent("Version", value: "BirdNET v2")
                LabeledContent("Dateien", value: "audio-model.tflite, meta-model.tflite")
                LabeledContent("Labels", value: "BirdNET_v2/labels/de.txt")
            }

            Section("Urheber") {
                Text("BirdNET wurde vom K. Lisa Yang Center for Conservation Bioacoustics am Cornell Lab of Ornithology in Zusammenarbeit mit der Technischen Universität Chemnitz entwickelt.")
            }

            Section("Lizenz") {
                LabeledContent("Modell", value: "CC BY-NC-SA 4.0")
                Text("Die BirdNET-Modelle sind als Creative-Commons-Modellressourcen für nicht-kommerzielle Nutzung mit Namensnennung und Weitergabe unter gleichen Bedingungen lizenziert. Der BirdNET-Analyzer-Quellcode ist separat unter MIT verfügbar.")
                    .foregroundStyle(.secondary)
            }

            Section("Quelle") {
                Link(
                    "BirdNET-Analyzer auf GitHub",
                    destination: URL(string: "https://github.com/birdnet-team/BirdNET-Analyzer")!
                )
                Link(
                    "BirdNET Projektseite",
                    destination: URL(string: "https://birdnet.cornell.edu")!
                )
            }
        }
        .navigationTitle("AI-Modell")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AppLicenseInfoView: View {

    var body: some View {
        List {
            Section("App") {
                LabeledContent("Lizenz", value: "MIT")
                LabeledContent("Autor", value: "Ole Wulff")
                LabeledContent("Kontakt", value: "offlepoffle1@icloud.com")
            }

            Section("Bilder") {
                Text("Vogelbilder werden aus freien Wikimedia-Commons-Quellen geladen und lokal gecacht. Die jeweilige Lizenz, Quelle und der Autor werden in der einzelnen Vogelansicht beim Bild angezeigt.")
            }

            Section("Abhängigkeiten") {
                Text("TensorFlow Lite wird über CocoaPods eingebunden. Die Lizenzinformationen der Pods bleiben in den jeweiligen Pod-Metadaten erhalten.")
            }
        }
        .navigationTitle("Lizenzen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ExpertSettingsView: View {

    @State private var benchmarkViewModel = ExpertBenchmarkViewModel()
    @AppStorage(AppSettings.confidenceThresholdKey)
    private var confidenceThreshold = AppSettings.defaultConfidenceThreshold

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Threshold", systemImage: "scope")
                        Spacer()
                        ExpertCurrentDefaultText(
                            current: "\(Int(confidenceThreshold * 100))%",
                            defaultValue: "\(Int(AppSettings.defaultConfidenceThreshold * 100))%"
                        )
                            .font(.headline.monospacedDigit())
                    }

                    Slider(
                        value: $confidenceThreshold,
                        in: 0.05...0.95,
                        step: 0.01
                    ) {
                        Text("Threshold")
                    } minimumValueLabel: {
                        Text("5%")
                    } maximumValueLabel: {
                        Text("95%")
                    }

                    ThresholdDefaultMarker()
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Niedrigere Werte finden leisere Rufe eher, erzeugen aber mehr Fehlalarme.")
            }

            ForEach(1...AppSettings.audioProfileCount, id: \.self) { profileIndex in
                ExpertProfileSettingsSection(profileIndex: profileIndex)
            }

            ExpertBenchmarkSection(viewModel: benchmarkViewModel)

            Section {
                Button {
                    resetToDefaults()
                } label: {
                    Label("reset to default", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle("Expert")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            benchmarkViewModel.loadModel()
        }
    }

    private func resetToDefaults() {
        confidenceThreshold = AppSettings.defaultConfidenceThreshold
        AppSettings.resetAudioProfileDefaults()
    }
}

struct ExpertProfileSettingsSection: View {

    let profileIndex: Int
    @State private var areParametersExpanded = false
    @AppStorage private var isEnabled: Bool
    @AppStorage private var isBandpassEnabled: Bool
    @AppStorage private var highpassCutoffHz: Double
    @AppStorage private var lowpassCutoffHz: Double
    @AppStorage private var isBandEnergyGateEnabled: Bool
    @AppStorage private var minimumBandRMS: Double

    init(profileIndex: Int) {
        self.profileIndex = profileIndex
        _isEnabled = AppStorage(
            wrappedValue: AppSettings.defaultAudioProfileEnabled(profileIndex: profileIndex),
            AppSettings.audioProfileEnabledKey(profileIndex: profileIndex)
        )
        _isBandpassEnabled = AppStorage(
            wrappedValue: AppSettings.defaultAudioBandpassEnabled(profileIndex: profileIndex),
            AppSettings.audioBandpassEnabledKey(profileIndex: profileIndex)
        )
        _highpassCutoffHz = AppStorage(
            wrappedValue: AppSettings.defaultAudioHighpassCutoffHz(profileIndex: profileIndex),
            AppSettings.audioHighpassCutoffHzKey(profileIndex: profileIndex)
        )
        _lowpassCutoffHz = AppStorage(
            wrappedValue: AppSettings.defaultAudioLowpassCutoffHz(profileIndex: profileIndex),
            AppSettings.audioLowpassCutoffHzKey(profileIndex: profileIndex)
        )
        _isBandEnergyGateEnabled = AppStorage(
            wrappedValue: AppSettings.defaultAudioBandEnergyGateEnabled(profileIndex: profileIndex),
            AppSettings.audioBandEnergyGateEnabledKey(profileIndex: profileIndex)
        )
        _minimumBandRMS = AppStorage(
            wrappedValue: AppSettings.defaultAudioMinimumBandRMS(profileIndex: profileIndex),
            AppSettings.audioMinimumBandRMSKey(profileIndex: profileIndex)
        )
    }

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Label(title, systemImage: "slider.horizontal.3")
            }

            DisclosureGroup(isExpanded: $areParametersExpanded) {
                Toggle(isOn: $isBandpassEnabled) {
                    Label("Bandpass", systemImage: "waveform.path.ecg")
                }
                .disabled(!isEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Highpass")
                        Spacer()
                        ExpertCurrentDefaultText(
                            current: "\(Int(highpassCutoffHz)) Hz",
                            defaultValue: "\(Int(AppSettings.defaultAudioHighpassCutoffHz(profileIndex: profileIndex))) Hz"
                        )
                    }
                    Slider(value: $highpassCutoffHz, in: 50...12_000, step: 50)
                }
                .disabled(!isEnabled || !isBandpassEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Lowpass")
                        Spacer()
                        ExpertCurrentDefaultText(
                            current: String(format: "%.1f kHz", lowpassCutoffHz / 1000),
                            defaultValue: String(
                                format: "%.1f kHz",
                                AppSettings.defaultAudioLowpassCutoffHz(profileIndex: profileIndex) / 1000
                            )
                        )
                    }
                    Slider(value: $lowpassCutoffHz, in: 500...16_000, step: 250)
                }
                .disabled(!isEnabled || !isBandpassEnabled)

                Toggle(isOn: $isBandEnergyGateEnabled) {
                    Label("Band-Energy-Gate", systemImage: "gauge")
                }
                .disabled(!isEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Min. Band-RMS")
                        Spacer()
                        ExpertCurrentDefaultText(
                            current: String(format: "%.4f", minimumBandRMS),
                            defaultValue: String(
                                format: "%.4f",
                                AppSettings.defaultAudioMinimumBandRMS(profileIndex: profileIndex)
                            )
                        )
                    }
                    Slider(value: $minimumBandRMS, in: 0.0002...0.005, step: 0.0002)
                }
                .disabled(!isEnabled || !isBandEnergyGateEnabled)
            } label: {
                Label("Parameter", systemImage: "chevron.down.circle")
            }
        }
    }

    private var title: String {
        AppSettings.audioProfileLabel(profileIndex: profileIndex)
    }
}

struct ExpertBenchmarkSection: View {

    @Bindable var viewModel: ExpertBenchmarkViewModel
    @State private var isImportingSample = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Benchmark", systemImage: "waveform.badge.magnifyingglass")
                    Spacer()
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ProgressView(
                    value: viewModel.recordingProgress,
                    total: 1
                )
                .tint(viewModel.state == .recording ? .red : .accentColor)

                HStack {
                    LabeledContent(
                        "Sample",
                        value: String(
                            format: "%.1f / %.0f s",
                            viewModel.recordingDuration,
                            BenchmarkAudioRecorder.maximumDuration
                        )
                    )
                    .monospacedDigit()
                }

                HStack(spacing: 10) {
                    Button {
                        if viewModel.state == .recording {
                            viewModel.stopRecording()
                        } else {
                            viewModel.startRecording()
                        }
                    } label: {
                        Image(
                            systemName: viewModel.state == .recording
                                ? "stop.circle.fill" : "record.circle"
                        )
                        .font(.title3)
                        .frame(width: 38, height: 34)
                    }
                    .disabled(!viewModel.canRecord && viewModel.state != .recording)
                    .accessibilityLabel(viewModel.state == .recording ? "Stop" : "Aufnehmen")

                    Button {
                        isImportingSample = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.title3)
                            .frame(width: 38, height: 34)
                    }
                    .disabled(viewModel.state == .recording || viewModel.state == .processing)
                    .accessibilityLabel("Sample-Datei laden")

                    Button {
                        viewModel.processRecording()
                    } label: {
                        Image(
                            systemName: viewModel.results.isEmpty
                                ? "play.circle" : "arrow.clockwise.circle"
                        )
                        .font(.title3)
                        .frame(width: 38, height: 34)
                    }
                    .disabled(!viewModel.canProcess)
                    .accessibilityLabel(viewModel.results.isEmpty ? "Prozessieren" : "Erneut prozessieren")

                    Button(role: .destructive) {
                        viewModel.clearRecording()
                    } label: {
                        Image(systemName: "trash")
                            .font(.title3)
                            .frame(width: 38, height: 34)
                    }
                    .disabled(viewModel.state == .processing)
                    .accessibilityLabel("Sample löschen")
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)

            LabeledContent("Status", value: viewModel.statusText)
            LabeledContent("Format", value: viewModel.audioFormat)
            LabeledContent(
                "Fenster",
                value: "\(viewModel.processedWindowCount) analysiert, \(viewModel.skippedWindowCount) Gate-Skips"
            )
            if let processingDuration = viewModel.processingDuration {
                LabeledContent(
                    "Renderzeit",
                    value: String(format: "%.2f s", processingDuration)
                )
                .monospacedDigit()
            }

            if viewModel.state == .processing {
                HStack {
                    ProgressView()
                    Text("Durchprozessieren")
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.results.isEmpty {
                Text("Gesamt")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(viewModel.results.prefix(10)) { result in
                    ExpertBenchmarkResultRow(result: result)
                }
            }

            if !viewModel.profileResults.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Profile")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ExpertBenchmarkProfileTable(profileResults: viewModel.profileResults)
                }
                .padding(.vertical, 4)
            }
        } footer: {
            Text("Nimmt bis zu 30 Sekunden auf und rendert die Aufnahme mit den aktuellen Expert-Parametern wie Live-Audio in 3-Sekunden-Fenstern. Die Ergebnisse sind eine technische Prozentansicht und werden nicht als Session gespeichert.")
        }
        .fileImporter(
            isPresented: $isImportingSample,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first
            else {
                return
            }

            viewModel.importSample(from: url)
        }
    }

    private var statusLabel: String {
        switch viewModel.state {
        case .idle:
            return "bereit"
        case .loadingModel:
            return "Modell"
        case .recording:
            return "Aufnahme"
        case .ready:
            return "Sample"
        case .processing:
            return "Render"
        case .finished:
            return "fertig"
        case .failed:
            return "Fehler"
        }
    }
}

struct ExpertBenchmarkProfileTable: View {

    let profileResults: [ExpertBenchmarkProfileResult]

    private var rows: [ExpertBenchmarkProfileComparisonRow] {
        ExpertBenchmarkProfileComparisonRow.rows(from: profileResults)
    }

    var body: some View {
        GeometryReader { proxy in
            let profileCount = max(profileResults.count, 1)
            let spacing: CGFloat = 8
            let totalSpacing = CGFloat(profileCount) * spacing
            let availableWidth = max(260, proxy.size.width)
            let profileColumnWidth = max(
                42,
                min(58, (availableWidth - totalSpacing) * 0.17)
            )
            let speciesColumnWidth = max(
                92,
                availableWidth - totalSpacing - CGFloat(profileCount) * profileColumnWidth
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: spacing) {
                    Text("Art")
                        .frame(width: speciesColumnWidth, alignment: .leading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(profileResults) { profileResult in
                        ExpertBenchmarkProfileHeader(
                            profileResult: profileResult,
                            width: profileColumnWidth
                        )
                    }
                }

                Divider()

                if rows.isEmpty {
                    Text("Keine Treffer ueber Threshold")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows.prefix(12)) { row in
                        ExpertBenchmarkProfileComparisonGridRow(
                            row: row,
                            profileResults: profileResults,
                            speciesColumnWidth: speciesColumnWidth,
                            profileColumnWidth: profileColumnWidth,
                            spacing: spacing
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(profileResults) { profileResult in
                        Text(profileSummary(profileResult))
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: tableHeight)
    }

    private var tableHeight: CGFloat {
        let rowCount = rows.isEmpty ? 1 : min(rows.count, 12)
        return 68 + CGFloat(rowCount) * 56 + CGFloat(profileResults.count) * 14
    }

    private func profileSummary(_ profileResult: ExpertBenchmarkProfileResult) -> String {
        "\(profileResult.profileLabel): \(profileResult.analyzedWindowCount) analysiert, \(profileResult.skippedWindowCount) Skip"
    }
}

struct ExpertBenchmarkProfileHeader: View {

    let profileResult: ExpertBenchmarkProfileResult
    let width: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(shortProfileLabel)
                .font(.caption.weight(.semibold))
            Text(frequencyText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .frame(width: width, alignment: .trailing)
    }

    private var shortProfileLabel: String {
        profileResult.profileLabel
            .replacingOccurrences(of: "Profil ", with: "P")
    }

    private var frequencyText: String {
        guard profileResult.settings.isBandpassEnabled else {
            return "voll"
        }
        return "\(Self.frequency(profileResult.settings.highpassCutoffHz))-\(Self.frequency(profileResult.settings.lowpassCutoffHz))"
    }

    private static func frequency(_ value: Float) -> String {
        if value >= 1_000 {
            return String(format: "%.1fk", value / 1_000)
                .replacingOccurrences(of: ".0k", with: "k")
        }
        return String(format: "%.0f", value)
    }
}

struct ExpertBenchmarkProfileComparisonGridRow: View {

    let row: ExpertBenchmarkProfileComparisonRow
    let profileResults: [ExpertBenchmarkProfileResult]
    let speciesColumnWidth: CGFloat
    let profileColumnWidth: CGFloat
    let spacing: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.germanName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.scientificName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: speciesColumnWidth, alignment: .leading)

            ForEach(profileResults) { profileResult in
                Text(confidenceText(for: profileResult))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(confidenceColor(for: profileResult))
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                    .frame(width: profileColumnWidth, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    private func confidenceText(for profileResult: ExpertBenchmarkProfileResult) -> String {
        guard let result = row.resultsByProfile[profileResult.profileLabel] else {
            return "-"
        }
        return String(format: "%.0f%%", result.maxConfidence * 100)
    }

    private func confidenceColor(for profileResult: ExpertBenchmarkProfileResult) -> Color {
        guard let result = row.resultsByProfile[profileResult.profileLabel] else {
            return .secondary
        }
        if result.maxConfidence >= 0.8 {
            return .green
        }
        if result.maxConfidence >= 0.5 {
            return .primary
        }
        return .secondary
    }
}

struct ExpertBenchmarkProfileComparisonRow: Identifiable, Equatable {
    var id: String { scientificName }
    let scientificName: String
    let germanName: String
    let resultsByProfile: [String: ExpertBenchmarkDetectionResult]
    let maxConfidence: Float

    static func rows(
        from profileResults: [ExpertBenchmarkProfileResult]
    ) -> [ExpertBenchmarkProfileComparisonRow] {
        var namesByScientificName: [String: String] = [:]
        var resultsBySpecies: [String: [String: ExpertBenchmarkDetectionResult]] = [:]

        for profileResult in profileResults {
            for result in profileResult.results {
                namesByScientificName[result.scientificName] = result.germanName
                resultsBySpecies[result.scientificName, default: [:]][profileResult.profileLabel] = result
            }
        }

        return resultsBySpecies.map { scientificName, resultsByProfile in
            ExpertBenchmarkProfileComparisonRow(
                scientificName: scientificName,
                germanName: namesByScientificName[scientificName] ?? scientificName,
                resultsByProfile: resultsByProfile,
                maxConfidence: resultsByProfile.values.map(\.maxConfidence).max() ?? 0
            )
        }
        .sorted {
            if $0.maxConfidence == $1.maxConfidence {
                return $0.germanName < $1.germanName
            }
            return $0.maxConfidence > $1.maxConfidence
        }
    }
}

struct ExpertBenchmarkPreprocessingRow: View {

    let summary: ExpertBenchmarkPreprocessingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(summary.profileLabel, systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(summary.windowCount - summary.skippedWindowCount)/\(summary.windowCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(metricsText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var metricsText: String {
        String(
            format: "RMS %.4f · Band %.4f",
            summary.averageInputRMS,
            summary.averageBandRMS
        )
    }
}

struct ExpertBenchmarkResultRow: View {

    let result: ExpertBenchmarkDetectionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.germanName)
                        .font(.subheadline.weight(.semibold))
                    Text(result.scientificName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.percent(result.maxConfidence))
                        .font(.headline.monospacedDigit())
                    Text("max")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label(
                    "\(result.hitWindowCount)/\(result.analyzedWindowCount)",
                    systemImage: "square.stack.3d.up"
                )
                Spacer()
                Text("Ø \(Self.percent(result.averageConfidence))")
                Text(Self.timeRange(result))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private static func percent(_ confidence: Float) -> String {
        String(format: "%.1f%%", confidence * 100)
    }

    private static func timeRange(_ result: ExpertBenchmarkDetectionResult) -> String {
        String(
            format: "%.0f-%.0f s",
            result.firstHitStartSeconds,
            result.lastHitStartSeconds + 3
        )
    }
}

struct ExpertCurrentDefaultText: View {

    let current: String
    let defaultValue: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(current)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("Default \(defaultValue)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }
}

struct ThresholdDefaultMarker: View {

    private let minimum = 0.05
    private let maximum = 0.95
    private let defaultValue = AppSettings.defaultConfidenceThreshold
    private let visualOffset = 0.05

    var body: some View {
        GeometryReader { geometry in
            let markerValue = defaultValue + visualOffset
            let progress = (markerValue - minimum) / (maximum - minimum)
            let xPosition = max(0, min(1, progress)) * geometry.size.width

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)

                VStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: 1, height: 8)
                    Text("Default 35%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .offset(x: xPosition - 34)
            }
        }
        .frame(height: 28)
    }
}

// MARK: - Bird Overview View

struct BirdOverviewView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BirdSpecies.germanName)
    private var species: [BirdSpecies]

    var body: some View {
        NavigationStack {
            Group {
                if activeSpecies.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Vögel",
                        systemImage: "bird",
                        description: Text("Gefundene Vögel erscheinen hier nach Sessions gruppiert.")
                    )
                } else {
                    List(activeSpecies) { species in
                        NavigationLink {
                            BirdSpeciesDetailView(species: species)
                        } label: {
                            BirdSpeciesSummaryRow(species: species)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Vögel")
            .task {
                cleanupOrphanedBirdSpecies(in: modelContext)
            }
        }
    }

    private var activeSpecies: [BirdSpecies] {
        species.filter { !$0.relevantObservations.isEmpty }
    }
}

struct BirdSpeciesDetailView: View {

    let species: BirdSpecies

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    BirdThumbnail(scientificName: species.scientificName, size: 58)

                    VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(species.germanName)
                            .font(.headline)
                        BirdSpeakButton(
                            germanName: species.germanName,
                            scientificName: species.scientificName
                        )
                        .accessibilityLabel("\(species.germanName) vorlesen")
                        if species.isNewlyDiscovered {
                            NewSpeciesBadge()
                        }
                        }
                        Text(species.scientificName)
                            .font(.caption)
                            .italic()
                            .foregroundStyle(.secondary)
                        Text(speciesHistoryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Sessions") {
                ForEach(matchingSessions) { session in
                    NavigationLink {
                        SessionDetailView(session: session)
                    } label: {
                        BirdSpeciesSessionRow(session: session, species: species)
                    }
                }
            }

            BirdImageLicenseGallery(
                species: [
                    BirdImageLicenseSpecies(
                        scientificName: species.scientificName,
                        germanName: species.germanName
                    )
                ],
                allowsMultipleImagesPerSpecies: true
            )
        }
        .navigationTitle(species.germanName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var matchingSessions: [BirdSession] {
        let sessions = species.observations.compactMap(\.session)
        var seen = Set<UUID>()
        return sessions
            .filter { seen.insert($0.id).inserted }
            .sorted {
                $0.startedAt > $1.startedAt
            }
    }

    private var speciesHistoryText: String {
        BirdSpeciesHistoryFormatter.detailText(for: species)
    }
}

struct BirdSpeciesSessionListView: View {

    let scientificName: String
    let germanName: String
    @Query(sort: \BirdSpecies.germanName)
    private var species: [BirdSpecies]

    var body: some View {
        if let match {
            BirdSpeciesDetailView(species: match)
        } else {
            ContentUnavailableView(
                germanName,
                systemImage: "bird",
                description: Text(scientificName)
            )
        }
    }

    private var match: BirdSpecies? {
        species.first { $0.scientificName == scientificName }
    }
}

struct BirdSpeciesSummaryRow: View {

    let species: BirdSpecies

    var body: some View {
        HStack(spacing: 14) {
            BirdThumbnail(scientificName: species.scientificName, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(species.germanName)
                        .font(.headline)
                        .lineLimit(1)
                    BirdSpeakButton(
                        germanName: species.germanName,
                        scientificName: species.scientificName
                    )
                    .accessibilityLabel("\(species.germanName) vorlesen")
                    if species.isNewlyDiscovered {
                        NewSpeciesBadge()
                    }
                }
                Text(species.scientificName)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(BirdSpeciesHistoryFormatter.listText(for: species))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(sessionCount)")
                    .font(.title3.weight(.bold).monospacedDigit())
                Text(sessionCount == 1 ? "Session" : "Sessions")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var sessionCount: Int {
        species.uniqueSessionCount
    }
}

struct BirdSpeciesSessionRow: View {

    let session: BirdSession
    let species: BirdSpecies

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                BirdSpeakButton(
                    germanName: species.germanName,
                    scientificName: species.scientificName
                )
                .accessibilityLabel("\(species.germanName) vorlesen")
            }

            HStack(spacing: 12) {
                Label(durationText, systemImage: "timer")
                if let detection {
                    Label("\(Int(detection.bestConfidence * 100))%", systemImage: "scope")
                    Label("\(detection.detectionCount)x", systemImage: "repeat")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var detection: SessionBirdDetection? {
        session.reviewedDetections.first { $0.species?.id == species.id }
    }

    private var durationText: String {
        SessionDetailView.durationFormatter.string(from: session.duration) ?? "0:00"
    }
}

struct BirdSpeciesSummary: Identifiable {
    let id: String
    let scientificName: String
    let germanName: String
    let sessionCount: Int
    let bestConfidence: Float
    let lastDetectedAt: Date

    static func make(from sessions: [BirdSession]) -> [BirdSpeciesSummary] {
        var summaries: [String: MutableBirdSpeciesSummary] = [:]

        for session in sessions {
            var speciesSeenInSession = Set<String>()

            for detection in session.reviewedDetections {
                guard speciesSeenInSession.insert(detection.scientificName).inserted else {
                    continue
                }

                var summary = summaries[detection.scientificName]
                    ?? MutableBirdSpeciesSummary(
                        scientificName: detection.scientificName,
                        germanName: detection.germanName
                    )
                summary.sessionIDs.insert(session.id)
                summary.bestConfidence = max(summary.bestConfidence, detection.bestConfidence)
                summary.lastDetectedAt = max(summary.lastDetectedAt, detection.lastDetectedAt)
                summaries[detection.scientificName] = summary
            }
        }

        return summaries.values
            .map { $0.snapshot }
            .sorted {
                if $0.sessionCount != $1.sessionCount {
                    return $0.sessionCount > $1.sessionCount
                }

                if $0.lastDetectedAt != $1.lastDetectedAt {
                    return $0.lastDetectedAt > $1.lastDetectedAt
                }

                return $0.germanName.localizedCaseInsensitiveCompare($1.germanName) == .orderedAscending
            }
    }
}

private struct MutableBirdSpeciesSummary {
    let scientificName: String
    let germanName: String
    var sessionIDs = Set<UUID>()
    var bestConfidence: Float = 0
    var lastDetectedAt = Date.distantPast

    var snapshot: BirdSpeciesSummary {
        BirdSpeciesSummary(
            id: scientificName,
            scientificName: scientificName,
            germanName: germanName,
            sessionCount: sessionIDs.count,
            bestConfidence: bestConfidence,
            lastDetectedAt: lastDetectedAt
        )
    }
}

// MARK: - Sessions View

struct SessionsView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BirdSession.startedAt, order: .reverse)
    private var sessions: [BirdSession]

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Sessions",
                        systemImage: "waveform",
                        description: Text("Starte im Zuhören-Tab eine Aufnahme.")
                    )
                } else {
                    List {
                        ForEach(sessionDays) { day in
                            NavigationLink {
                                SessionDayView(date: day.date)
                            } label: {
                                SessionDayRow(day: day)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Sessions")
        }
    }

    private var sessionDays: [SessionDaySummary] {
        SessionDaySummary.make(from: sessions)
    }
}

struct SessionDayView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BirdSession.startedAt, order: .reverse)
    private var sessions: [BirdSession]
    let date: Date

    var body: some View {
        List {
            Section {
                LabeledContent("Sessions", value: "\(day.sessionCount)")
                LabeledContent("Arten", value: "\(day.speciesCount)")
            }

            Section("Sessions") {
                ForEach(day.sessions) { session in
                    NavigationLink {
                        SessionDetailView(session: session)
                    } label: {
                        SessionRow(session: session)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            delete(session)
                            try? modelContext.save()
                            cleanupOrphanedBirdSpecies(in: modelContext)
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                    }
                }
                .onDelete(perform: delete)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(day.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
    }

    private func delete(_ session: BirdSession) {
        for detection in session.detections {
            modelContext.delete(detection)
        }
        modelContext.delete(session)
    }

    private func delete(at offsets: IndexSet) {
        let sessionsToDelete = offsets.map { day.sessions[$0] }
        for session in sessionsToDelete {
            delete(session)
        }
        try? modelContext.save()
        cleanupOrphanedBirdSpecies(in: modelContext)
    }

    private var day: SessionDaySummary {
        SessionDaySummary.make(from: sessionsForDate).first ?? SessionDaySummary(
            id: date,
            date: date,
            sessions: [],
            speciesNames: []
        )
    }

    private var sessionsForDate: [BirdSession] {
        let calendar = Calendar.current
        return sessions.filter {
            calendar.isDate($0.startedAt, inSameDayAs: date)
        }
    }
}

struct SessionDaySummary: Identifiable {

    let id: Date
    let date: Date
    let sessions: [BirdSession]
    let speciesNames: [String]

    var title: String {
        Self.titleFormatter.string(from: date)
    }

    var sessionCount: Int {
        sessions.count
    }

    var speciesCount: Int {
        speciesNames.count
    }

    var speciesPreview: String {
        guard !speciesNames.isEmpty else {
            return "Keine Arten"
        }

        let visibleNames = speciesNames.prefix(4).joined(separator: ", ")
        let remainingCount = speciesNames.count - 4
        if remainingCount > 0 {
            return "\(visibleNames) +\(remainingCount)"
        }

        return visibleNames
    }

    static func make(from sessions: [BirdSession]) -> [SessionDaySummary] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sessions) {
            calendar.startOfDay(for: $0.startedAt)
        }

        return grouped
            .map { day, sessions in
                let sortedSessions = sessions.sorted { $0.startedAt > $1.startedAt }
                let speciesNames = Set(
                    sortedSessions.flatMap { session in
                        session.reviewedDetections.map(\.germanName)
                    }
                )
                .sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }

                return SessionDaySummary(
                    id: day,
                    date: day,
                    sessions: sortedSessions,
                    speciesNames: speciesNames
                )
            }
            .sorted { $0.date > $1.date }
    }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()
}

struct SessionDayRow: View {

    let day: SessionDaySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(day.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 12) {
                Label("\(day.sessionCount)", systemImage: "list.bullet.rectangle")
                Label("\(day.speciesCount)", systemImage: "bird.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(day.speciesPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

struct SessionRow: View {

    let session: BirdSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.displayTitle)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 12) {
                Label(session.dateDescription, systemImage: "calendar")
                Label(durationText, systemImage: "timer")
                Label("\(session.reviewedDetections.count)", systemImage: "bird.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var durationText: String {
        SessionDetailView.durationFormatter.string(from: session.duration) ?? "0:00"
    }
}

struct SessionDetailView: View {

    @Environment(\.modelContext) private var modelContext
    let session: BirdSession
    @State private var detectionPendingDeletion: SessionBirdDetection?

    var body: some View {
        List {
            Section {
                LabeledContent("Start", value: Self.dateFormatter.string(from: session.startedAt))
                LabeledContent("Dauer", value: Self.durationFormatter.string(from: session.duration) ?? "0:00")
                LabeledContent("Ort", value: session.locationDescription)
                if let coordinateDescription = session.coordinateDescription {
                    LabeledContent("Koordinaten", value: coordinateDescription)
                }
            }

            if let coordinate = sessionCoordinate {
                Section("Karte") {
                    Map(initialPosition: .region(mapRegion(for: coordinate))) {
                        Marker(session.locationDescription, coordinate: coordinate)
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            Section("Vögel") {
                if session.visibleDetections.isEmpty {
                    Text("Keine Treffer in dieser Session.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.visibleDetections.sortedForDisplay) { detection in
                        if let species = detection.species {
                            NavigationLink {
                                BirdSpeciesDetailView(species: species)
                            } label: {
                                SessionDetectionReviewRow(detection: detection)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    detectionPendingDeletion = detection
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                        } else {
                            SessionDetectionReviewRow(detection: detection)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        detectionPendingDeletion = detection
                                    } label: {
                                        Label("Löschen", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Diesen Vogel aus der Session löschen?",
            isPresented: Binding(
                get: { detectionPendingDeletion != nil },
                set: { if !$0 { detectionPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                deletePendingDetection()
            }
            Button("Abbrechen", role: .cancel) {
                detectionPendingDeletion = nil
            }
        } message: {
            if let detectionPendingDeletion {
                Text("\(detectionPendingDeletion.germanName) wird aus dieser Session entfernt.")
            }
        }
    }

    private func deletePendingDetection() {
        guard let detection = detectionPendingDeletion else { return }
        modelContext.delete(detection)
        try? modelContext.save()
        cleanupOrphanedBirdSpecies(in: modelContext)
        detectionPendingDeletion = nil
    }

    private var sessionCoordinate: CLLocationCoordinate2D? {
        guard let latitude = session.latitude,
              let longitude = session.longitude
        else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func mapRegion(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        )
    }

    static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

struct SessionDetectionReviewRow: View {

    let detection: SessionBirdDetection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                BirdThumbnail(scientificName: detection.scientificName, size: 50)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(detection.germanName)
                            .font(.headline)
                        BirdSpeakButton(
                            germanName: detection.germanName,
                            scientificName: detection.scientificName
                        )
                        .accessibilityLabel("\(detection.germanName) vorlesen")
                        if detection.isFirstObservationForSpecies {
                            NewSpeciesBadge()
                        }
                    }
                    Text(detection.scientificName)
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(Int(detection.bestConfidence * 100))%")
                    .font(.headline.monospacedDigit())
            }

            HStack(spacing: 10) {
                Label("\(detection.detectionCount)x", systemImage: "repeat")
                    .foregroundStyle(.secondary)

                Spacer()

                Label(detection.status.label, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.20, green: 0.65, blue: 0.40))
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

struct SessionDetectionCard: View {

    @Environment(\.modelContext) private var modelContext
    let detection: SessionBirdDetection
    let flashToken: Int
    @State private var isConfirmingDeletion = false
    @State private var flashOpacity = 0.0

    var body: some View {
        HStack(spacing: 14) {
            BirdThumbnail(
                scientificName: detection.scientificName,
                size: 48,
                accentColor: confidenceColor
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(detection.germanName)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    BirdSpeakButton(
                        germanName: detection.germanName,
                        scientificName: detection.scientificName
                    )
                    .accessibilityLabel("\(detection.germanName) vorlesen")
                    if detection.isFirstObservationForSpecies {
                        NewSpeciesBadge()
                    }
                }

                Text(detection.scientificName)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("\(detection.detectionCount)x")
                    Text(detection.status.label)
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) {
                Text(confidenceText)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(confidenceColor)
                    .monospacedDigit()

                Button(role: .destructive) {
                    isConfirmingDeletion = true
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color(red: 0.95, green: 0.40, blue: 0.35))
                .accessibilityLabel("Aus Session löschen")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(confidenceColor.opacity(flashOpacity))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            flashBorderColor,
                            lineWidth: flashBorderWidth
                        )
                }
        )
        .confirmationDialog(
            "Diesen Vogel aus der Session löschen?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                modelContext.delete(detection)
                try? modelContext.save()
                cleanupOrphanedBirdSpecies(in: modelContext)
            }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text("\(detection.germanName) wird aus der aktiven Session entfernt.")
        }
        .onChange(of: flashToken) { _, newValue in
            guard newValue > 0 else { return }
            playFlashAnimation()
        }
    }

    private var confidenceColor: Color {
        if detection.bestConfidence > 0.7 {
            return Color(red: 0.35, green: 0.87, blue: 0.50)
        } else if detection.bestConfidence > 0.4 {
            return Color(red: 0.95, green: 0.75, blue: 0.25)
        } else {
            return Color(red: 0.85, green: 0.45, blue: 0.30)
        }
    }

    private var confidenceText: String {
        "\(Int(detection.bestConfidence * 100))%"
    }

    private var flashBorderColor: Color {
        flashOpacity > 0.01 ? confidenceColor.opacity(0.8) : Color(.quaternaryLabel)
    }

    private var flashBorderWidth: CGFloat {
        flashOpacity > 0.01 ? 1.5 : 0.5
    }

    private func playFlashAnimation() {
        Task { @MainActor in
            for _ in 0..<2 {
                withAnimation(.easeInOut(duration: 0.12)) {
                    flashOpacity = 0.22
                }
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(.easeInOut(duration: 0.12)) {
                    flashOpacity = 0
                }
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }
}

private extension Array where Element == BirdImageInfo {
    var uniquedByScientificName: [BirdImageInfo] {
        var seen = Set<String>()
        return filter { seen.insert($0.scientificName).inserted }
    }
}

// MARK: - Diagnostic Item

struct DiagnosticItem: View {

    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

// MARK: - Detection Card

struct DetectionCard: View {

    let detection: BirdDetection

    var body: some View {
        HStack(spacing: 14) {
            BirdThumbnail(
                scientificName: detection.scientificName,
                size: 48,
                accentColor: confidenceColor
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(detection.germanName)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    BirdSpeakButton(
                        germanName: detection.germanName,
                        scientificName: detection.scientificName
                    )
                    .accessibilityLabel("\(detection.germanName) vorlesen")
                }

                Text(detection.scientificName)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(1)

                // Confidence bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: 4)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        confidenceColor.opacity(0.8),
                                        confidenceColor,
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(
                                width: geo.size.width * CGFloat(detection.confidence),
                                height: 4
                            )
                    }
                }
                .frame(height: 4)
            }

            Spacer(minLength: 0)

            // Confidence percentage
            Text("\(Int(detection.confidence * 100))%")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(confidenceColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .stroke(.quaternary, lineWidth: 0.5)
        )
    }

    private var confidenceColor: Color {
        if detection.confidence > 0.7 {
            return Color(red: 0.35, green: 0.87, blue: 0.50) // Green
        } else if detection.confidence > 0.4 {
            return Color(red: 0.95, green: 0.75, blue: 0.25) // Amber
        } else {
            return Color(red: 0.85, green: 0.45, blue: 0.30) // Orange
        }
    }
}

struct BirdImageLicenseSpecies: Identifiable, Hashable {
    let scientificName: String
    let germanName: String

    var id: String {
        scientificName
    }
}

struct NewSpeciesBadge: View {

    var body: some View {
        Text("Neu")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.accentColor.opacity(0.12))
            )
    }
}

enum BirdSpeciesHistoryFormatter {

    static func listText(for species: BirdSpecies, now: Date = Date()) -> String {
        let firstSeen = species.firstObservedAt.map(dateText) ?? "unbekannt"
        return "Erstfund: \(firstSeen) · Zuletzt: \(daysSinceLastSeenText(for: species, now: now))"
    }

    static func detailText(for species: BirdSpecies, now: Date = Date()) -> String {
        let firstSeen = species.firstObservedAt.map(dateText) ?? "unbekannt"
        return "Erstfund am \(firstSeen) · Letzte Sichtung \(daysSinceLastSeenText(for: species, now: now))"
    }

    static func daysSinceLastSeenText(for species: BirdSpecies, now: Date = Date()) -> String {
        guard let lastObservedAt = species.lastObservedAt else {
            return "unbekannt"
        }

        let days = Calendar.current.dateComponents([.day], from: lastObservedAt, to: now).day ?? 0
        if days <= 0 {
            return "heute"
        }
        if days == 1 {
            return "vor 1 Tag"
        }
        return "vor \(days) Tagen"
    }

    private static func dateText(for date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

struct BirdImageLicenseEntry: Identifiable {
    let scientificName: String
    let germanName: String
    let title: String
    let credit: String
    let license: String
    let sourceURL: URL
    let assetName: String?
    let image: UIImage?

    var id: String {
        "\(scientificName)-\(sourceURL.absoluteString)"
    }
}

enum BirdImageLicenseLoader {

    static func entries(
        for species: [BirdImageLicenseSpecies],
        maximumCount: Int,
        allowsMultipleImagesPerSpecies: Bool
    ) async -> [BirdImageLicenseEntry] {
        let uniqueSpecies = uniqueSpecies(from: species)
        var groupedEntries: [[BirdImageLicenseEntry]] = []

        for item in uniqueSpecies {
            let results = await BirdImageStore.shared.images(
                for: item.scientificName,
                maximumCount: allowsMultipleImagesPerSpecies ? maximumCount : 1
            )
            let entries = results.map { result in
                BirdImageLicenseEntry(
                    scientificName: item.scientificName,
                    germanName: item.germanName,
                    title: result.info.title,
                    credit: result.info.credit,
                    license: result.info.license,
                    sourceURL: result.info.sourceURL,
                    assetName: nil,
                    image: result.image
                )
            }
            if !entries.isEmpty {
                groupedEntries.append(entries)
            }
        }

        var orderedEntries: [BirdImageLicenseEntry] = []

        for entries in groupedEntries {
            if let first = entries.first {
                orderedEntries.append(first)
            }
        }

        if allowsMultipleImagesPerSpecies {
            for entries in groupedEntries {
                orderedEntries.append(contentsOf: entries.dropFirst())
            }
        }

        return Array(orderedEntries.prefix(maximumCount))
    }

    static func key(for species: [BirdImageLicenseSpecies]) -> String {
        uniqueSpecies(from: species)
            .map(\.scientificName)
            .joined(separator: "|")
    }

    private static func uniqueSpecies(from species: [BirdImageLicenseSpecies]) -> [BirdImageLicenseSpecies] {
        var seen = Set<String>()
        return species.filter { item in
            seen.insert(item.scientificName).inserted
        }
    }
}

struct BirdGalleryImageView: View {

    let entry: BirdImageLicenseEntry
    var contentMode: ContentMode = .fill

    var body: some View {
        Group {
            if let assetName = entry.assetName {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let image = entry.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        }
    }
}

struct BirdImageGallerySelection: Identifiable {
    let id = UUID()
    let entries: [BirdImageLicenseEntry]
    let selectedEntryID: String
}

struct BirdImageGalleryPreviewSheet: View {

    let selection: BirdImageGallerySelection
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEntryID: String

    init(selection: BirdImageGallerySelection) {
        self.selection = selection
        _selectedEntryID = State(initialValue: selection.selectedEntryID)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedEntryID) {
                ForEach(selection.entries) { entry in
                    VStack(spacing: 16) {
                        BirdGalleryImageView(entry: entry, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.germanName)
                                .font(.headline)
                            Text(entry.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Lizenz: \(entry.license)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Autor: \(entry.credit)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Link("Quelle öffnen", destination: entry.sourceURL)
                                .font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    }
                    .tag(entry.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .navigationTitle("Bild")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ActiveSessionImageGallery: View {

    @Environment(\.modelContext) private var modelContext
    let species: [BirdImageLicenseSpecies]
    @State private var entries: [BirdImageLicenseEntry] = []
    @State private var hasLoaded = false
    @State private var gallerySelection: BirdImageGallerySelection?

    var body: some View {
        Group {
            if !species.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Bilder")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))

                    if entries.isEmpty {
                        HStack(spacing: 8) {
                            if !hasLoaded {
                                ProgressView()
                                    .tint(Color(red: 0.35, green: 0.87, blue: 0.50))
                                    .scaleEffect(0.75)
                            }
                            Text(hasLoaded ? "Keine Bilder gefunden." : "Bilder werden geladen...")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.56))
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(entries.prefix(maximumImageCount)) { entry in
                                    Button {
                                        gallerySelection = BirdImageGallerySelection(
                                            entries: Array(entries.prefix(maximumImageCount)),
                                            selectedEntryID: entry.id
                                        )
                                    } label: {
                                        VStack(alignment: .leading, spacing: 7) {
                                            BirdGalleryImageView(entry: entry)
                                                .frame(width: 118, height: 88)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                            Text(entry.germanName)
                                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                                .foregroundStyle(.white.opacity(0.82))
                                                .lineLimit(1)
                                        }
                                        .frame(width: 118, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bildlizenzen")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))

                        if entries.isEmpty {
                            Text(hasLoaded ? "Keine Lizenzdaten verfügbar." : "Lizenzdaten werden geladen...")
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.50))
                        } else {
                            ForEach(entries.prefix(maximumImageCount)) { entry in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.germanName)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.84))
                                    Text(entry.title)
                                        .font(.system(size: 11, weight: .regular, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.56))
                                        .lineLimit(2)
                                    Text("Lizenz: \(entry.license)")
                                        .font(.system(size: 11, weight: .regular, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.50))
                                        .lineLimit(2)
                                    Text("Autor: \(entry.credit)")
                                        .font(.system(size: 11, weight: .regular, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.50))
                                        .lineLimit(2)
                                    Link("Quelle öffnen", destination: entry.sourceURL)
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color(red: 0.35, green: 0.87, blue: 0.50))
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.055))
                        .stroke(.white.opacity(0.08), lineWidth: 0.5)
                )
            }
        }
        .task(id: speciesKey) {
            await loadEntries()
        }
        .sheet(item: $gallerySelection) { selection in
            BirdImageGalleryPreviewSheet(selection: selection)
        }
    }

    private var maximumImageCount: Int {
        AppSettings.birdImageMaximumCount
    }

    private var speciesKey: String {
        "\(BirdImageLicenseLoader.key(for: species))|\(maximumImageCount)"
    }

    private func loadEntries() async {
        hasLoaded = false
        entries = await BirdImageLicenseLoader.entries(
            for: species,
            maximumCount: maximumImageCount,
            allowsMultipleImagesPerSpecies: false
        )
        persist(entries)
        hasLoaded = true
    }

    private func persist(_ entries: [BirdImageLicenseEntry]) {
        BirdImageLicensePersister.persist(entries, modelContext: modelContext)
    }
}

struct BirdImageLicenseGallery: View {

    @Environment(\.modelContext) private var modelContext
    let species: [BirdImageLicenseSpecies]
    var allowsMultipleImagesPerSpecies = false
    @State private var entries: [BirdImageLicenseEntry] = []
    @State private var hasLoaded = false
    @State private var gallerySelection: BirdImageGallerySelection?

    var body: some View {
        Group {
            if !species.isEmpty {
                Section("Bilder") {
                    if entries.isEmpty {
                        HStack(spacing: 8) {
                            if !hasLoaded {
                                ProgressView()
                                    .scaleEffect(0.75)
                            }
                            Text(hasLoaded ? "Keine Bilder gefunden." : "Bilder werden geladen...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(entries.prefix(maximumImageCount)) { entry in
                                    Button {
                                        gallerySelection = BirdImageGallerySelection(
                                            entries: Array(entries.prefix(maximumImageCount)),
                                            selectedEntryID: entry.id
                                        )
                                    } label: {
                                        VStack(alignment: .leading, spacing: 7) {
                                            BirdGalleryImageView(entry: entry)
                                                .frame(width: 118, height: 88)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                            Text(entry.germanName)
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(1)
                                        }
                                        .frame(width: 118, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Bildlizenzen") {
                    if entries.isEmpty {
                        Text(hasLoaded ? "Keine Lizenzdaten verfügbar." : "Lizenzdaten werden geladen...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entries.prefix(maximumImageCount)) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.germanName)
                                    .font(.subheadline.weight(.semibold))
                                Text(entry.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Lizenz: \(entry.license)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Autor: \(entry.credit)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Link("Quelle öffnen", destination: entry.sourceURL)
                                    .font(.caption)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .task(id: speciesKey) {
            await loadEntries()
        }
        .sheet(item: $gallerySelection) { selection in
            BirdImageGalleryPreviewSheet(selection: selection)
        }
    }

    private var maximumImageCount: Int {
        allowsMultipleImagesPerSpecies
            ? AppSettings.birdImageMaximumCount
            : 1
    }

    private var speciesKey: String {
        "\(BirdImageLicenseLoader.key(for: species))|\(maximumImageCount)|\(allowsMultipleImagesPerSpecies)"
    }

    private func loadEntries() async {
        hasLoaded = false
        entries = await BirdImageLicenseLoader.entries(
            for: species,
            maximumCount: maximumImageCount,
            allowsMultipleImagesPerSpecies: allowsMultipleImagesPerSpecies
        )
        persist(entries)
        hasLoaded = true
    }

    private func persist(_ entries: [BirdImageLicenseEntry]) {
        BirdImageLicensePersister.persist(entries, modelContext: modelContext)
    }
}

enum BirdImageLicensePersister {
    @MainActor
    static func persist(
        _ entries: [BirdImageLicenseEntry],
        modelContext: ModelContext
    ) {
        for entry in entries {
            let scientificName = entry.scientificName
            let descriptor = FetchDescriptor<BirdSpecies>(
                predicate: #Predicate { species in
                    species.scientificName == scientificName
                }
            )
            guard let species = try? modelContext.fetch(descriptor).first else {
                continue
            }

            guard !species.images.contains(where: {
                $0.sourceURLString == entry.sourceURL.absoluteString
            }) else {
                continue
            }

            let image = BirdSpeciesImage(
                title: entry.title,
                author: entry.credit,
                license: entry.license,
                sourceURL: entry.sourceURL,
                fileName: "\(entry.scientificName)-cached"
            )
            image.species = species
            species.images.append(image)
        }

        try? modelContext.save()
    }
}

// MARK: - Bird Thumbnail

struct BirdThumbnail: View {

    let scientificName: String
    let size: CGFloat
    var accentColor: Color = Color(red: 0.35, green: 0.87, blue: 0.50)
    var overlaySystemImage: String?
    @State private var cachedImage: UIImage?
    @State private var isLoadingImage = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let cachedImage {
                    Image(uiImage: cachedImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Circle()
                            .fill(accentColor.opacity(0.15))

                        if isLoadingImage {
                            ProgressView()
                                .tint(accentColor)
                                .scaleEffect(0.75)
                        } else {
                            Image(systemName: "bird.fill")
                                .font(.system(size: size * 0.38))
                                .foregroundStyle(accentColor)
                        }
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let overlaySystemImage {
                Image(systemName: overlaySystemImage)
                    .font(.system(size: size * 0.32, weight: .bold))
                    .foregroundStyle(accentColor)
                    .background(
                        Circle()
                            .fill(Color(red: 0.04, green: 0.08, blue: 0.06))
                            .frame(width: size * 0.45, height: size * 0.45)
                    )
                    .offset(x: 3, y: 3)
            }
        }
        .task(id: scientificName) {
            await loadCachedOrRemoteImage()
        }
        .accessibilityHidden(true)
    }

    private func loadCachedOrRemoteImage() async {
        cachedImage = nil
        isLoadingImage = true
        if let result = await BirdImageStore.shared.image(for: scientificName) {
            cachedImage = result.image
        }
        isLoadingImage = false
    }
}

// MARK: - Pulse Ring Animation

struct PulseRing: View {

    let delay: Double
    var size: CGFloat = 130

    @State private var isAnimating = false

    var body: some View {
        Circle()
            .stroke(
                Color.accentColor.opacity(0.28),
                lineWidth: 2
            )
            .frame(width: size, height: size)
            .scaleEffect(isAnimating ? 1.6 : 1.0)
            .opacity(isAnimating ? 0 : 0.6)
            .onAppear {
                withAnimation(
                    .easeOut(duration: 2.0)
                    .repeatForever(autoreverses: false)
                    .delay(delay)
                ) {
                    isAnimating = true
                }
            }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
