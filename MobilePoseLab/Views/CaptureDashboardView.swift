import SwiftUI

struct CaptureDashboardView: View {
    @EnvironmentObject private var store: CaptureSessionStore
    @EnvironmentObject private var phoneRecorder: PhoneMotionRecorder
    @EnvironmentObject private var airPodsRecorder: AirPodsMotionRecorder
    @EnvironmentObject private var watchReceiver: WatchConnectivityReceiver

    @State private var csvURL: URL?
    @State private var exportError: String?
    @State private var portText = "8001"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Computer IP", text: $store.streamingConfig.targetHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("UDP Port", text: $portText)
                        .keyboardType(.numberPad)
                        .onChange(of: portText) { _, newValue in
                            if let port = Int(newValue) {
                                store.streamingConfig.targetPort = port
                            }
                        }
                    LabeledContent("Target", value: "\(store.streamingConfig.targetHost):\(store.streamingConfig.targetPort)")
                } header: {
                    Text("UDP target")
                }

                Section {
                    Toggle("Send iPhone Motion", isOn: $store.streamingConfig.sendPhone)
                    Toggle("Send Apple Watch Motion", isOn: $store.streamingConfig.sendWatch)
                    Toggle("Send AirPods Motion", isOn: $store.streamingConfig.sendAirPods)
                } header: {
                    Text("Devices")
                }

                Section {
                    TextField("iPhone device ID", text: $store.streamingConfig.phoneDeviceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Watch device ID", text: $store.streamingConfig.watchDeviceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("AirPods device ID", text: $store.streamingConfig.airPodsDeviceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Device IDs")
                }

                Section {
                    placementPicker("Phone", selection: phonePlacementBinding, options: [.unknown, .leftPocket, .rightPocket, .leftHand, .rightHand])
                    placementPicker("Watch", selection: watchPlacementBinding, options: [.leftWrist, .rightWrist, .unknown])
                    placementPicker("Headphone", selection: headphonePlacementBinding, options: [.head, .unknown])
                } header: {
                    Text("Placement metadata")
                }

                Section {
                    Button {
                        store.isStreaming ? stopStreaming() : startStreaming()
                    } label: {
                        Label(store.isStreaming ? "Stop Upload" : "Start Upload", systemImage: store.isStreaming ? "stop.fill" : "dot.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(store.isStreaming ? .red : .green)

                    Button {
                        startUploadAndCSVRecording()
                    } label: {
                        Label("Start Upload + CSV", systemImage: "tray.and.arrow.up.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isStreaming || store.isCSVRecording)

                    Button {
                        store.isCSVRecording ? stopCSVRecording() : startCSVRecording()
                    } label: {
                        Label(store.isCSVRecording ? "Stop Local CSV Recording" : "Start Local CSV Recording", systemImage: store.isCSVRecording ? "pause.rectangle" : "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    exportButton()
                } header: {
                    Text("Controls")
                }

                Section {
                    StatusCard(title: "iPhone", systemImage: "iphone", isLive: phoneRecorder.isRunning, stats: store.sourceStats[.iPhone])
                    StatusCard(title: "Apple Watch", systemImage: "applewatch", isLive: watchReceiver.isReachable, stats: store.sourceStats[.appleWatch])
                    StatusCard(title: "AirPods", systemImage: "airpodspro", isLive: airPodsRecorder.isRunning, stats: store.sourceStats[.airPods])
                } header: {
                    Text("Stream status")
                }

                Section {
                    LabeledContent("UDP packets", value: "\(store.udpPacketCount)")
                    LabeledContent("CSV rows", value: "\(store.csvRowCount)")
                    LabeledContent("Preparation", value: store.streamPreparationStatus)
                    LabeledContent("Gravity baselines", value: "\(store.gravityCalibrationSnapshots.count)")
                    LabeledContent("Last packet age", value: String(format: "%.2f s", lastPacketAge))
                    LabeledContent("Phone motion", value: phoneRecorder.isAvailable ? "Available" : "Unavailable")
                    LabeledContent("Headphone motion", value: airPodsRecorder.isAvailable ? "Available" : "Unavailable")
                    LabeledContent("Headphone connected", value: airPodsRecorder.isConnected ? "Connected" : "Disconnected")
                    LabeledContent("Headphone auth", value: headphoneAuthorizationText)
                    LabeledContent("Watch session", value: watchReceiver.isSupported ? "Supported" : "Unsupported")
                    LabeledContent("Watch reachable", value: watchReceiver.isReachable ? "Reachable" : "Not reachable")
                    LabeledContent("Watch latency", value: String(format: "%.2f s", store.sourceStats[.appleWatch]?.packetAge ?? 0))
                    if !store.lastUDPError.isEmpty {
                        Text(store.lastUDPError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let exportError {
                        Text(exportError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Diagnostics")
                }
            }
            .navigationTitle("MobilePoseLab Streamer")
            .onAppear {
                portText = String(store.streamingConfig.targetPort)
            }
        }
    }

    private var lastPacketAge: Double {
        guard store.lastPacketHostTime > 0 else { return 0 }
        return max(0, ProcessInfo.processInfo.systemUptime - store.lastPacketHostTime)
    }

    private var headphoneAuthorizationText: String {
        switch airPodsRecorder.authorizationStatus {
        case .notDetermined:
            return "Not determined"
        case .restricted:
            return "Restricted"
        case .denied:
            return "Denied"
        case .authorized:
            return "Authorized"
        @unknown default:
            return "Unknown"
        }
    }

    private func startStreaming() {
        if let port = Int(portText) {
            store.streamingConfig.targetPort = port
        }
        store.startStreaming()
        startEnabledRecorders()
    }

    private func startCSVRecording() {
        store.startCSVRecording()
        startEnabledRecorders()
    }

    private func startUploadAndCSVRecording() {
        if let port = Int(portText) {
            store.streamingConfig.targetPort = port
        }
        store.startStreaming()
        store.startCSVRecording()
        startEnabledRecorders()
    }

    private func startEnabledRecorders() {
        if store.streamingConfig.sendPhone {
            phoneRecorder.start(store: store)
        }
        if store.streamingConfig.sendAirPods {
            airPodsRecorder.start(store: store)
        }
        if store.streamingConfig.sendWatch {
            watchReceiver.startWatchCapture(targetHz: store.profile.targetHz)
        }
    }

    private func stopStreaming() {
        store.stopStreaming()
        stopRecordersIfIdle()
    }

    private func stopCSVRecording() {
        store.stopCSVRecording()
        stopRecordersIfIdle()
    }

    private func stopRecordersIfIdle() {
        guard !store.isStreaming, !store.isCSVRecording else { return }
        phoneRecorder.stop()
        airPodsRecorder.stop()
        watchReceiver.stopWatchCapture()
    }

    private var phonePlacementBinding: Binding<BodyPlacement> {
        Binding(get: { store.profile.phonePlacement }, set: { store.profile.phonePlacement = $0 })
    }

    private var watchPlacementBinding: Binding<BodyPlacement> {
        Binding(get: { store.profile.watchPlacement }, set: { store.profile.watchPlacement = $0 })
    }

    private var headphonePlacementBinding: Binding<BodyPlacement> {
        Binding(get: { store.profile.headphonePlacement }, set: { store.profile.headphonePlacement = $0 })
    }

    @ViewBuilder
    private func placementPicker(_ title: String, selection: Binding<BodyPlacement>, options: [BodyPlacement]) -> some View {
        Picker(title, selection: selection) {
            ForEach(options) { placement in
                Text(placement.displayName).tag(placement)
            }
        }
    }

    @ViewBuilder
    private func exportButton() -> some View {
        Button {
            do {
                csvURL = try store.exportCSV()
                exportError = nil
            } catch {
                exportError = error.localizedDescription
            }
        } label: {
            Label("Export CSV", systemImage: "square.and.arrow.up")
        }

        if let csvURL {
            ShareLink(item: csvURL) {
                Label("Share \(csvURL.lastPathComponent)", systemImage: "paperplane")
            }
        }
    }
}

private struct StatusCard: View {
    var title: String
    var systemImage: String
    var isLive: Bool
    var stats: StreamSourceStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(isLive ? "Live" : "Idle")
                    .font(.caption)
                    .foregroundStyle(isLive ? .green : .secondary)
            }
            HStack {
                Text(String(format: "%.1f Hz", stats?.hz ?? 0))
                    .font(.caption.monospacedDigit())
                Spacer()
                Text("packets \(stats?.packetCount ?? 0)")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            HStack {
                Text(String(format: "age %.2fs", stats?.packetAge ?? 0))
                Spacer()
                Text("drop \(stats?.droppedFrameEstimate ?? 0)")
                Text(String(format: "|a| %.2f", stats?.lastAccelerationNorm ?? 0))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack {
                Text(String(format: "|q| %.3f", stats?.lastQuaternionNorm ?? 0))
                Spacer()
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
