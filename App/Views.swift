import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var scanner: Scanner
    @FocusState private var editing: Bool
    @State private var showInfo = false
    @State private var confirmCloud = false
    @State private var importMap = false
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.openURL) private var openURL

    private var navigating: Binding<Bool> {
        Binding(get: { scanner.target != nil }, set: { presented in
            if !presented, scanner.target != nil { scanner.end() }
        })
    }
    var body: some View {
        NavigationStack {
            page {
                destinationEntry
                group("常用设施") { facilityRows }
                if !scanner.history.isEmpty { group("最近找过") { recentRows } }
                Toggle(isOn: $scanner.sound) { Label("语音播报", systemImage: "speaker.wave.2") }
                    .tint(Palette.accent).padding(.horizontal, 19).padding(.vertical, 13)
                    .surface(Palette.paper, radius: Radius.control).accessibilityIdentifier("voice")
            }
            .navigationTitle("室内寻路")
            .toolbar { helpItem }
            .navigationDestination(isPresented: navigating) {
                page(spacing: 14) {
                    if let route = scanner.journey { navigationContent(route) }
                }
                .navigationTitle("室内导航").navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        navIcon("chevron.backward", label: "返回，换目标", id: "end") { scanner.end() }
                    }.sharedBackgroundVisibility(.hidden)
                    helpItem
                }
            }
        }
        .background { HapticAnchor(feedback: scanner.feedback).allowsHitTesting(false).accessibilityHidden(true) }
        .tint(Palette.accent)
        .sheet(isPresented: $showInfo) { instructions }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            scanner.camera.updateOrientation(UIDevice.current.orientation)
        }
    }

    private func page<Content: View>(spacing: CGFloat = 22, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing, content: content)
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 32)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively).background(Palette.page)
    }
    private var helpItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            navIcon("questionmark", label: "使用说明", id: "help") { scanner.cancelForHelp(); showInfo = true }
        }.sharedBackgroundVisibility(.hidden)
    }
    private func navIcon(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.primary).accessibilityLabel(label).accessibilityIdentifier(id)
    }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 10).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content).surface(Palette.paper, radius: Radius.panel)
        }
    }
    private var destinationEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("你想去哪里？").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Button { editing=false; scanner.dictate() } label: {
                Label(scanner.listening ? "说完，开始导航" : "说出目的地", systemImage:scanner.listening ? "waveform" : "mic.fill")
            }.buttonStyle(SignButton(tone:.primary)).accessibilityIdentifier("speakDestination")
            if scanner.listening { Button("取消听写") { scanner.cancelDictation() }.buttonStyle(SignButton()) }
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("房号、科室或店名", text: $scanner.entry)
                    .font(.body).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go).focused($editing).onSubmit(begin)
                    .accessibilityLabel("目的地名称").accessibilityHint("也可以使用键盘听写。")
                    .accessibilityIdentifier("targetInput")
                if editing && !scanner.entry.isEmpty {
                    Button { scanner.entry = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("清除目的地")
                }
            }.padding(.horizontal, 16).frame(minHeight: 54)
                .surface(Palette.paper, radius: Radius.control)
            if !scanner.validation.isEmpty {
                Text(scanner.validation).font(.callout).foregroundStyle(.red).accessibilityIdentifier("validation")
            }
            Button(action: begin) { Label("开始导航", systemImage: "location.fill") }
                .buttonStyle(SignButton()).accessibilityIdentifier("startLive")
            Text("站定后慢慢转动手机，听取沿途的标识提示。")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
    }
    private func begin() { editing = false; scanner.begin() }
    @ViewBuilder private var facilityRows: some View {
        ForEach(Array(Facility.allCases.enumerated()), id: \.element) { index, item in
            if index != 0 { Divider().padding(.leading, 54) }
            let symbol: String = switch item {
            case .lift: "arrow.up.arrow.down"; case .exit: "door.left.hand.open"
            case .stairs: "stairs"; case .restroom: "figure.stand.dress.line.vertical.figure"
            }
            targetRow(item.rawValue, symbol: symbol, id: "facility-\(item.rawValue)")
        }
    }
    @ViewBuilder private var recentRows: some View {
        ForEach(Array(scanner.history.enumerated()), id: \.element) { index, name in
            if index != 0 { Divider().padding(.leading, 54) }
            targetRow(name, symbol: "clock.arrow.circlepath", id: "recent-\(name)")
        }
    }
    private func targetRow(_ name: String, symbol: String, id: String) -> some View {
        let selected = scanner.entry == name
        return Button { scanner.entry = name; editing = false } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(Palette.accent).accessibilityHidden(true)
                Text(verbatim: name).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Palette.accent).accessibilityHidden(true) }
            }.padding(.horizontal, 18).padding(.vertical, 11).frame(minHeight: 50).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier(id)
    }

    @ViewBuilder private func navigationContent(_ route: WayfindingJourney) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("目的地").font(.subheadline).foregroundStyle(.secondary)
            Text(verbatim: route.searchTarget.text).font(.largeTitle.bold()).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("currentTarget")
        }.padding(.horizontal, 4).accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
        JourneyCard(scanner: scanner, route: route)
        if route.stage != .arrived {
            actionRow
            if scanner.canGuide, scanner.lastSpatialCue == .face {
                Button("手机已朝向身体前方") { scanner.bodyForward() }.buttonStyle(SignButton(tone:.primary)).accessibilityIdentifier("bodyForward")
            }
            if scanner.canGuide {
                Button("重新寻找平坦过道") { scanner.rescanPassage() }.buttonStyle(SignButton()).accessibilityIdentifier("rescanPassage")
                if scanner.canCheckDoor { Button("我已在门边，已核对这扇门") { scanner.confirmDoor() }.buttonStyle(SignButton()).accessibilityIdentifier("manualDoor") }
            }
            cameraPanel
            Button { scanner.dictate() } label: { Label("改说目的地",systemImage:"mic.fill") }.buttonStyle(SignButton()).accessibilityIdentifier("changeByVoice")
            Text(scanner.networkNote).font(.footnote).foregroundStyle(.secondary)
        }
        if !route.history.isEmpty { JourneyHistory(route: route) }
        if scanner.canGuide && !route.target.isClassroomDoor {
            if route.stage == .survey || route.stage == .doorway {
                Button("我已在公共区域") { scanner.publicArea() }.buttonStyle(SignButton()).accessibilityIdentifier("publicArea")
            } else {
                Button("重新确认位置") { scanner.locateAgain() }.buttonStyle(SignButton()).accessibilityIdentifier("relocalize")
            }
        }
        Button(route.stage == .arrived ? "完成" : "结束导航") { scanner.end() }
            .buttonStyle(SignButton(tone: route.stage == .arrived ? .primary : .secondary)).accessibilityIdentifier("finish")
            #if DEBUG && targetEnvironment(simulator)
            .accessibilityValue(route.stage == .arrived && ProcessInfo.processInfo.environment["PATHSENSE_TEST_FEEDBACK"] == "1" ? scanner.metricsText : "")
            #endif
    }
    private var actionRow: some View {
        let layout = type.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Button { scanner.repeatLast() } label: { Label("重听", systemImage: "speaker.wave.2") }
                .buttonStyle(SignButton()).accessibilityIdentifier("repeat")
            if scanner.canGuide || scanner.isPaused {
                Button { scanner.pauseOrResume() } label: {
                    Label(scanner.isPaused ? "继续" : "暂停", systemImage: scanner.isPaused ? "play.fill" : "pause.fill")
                }.buttonStyle(SignButton()).accessibilityIdentifier("pause")
                #if DEBUG && targetEnvironment(simulator)
                .accessibilityValue(scanner.isPaused && ProcessInfo.processInfo.environment["PATHSENSE_TEST_FEEDBACK"] == "1" ? scanner.metricsText : "")
                #endif
            }
        }
    }
    @ViewBuilder private var cameraPanel: some View {
        if !scanner.isPaused {
            switch scanner.capture {
            case .ready:
                ZStack(alignment: .bottomLeading) {
                    cameraSurface.frame(maxWidth: .infinity).frame(height: type.isAccessibilitySize ? 148 : 192).clipped()
                        .overlay { Image(systemName: "viewfinder").font(.system(size: 64, weight: .thin)).foregroundStyle(.white.opacity(0.80)).shadow(radius: 1) }
                        .accessibilityHidden(true)
                    Label(scanner.cameraLabel, systemImage: "video.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
                        .surface(.black.opacity(0.72), radius: 14).padding(12).accessibilityIdentifier("liveStatus")
                }.clipShape(G2Rectangle(Radius.panel))
            case .denied:
                Button { if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) } } label: {
                    Label("打开相机权限设置", systemImage: "gearshape")
                }.buttonStyle(SignButton()).accessibilityIdentifier("cameraSettings")
            case .unavailable, .failed, .interrupted, .restricted:
                Button { scanner.retryCamera() } label: { Label("重试相机", systemImage: "arrow.clockwise") }
                    .buttonStyle(SignButton()).accessibilityIdentifier("retryCamera")
            case .starting: ProgressView().frame(maxWidth: .infinity).accessibilityLabel("正在打开相机")
            }
        }
    }
    @ViewBuilder private var cameraSurface: some View {
        #if DEBUG && targetEnvironment(simulator)
        if scanner.camera.isReplaying {
            if let preview = scanner.replayPreview {
                Image(uiImage: preview).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity).background(.black)
            } else { Color.black }
        } else { CameraPreview(session: scanner.camera.session) }
        #else
        CameraPreview(session: scanner.camera.session)
        #endif
    }
    private var instructions: some View {
        NavigationStack {
            List {
                info("开始导航", "location", "点“说出目的地”，例如“带我去教室门口”。也可以输入房号、科室或店名。首次导航请允许后置相机。")
                info("查看路牌", "viewfinder", "转动手机环顾四周。看到牌时，让名称、楼层和对应箭头一起入镜。导航会记住标识的位置。")
                info("现场核对", "signpost.right", "请核对通道和独立门牌后再确认。行走和避障时，继续使用惯常的出行辅助。")
                info("相机与隐私", "lock", "位姿、近场通行图和识别默认在本次导航中处理。启用云端后，选中的画面、目的地、相关位姿和线索会经演示 Mac 发给 DeepSeek。暂停、进入后台或结束会停止采集和发送。中文语音输入使用本机识别。")
                Section("云端视觉") {
                    Text(scanner.networkNote).accessibilityIdentifier("cloudStatus")
                    TextField("演示 Mac 显示的完整配对地址",text:$scanner.proxyAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).disabled(scanner.cloudEnabled)
                        .accessibilityIdentifier("proxyAddress")
                    Button(scanner.cloudEnabled ? "切换到仅本机" : "启用云端视觉") {
                        if scanner.cloudEnabled { scanner.configureCloud(enable:false) } else { confirmCloud=true }
                    }.accessibilityIdentifier("enableCloud")
                }
                Section("楼层参考图") {
                    Text(scanner.mapNote)
                    Button("导入本地楼层图") { importMap=true }; Button("使用无图导航") { scanner.clearPrior() }
                }
                if !scanner.metricsText.isEmpty {
                    Section("本次测试记录") { ShareLink("分享计时和停步记录",item:scanner.metricsText) }
                }
            }.alert("允许发送导航关键帧？",isPresented:$confirmCloud) {
                Button("仅本机使用",role:.cancel) {}; Button("允许关键帧") { scanner.configureCloud(enable:true) }
            } message: { Text("目的地、选中的现场画面、对应位姿和近期导航线索会经配对的 Mac 发送给 DeepSeek。画面可能包含旁人。你可以随时切回仅本机。") }
            .fileImporter(isPresented:$importMap,allowedContentTypes:[.json]) { result in if case .success(let url)=result { scanner.loadPrior(url) } }
            .listStyle(.insetGrouped).navigationTitle("使用说明").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { showInfo = false } }
                        .sharedBackgroundVisibility(.hidden)
                }
        }.presentationDragIndicator(.visible)
    }
    private func info(_ title: String, _ symbol: String, _ copy: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).font(.headline).accessibilityAddTraits(.isHeader)
                Text(copy).font(.body).fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 5)
        }
    }
}
