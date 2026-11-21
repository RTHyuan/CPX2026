import SwiftUI
import PhotosUI

private enum Palette {
    static let page = Color(red: 0.96, green: 0.965, blue: 0.94)
    static let ink = Color(red: 0.055, green: 0.15, blue: 0.145)
    static let teal = Color(red: 0.025, green: 0.335, blue: 0.285)
    static let muted = Color(red: 0.25, green: 0.33, blue: 0.31)
    static let wash = Color(red: 0.875, green: 0.92, blue: 0.865)
    static let lime = Color(red: 0.82, green: 0.93, blue: 0.56)
}

struct RootView: View {
    @ObservedObject var scanner: Scanner
    @FocusState private var editing: Bool
    @State private var showInfo = false
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.openURL) private var openURL
    @State private var picked: PhotosPickerItem?
    @State private var showRaw = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let target = scanner.target { scanView(target) } else { home }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
                .frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.page.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if scanner.target == nil {
                        Label("PathSense", systemImage: "viewfinder").labelStyle(.titleAndIcon).font(.headline).foregroundStyle(Palette.teal).accessibilityLabel("PathSense")
                    } else {
                        Button { scanner.end(); showRaw = false } label: { Label("换目标", systemImage: "chevron.left") }.accessibilityIdentifier("end")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button { showInfo = true } label: { Image(systemName: "questionmark.circle").frame(minWidth: 38, minHeight: 40) }.accessibilityLabel("使用说明").accessibilityIdentifier("help") }
            }
            .toolbarBackground(Palette.page, for: .navigationBar)
        }
        .tint(Palette.teal).foregroundStyle(Palette.ink).preferredColorScheme(.light)
        .sheet(isPresented: $showInfo) { info }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            let request = scanner.startImport()
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { scanner.loadPhoto(data, from: "选取的照片", request: request) }
                else { scanner.importError(for: request) }
                if picked == item { picked = nil }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in scanner.camera.updateOrientation(UIDevice.current.orientation) }
    }

    @ViewBuilder private var home: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "signpost.right.fill").font(.title2).foregroundStyle(Palette.lime).accessibilityHidden(true)
            Text("找一块标牌").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text("输入要找的房号或设施，听听眼前的标识写了什么。").font(.body).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).padding(22).background(Palette.ink, in: RoundedRectangle(cornerRadius: 23))
        VStack(alignment: .leading, spacing: 11) {
            Text("要找哪里？").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            HStack {
                Image(systemName: "number").foregroundStyle(Palette.teal).accessibilityHidden(true)
                TextField("房号，例如 305", text: $scanner.entry).textInputAutocapitalization(.characters).autocorrectionDisabled().submitLabel(.go).focused($editing)
                    .accessibilityLabel("目标房号或设施").accessibilityHint("支持键盘听写，例如我要找三零五教室。")
                    .accessibilityIdentifier("targetInput").onSubmit { begin(.live) }
            }.padding(15).background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay { RoundedRectangle(cornerRadius: 14).stroke(Palette.muted, lineWidth: 1) }
            Text("可用键盘听写，说「我要找三零五教室」。").font(.footnote).foregroundStyle(Palette.muted)
            if !scanner.validation.isEmpty { Text(scanner.validation).font(.callout).foregroundStyle(.red).accessibilityIdentifier("validation") }
            adaptiveButtons(Facility.allCases.map(\.rawValue), prefix: "facility") { value in scanner.entry = value; editing = false }
            Button { begin(.live) } label: { Label("开始扫描", systemImage: "camera.viewfinder") }.buttonStyle(ActionButton()).accessibilityIdentifier("startLive")
            Button { if scanner.entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { scanner.entry = "305" }; begin(.photos) } label: { Label("用照片试一试", systemImage: "photo.on.rectangle") }.buttonStyle(ActionButton(secondary: true)).accessibilityIdentifier("startPhotos")
        }
        if !scanner.history.isEmpty {
            VStack(alignment: .leading, spacing: 8) { Text("最近找过").font(.headline); adaptiveButtons(scanner.history, prefix: "recent") { scanner.entry = $0; editing = false } }
        }
        Toggle(isOn: $scanner.sound) { Label("语音播报", systemImage: "speaker.wave.2") }.font(.headline).accessibilityIdentifier("voice")
        Label("站定后扫描。行走时请继续使用惯常的出行辅助。", systemImage: "figure.stand").font(.footnote).foregroundStyle(Palette.muted)
    }

    private func begin(_ mode: ScanMode) { editing = false; showRaw = false; scanner.begin(mode: mode) }
    private func adaptiveButtons(_ items: [String], prefix: String, pick: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: type.isAccessibilitySize ? 125 : 70), spacing: 7)], alignment: .leading, spacing: 7) {
            ForEach(items, id: \.self) { item in
                Button(item) { pick(item) }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44).background(Palette.wash, in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("\(prefix)-\(item)")
            }
        }
    }

    @ViewBuilder private func scanView(_ target: Destination) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("正在寻找").font(.headline).foregroundStyle(Palette.muted)
            Text(target.text).font(.system(.largeTitle, design: .rounded, weight: .bold)).accessibilityIdentifier("currentTarget")
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
        HStack(spacing: 4) {
            ForEach(ScanMode.allCases) { mode in
                Button { scanner.selectMode(mode); showRaw = false } label: {
                    Text(mode.rawValue).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(scanner.mode == mode ? Color.white : Palette.ink).background(scanner.mode == mode ? Palette.teal : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                }.accessibilityAddTraits(scanner.mode == mode ? .isSelected : []).accessibilityIdentifier("mode-\(mode)")
            }
        }.padding(4).background(Palette.wash, in: RoundedRectangle(cornerRadius: 13))
        if scanner.mode == .photos { photoTools } else { cameraPanel }
        VStack(alignment: .leading, spacing: 9) {
            Label(scanner.isPaused ? "扫描已暂停" : (scanner.reading?.title ?? "当前提示"), systemImage: scanner.reading?.isMatch == true ? "checkmark.circle.fill" : "waveform").font(.headline).foregroundStyle(Palette.teal)
            Text(scanner.message).font(.title3.weight(.medium)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("feedbackText")
            if let evidence = scanner.reading?.evidence, !evidence.isEmpty { Text("标识文字  \(evidence)").font(.subheadline.monospacedDigit()).foregroundStyle(Palette.muted) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
        HStack(spacing: 10) {
            Button { scanner.repeatLast() } label: { Label("重听", systemImage: "speaker.wave.2") }.buttonStyle(ActionButton(secondary: true)).accessibilityIdentifier("repeat")
            Button { scanner.pauseOrResume() } label: { Label(scanner.isPaused ? "继续" : "暂停", systemImage: scanner.isPaused ? "play.fill" : "pause.fill") }.buttonStyle(ActionButton(secondary: true)).accessibilityIdentifier("pause")
        }
        if !scanner.raw.isEmpty {
            DisclosureGroup("识别原文", isExpanded: $showRaw) { Text(scanner.raw.map(\.text).joined(separator: "\n")).font(.body).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }.accessibilityIdentifier("ocrDetails")
        }
        Button("结束扫描") { scanner.end(); showRaw = false }.frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("finish")
    }

    @ViewBuilder private var photoTools: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let photo = scanner.photo {
                Image(uiImage: photo).resizable().scaledToFit().frame(maxWidth: .infinity).frame(maxHeight: 115).accessibilityHidden(true)
                Text(scanner.source).font(.caption).foregroundStyle(Palette.muted)
            }
            PhotosPicker(selection: $picked, matching: .images) { Label("选取自己的标牌照片", systemImage: "photo") }.buttonStyle(ActionButton(secondary: true)).accessibilityIdentifier("photoPicker")
            Text("练习标牌").font(.headline).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: type.isAccessibilitySize ? 120 : 78))], spacing: 7) {
                ForEach(PracticeCard.allCases) { card in Button(card.label) { scanner.practice(card) }.font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 44).background(.white, in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("practice-\(card.rawValue)") }
            }
        }.disabled(scanner.isPaused)
    }

    @ViewBuilder private var cameraPanel: some View {
        if scanner.capture == .ready && !scanner.isPaused {
            CameraPreview(session: scanner.camera.session).frame(height: 174).clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay { Image(systemName: "viewfinder").font(.system(size: 98, weight: .ultraLight)).foregroundStyle(.white).shadow(radius: 2) }.accessibilityHidden(true)
            if scanner.mode == .snapshot { Button { scanner.shutter() } label: { Label(scanner.isReading ? "正在识字…" : "拍照识字", systemImage: "camera") }.buttonStyle(ActionButton()).disabled(scanner.isReading).accessibilityIdentifier("shutter") }
        } else if scanner.capture == .denied && !scanner.isPaused {
            Button { if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) } } label: { Label("打开相机权限设置", systemImage: "gearshape") }.buttonStyle(ActionButton(secondary: true))
        } else if scanner.capture == .unavailable && !scanner.isPaused {
            Button { scanner.selectMode(.photos) } label: { Label("改用照片识字", systemImage: "photo") }.buttonStyle(ActionButton(secondary: true)).accessibilityIdentifier("fallback")
        }
    }

    private var info: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 20) {
                Text("在原地核对标牌").font(.largeTitle.bold())
                Text("先选目标，再缓慢转动手机。手机读到与目标相关的文字时会提醒你。区间和目录提供线索，独立房号需要现场核对。")
                Text("怎样操作").font(.title2.bold())
                Text("点目标输入框，再点系统键盘上的听写按钮。说「我要找零三零五教室」会选中 0305，说「帮我找电梯」会选中电梯。核对目标后点开始扫描。")
                Text("连续扫描会等待多帧确认。拍一次和照片模式会说明这是单张图片的结果。点重听可以再听一遍，点换目标开始新的查找。")
                Text("相机与隐私").font(.title2.bold())
                Text("本机处理镜头画面和导入的照片。最近找过的目标保存在这台设备。行走、避障和紧急疏散请遵循现场设施和既有辅助方式。")
            }.padding(22).frame(maxWidth: 600) }.toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showInfo = false } } }
        }.presentationDragIndicator(.visible)
    }
}

private struct ActionButton: ButtonStyle {
    var secondary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).multilineTextAlignment(.center).frame(maxWidth: .infinity).frame(minHeight: 46).padding(.horizontal, 5).padding(.vertical, 2)
            .foregroundStyle(secondary ? Palette.teal : .white).background(secondary ? Palette.wash : Palette.teal, in: RoundedRectangle(cornerRadius: 13)).opacity(configuration.isPressed ? 0.72 : 1)
    }
}
