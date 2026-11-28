import SwiftUI
import PopinVRTracking

@MainActor
final class PopinVRSessionModel: ObservableObject {
    @Published var headPose: PopinVRHeadPose?
    @Published var trackingState = "待機中"
    @Published var handCount = 0
    @Published var jointCount = 0
    @Published var trackingFrame: PopinVRTrackingFrame?
    @Published var errorMessage: String?
    @Published var isRunning = false

    private var tracker: PopinVRTracking?

    func start() {
        guard tracker == nil else { return }
        errorMessage = nil
        guard let modelPath = Bundle.main.path(
            forResource: "hand_landmarker",
            ofType: "task",
            inDirectory: "Models"
        ) else {
            errorMessage = "手の認識モデルがアプリ内にありません。モデルを取得して再ビルドしてください。"
            return
        }

        let newTracker = PopinVRTracking(modelPath: modelPath, imageOrientation: .up)
        newTracker.onPose = { [weak self] pose in
            Task { @MainActor in
                self?.headPose = pose
                self?.trackingState = pose.trackingState
            }
        }
        newTracker.onFrame = { [weak self] frame in
            Task { @MainActor in
                self?.handCount = frame.hands.count
                self?.jointCount = frame.hands.reduce(0) { $0 + $1.joints.count }
                self?.trackingFrame = frame
            }
        }
        newTracker.onError = { [weak self] error in
            Task { @MainActor in self?.errorMessage = error.localizedDescription }
        }

        tracker = newTracker
        do {
            try newTracker.start()
            isRunning = true
            trackingState = "トラッキング開始"
        } catch {
            errorMessage = error.localizedDescription
            tracker = nil
            isRunning = false
        }
    }

    func stop() {
        tracker?.stop()
        tracker = nil
        isRunning = false
        trackingState = "停止中"
        trackingFrame = nil
        handCount = 0
        jointCount = 0
    }
}

struct ContentView: View {
    @StateObject private var model = PopinVRSessionModel()
    @State private var showViewer = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.025, green: 0.04, blue: 0.09), Color(red: 0.07, green: 0.09, blue: 0.17)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        statusPanel
                        handPanel
                        trackingControls
                        featureGrid
                        footer
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 30)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(isPresented: $showViewer) {
                ZStack(alignment: .topTrailing) {
                    PopinVRStereoView(headPose: model.headPose).ignoresSafeArea()
                    Button {
                        showViewer = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(18)
                    }
                }
                .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showSettings) {
                settingsSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(LinearGradient(colors: [.cyan, Color(red: 0.25, green: 0.42, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 58, height: 58)
                Image(systemName: "visionpro")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("POPINVR")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .tracking(2.4)
                Text("iPhone XR Runtime")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.09), in: Circle())
            }
            .accessibilityLabel("設定")
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SYSTEM STATUS")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(.cyan)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.isRunning ? .green : .orange)
                        .frame(width: 7, height: 7)
                    Text(model.isRunning ? "LIVE" : "STANDBY")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.isRunning ? "Tracking active" : "Ready when you are")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
            }
            Text(model.isRunning ? "ARKitとMediaPipeがデバイス上で動作しています。" : "起動直後はカメラを起動しません。準備ができたらトラッキングを開始できます。")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))
            HStack(spacing: 9) {
                metricPill(icon: "viewfinder", title: "6DoF", value: model.isRunning ? model.trackingState : "待機")
                metricPill(icon: "hand.raised.fill", title: "HANDS", value: "\(model.handCount)")
                metricPill(icon: "point.3.connected.trianglepath.dotted", title: "JOINTS", value: "\(model.jointCount)")
            }
        }
        .padding(18)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.09), lineWidth: 1))
    }

    private func metricPill(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.8)
            }
            .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
    }

    private var handPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("HAND TRACKING")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(.cyan)
                    Text("3D Hand Preview")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                }
                Spacer()
                Text("21 JOINTS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            PopinVRHandModelView(frame: model.trackingFrame)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    if model.handCount == 0 {
                        VStack(spacing: 8) {
                            Image(systemName: "hand.raised.fingers.spread.fill")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(.cyan.opacity(0.8))
                            Text(model.isRunning ? "カメラに手をかざしてください" : "トラッキング開始後に3Dモデルを表示")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        .allowsHitTesting(false)
                    }
                }
            Text("指ごとの関節を立体カプセルで接続し、掌もメッシュ状に表示します。")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(16)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private var trackingControls: some View {
        VStack(spacing: 10) {
            Button {
                if model.isRunning { model.stop() } else { model.start() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.isRunning ? "pause.fill" : "play.fill")
                    Text(model.isRunning ? "トラッキングを停止" : "トラッキングを開始")
                }
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(model.isRunning ? Color.orange.opacity(0.8) : Color.cyan.opacity(0.85), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            Button {
                showViewer = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.split.2x1")
                    Text("ステレオビューアを開く")
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var featureGrid: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("RUNTIME MODULES")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.5))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                moduleCard("ARKit", subtitle: "6DoF Head Pose", icon: "arkit", active: model.isRunning)
                moduleCard("MediaPipe", subtitle: "21-point Hands", icon: "hand.raised.fingers.spread.fill", active: model.isRunning)
                moduleCard("Metal", subtitle: "Stereo Renderer", icon: "cube.transparent", active: true)
                moduleCard("MoltenVK", subtitle: "Embedded · lazy init", icon: "cpu", active: true)
            }
        }
    }

    private func moduleCard(_ title: String, subtitle: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(active ? .cyan : .white.opacity(0.5))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 9)).foregroundStyle(.white.opacity(0.48))
            }
            Spacer(minLength: 0)
            Circle().fill(active ? .green : .gray).frame(width: 6, height: 6)
        }
        .padding(11)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var footer: some View {
        Text("POPINVR  •  LOCAL XR EXPERIMENT  •  BUILD 0.1")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.28))
            .frame(maxWidth: .infinity)
            .padding(.top, 3)
    }

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section("Tracking") {
                    LabeledContent("Head tracking", value: "ARKit World Tracking")
                    LabeledContent("Hand model", value: "MediaPipe 21 joints")
                    LabeledContent("Inference", value: "On-device")
                }
                Section("Graphics") {
                    LabeledContent("Compositor", value: "Metal / SBS")
                    LabeledContent("Vulkan backend", value: "MoltenVK embedded · lazy load")
                }
                Section {
                    Text("カメラは「トラッキングを開始」を押したときだけ使用します。映像はアプリ内で処理されます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("PopinVR 設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { showSettings = false }
                }
            }
        }
    }
}
