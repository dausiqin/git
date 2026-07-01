import SwiftUI

struct WatchCaptureView: View {
    @StateObject private var streamer = WatchMotionStreamer()

    var body: some View {
        VStack(spacing: 10) {
            Text(streamer.isRunning ? "Streaming" : "Ready")
                .font(.headline)
            Text(streamer.isReachable ? "Phone reachable" : "Phone not reachable")
                .font(.caption)
                .foregroundStyle(streamer.isReachable ? .green : .orange)
            Text(streamer.isRuntimeActive ? "Runtime active" : "Runtime idle")
                .font(.caption2)
                .foregroundStyle(streamer.isRuntimeActive ? .green : .secondary)
            Text(streamer.isWorkoutActive ? "Workout active" : "Workout idle")
                .font(.caption2)
                .foregroundStyle(streamer.isWorkoutActive ? .green : .secondary)
            Text(String(format: "%.2f %.2f %.2f", streamer.latestAcceleration.x, streamer.latestAcceleration.y, streamer.latestAcceleration.z))
                .font(.caption2.monospaced())
            Text(String(format: "Motion %.1f Hz", streamer.motionHz))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text(String(format: "HR %.0f bpm", streamer.latestHeartRateBpm))
                .font(.caption2.monospaced())
                .foregroundStyle(streamer.latestHeartRateBpm > 0 ? .green : .secondary)
            Text(lastSendText)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text("Sent \(streamer.sentSampleCount)  Buf \(streamer.bufferedSampleCount)  Drop \(streamer.droppedBatchCount)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if !streamer.lastError.isEmpty {
                Text(streamer.lastError)
                    .font(.caption2)
                    .lineLimit(2)
                    .foregroundStyle(.red)
            }
            Button(streamer.isRunning ? "Stop Workout Streaming" : "Start Workout Streaming") {
                streamer.isRunning ? streamer.stop() : streamer.start(targetHz: 30)
            }
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var lastSendText: String {
        guard streamer.lastSendTime > 0 else {
            return "Last send never"
        }
        let age = max(0, Date().timeIntervalSince1970 - streamer.lastSendTime)
        return String(format: "Last send %.1fs ago", age)
    }
}
