import SwiftUI
import PopinVRTracking

@MainActor
final class PopinVRSessionModel: ObservableObject {
    @Published var headPose: PopinVRHeadPose?
    @Published var trackingState = "waiting"
    @Published var handCount = 0
    @Published var jointCount = 0
    @Published var errorMessage: String?

    private var tracker: PopinVRTracking?

    func start() {
        guard tracker == nil else { return }
        guard let modelPath = Bundle.main.path(
            forResource: "hand_landmarker",
            ofType: "task",
            inDirectory: "Models"
        ) else {
            errorMessage = "hand_landmarker.task is missing. Run ios/Scripts/download_hand_model.sh and rebuild."
            return
        }

        let newTracker = PopinVRTracking(modelPath: modelPath, imageOrientation: .up)
        newTracker.onPose = { [weak self] pose in
            self?.headPose = pose
            self?.trackingState = pose.trackingState
        }
        newTracker.onFrame = { [weak self] frame in
            self?.handCount = frame.hands.count
            self?.jointCount = frame.hands.reduce(0) { $0 + $1.joints.count }
        }
        newTracker.onError = { [weak self] error in
            self?.errorMessage = error.localizedDescription
        }

        tracker = newTracker
        do {
            try newTracker.start()
        } catch {
            errorMessage = error.localizedDescription
            tracker = nil
        }
    }

    func stop() {
        tracker?.stop()
        tracker = nil
    }
}

struct ContentView: View {
    @StateObject private var model = PopinVRSessionModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            PopinVRStereoView(headPose: model.headPose)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 5) {
                Text("POPINVR")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .tracking(2)
                Text("6DoF  ·  \(model.trackingState)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Text("Hands  \(model.handCount)  ·  Joints  \(model.jointCount)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                if let error = model.errorMessage {
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 12))
            .padding(12)
        }
        .statusBarHidden(true)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
