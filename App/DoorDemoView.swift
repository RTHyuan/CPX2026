import SwiftUI

/// The destination-and-facilities interface, backed by the live visual guide.
struct DoorDemoView: View {
    @StateObject private var demo = DoorDemoSession()
    @ObservedObject var scanner: Scanner
    @State private var showInfo = false
    @State private var showMap = false
    #if DEBUG && targetEnvironment(simulator)
    @State private var didAutoStart = false
    #endif
    @FocusState private var editing: Bool
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.openURL) private var openURL

    private func text(_ chinese: String, _ english: String) -> String { demo.text(chinese, english) }
    private var navigating: Binding<Bool> {
        Binding(get: { demo.running || demo.arrived }, set: { if !$0 { demo.returnHome() } })
    }

    var body: some View {
        NavigationStack {
            page {
                destinationEntry
                group(text("常用设施", "Common destinations")) { facilityRows }
                if !demo.history.isEmpty { group(text("最近找过", "Recent destinations")) { recentRows } }
                if hasLocalMap { localMapCard }
                Toggle(isOn: $demo.sound) { Label(text("语音播报", "Spoken guidance"), systemImage: "speaker.wave.2") }
                    .tint(Palette.accent).padding(.horizontal, 19).padding(.vertical, 13)
                    .surface(Palette.paper, radius: Radius.control).accessibilityIdentifier("demoVoice")
                Picker("Language / 语言", selection: Binding(get: { demo.language }, set: { demo.setLanguage($0) })) {
                    Text("中文").tag(GuidanceLanguage.chinese)
                    Text("English").tag(GuidanceLanguage.english)
                }.pickerStyle(.segmented).disabled(demo.listening).accessibilityIdentifier("demoLanguage")
            }
            .navigationTitle(text("室内寻路", "Indoor Navigation"))
            .toolbar { helpItem }
            .navigationDestination(isPresented: navigating) {
                page(spacing: 14) { guidance }
                    .navigationTitle(text("室内导航", "Indoor Navigation")).navigationBarTitleDisplayMode(.inline)
                    .navigationBarBackButtonHidden()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            navIcon("chevron.backward", label: text("返回，换目标", "Back, change destination"), id: "demoBack") { demo.returnHome() }
                        }.sharedBackgroundVisibility(.hidden)
                        helpItem
                    }
            }
        }
        .environment(\.locale, Locale(identifier: demo.language.rawValue))
        .tint(Palette.accent)
        .background { HapticAnchor(feedback: demo.feedback).allowsHitTesting(false).accessibilityHidden(true) }
        .sheet(isPresented: $showInfo) { instructions }
        #if DEBUG && targetEnvironment(simulator)
        .onAppear {
            if !didAutoStart, ProcessInfo.processInfo.arguments.contains("--simulator-demo-autostart") {
                didAutoStart = true; begin()
            }
        }
        #endif
        .onChange(of: phase) { _, value in
            if value == .background || (value == .inactive && demo.running) { demo.background() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            demo.camera.updateOrientation(UIDevice.current.orientation)
        }
    }

    private func page<Content: View>(spacing: CGFloat = 22, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing, content: content)
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 32)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively).background(Palette.page)
    }
    private var helpItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            navIcon("questionmark", label: text("使用说明", "Instructions"), id: "demoHelp") {
                demo.cancelDictation()
                if demo.running && !demo.paused { demo.pauseOrResume() }
                showInfo = true
            }
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
            Text(text("你想去哪里？", "Where would you like to go?"))
                .font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Button { editing = false; demo.dictate() } label: {
                switch demo.dictationPhase {
                case .idle: Label(text("说出目的地", "Say your destination"), systemImage: "mic.fill")
                case .preparing: Label(text("正在打开麦克风…", "Opening the microphone…"), systemImage: "mic")
                case .listening: Label(text("说完，开始导航", "Done speaking, start"), systemImage: "waveform")
                case .finishing: Label(text("正在确认目的地…", "Confirming destination…"), systemImage: "text.bubble")
                }
            }.buttonStyle(SignButton(tone: .primary)).accessibilityIdentifier("demoSpeakDestination")
            if demo.listening {
                Text(text("正在听，请说出目的地。", "Listening. Please say your destination.")).font(.callout)
                Button(text("取消听写", "Cancel dictation")) { demo.cancelDictation() }.buttonStyle(SignButton())
            }
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(text("房号、科室或店名", "Room, department, or shop"), text: $demo.destination)
                    .font(.body).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go).focused($editing).onSubmit(begin).disabled(demo.listening)
                    .accessibilityLabel(text("目的地名称，默认门口", "Destination, doorway by default"))
                    .accessibilityHint(text("也可以使用键盘听写。", "You can also use keyboard dictation."))
                    .accessibilityIdentifier("demoDestination")
                if editing && !demo.destination.isEmpty {
                    Button { demo.destination = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel(text("清除目的地", "Clear destination"))
                }
            }.padding(.horizontal, 16).frame(minHeight: 54).surface(Palette.paper, radius: Radius.control)
            if !demo.listening {
                Button(action: begin) { Label(text("开始导航", "Start navigation"), systemImage: "location.fill") }
                    .buttonStyle(SignButton()).accessibilityIdentifier("startDoorDemo")
            }
            Text(text("手机朝身体前方。识图描述现场，听一句，做一步，到门口结束。",
                      "Point the phone straight ahead. Visual guidance describes the view and guides one step at a time to a doorway."))
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 4)
            Text(demo.status).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("demoStatus")
            if demo.isVideoReplay {
                Text(demo.videoReplayNotice).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("demoVideoReplayNotice")
            }
        }
    }
    private func begin() { editing = false; demo.start() }
    @ViewBuilder private var facilityRows: some View {
        let items = [("电梯", "Lift", "arrow.up.arrow.down"), ("出口", "Exit", "door.left.hand.open"),
                     ("楼梯", "Stairs", "stairs"), ("厕所", "Restroom", "figure.stand.dress.line.vertical.figure")]
        ForEach(items.indices, id: \.self) { index in
            if index != 0 { Divider().padding(.leading, 54) }
            let item = items[index]
            targetRow(text(item.0, item.1), symbol: item.2, id: "demoFacility-\(index)")
        }
    }
    @ViewBuilder private var recentRows: some View {
        ForEach(Array(demo.history.enumerated()), id: \.element) { index, name in
            if index != 0 { Divider().padding(.leading, 54) }
            targetRow(name, symbol: "clock.arrow.circlepath", id: "demoRecent-\(index)")
        }
    }
    private func targetRow(_ name: String, symbol: String, id: String) -> some View {
        let selected = demo.destination == name
        return Button { demo.destination = name; editing = false } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(Palette.accent).accessibilityHidden(true)
                Text(verbatim: name).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Palette.accent).accessibilityHidden(true) }
            }.padding(.horizontal, 18).padding(.vertical, 11).frame(minHeight: 50).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier(id)
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(text("目的地", "Destination")).font(.subheadline).foregroundStyle(.secondary)
                Text(verbatim: demo.destination).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                Label(demo.arrived ? text("已到门口", "At the doorway") : (demo.paused ? text("已暂停", "Paused") : text("实时识图引导", "Live visual guidance")),
                      systemImage: demo.arrived ? "door.left.hand.open" : (demo.paused ? "pause.circle" : "viewfinder"))
                    .font(.title3.bold()).accessibilityAddTraits(.isHeader)
                if !demo.scene.isEmpty { Text(verbatim: demo.scene).font(.body).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("demoScene") }
                if !demo.instruction.isEmpty { Text(verbatim: demo.instruction).font(.title3.bold()).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("demoInstruction") }
                Text(demo.status).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("demoStatus")
                if !demo.sensorNote.isEmpty { Text(demo.sensorNote).font(.callout).accessibilityIdentifier("demoSensorNote") }
                if demo.isVideoReplay {
                    Text(demo.videoReplayNotice).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("demoVideoReplayNotice")
                }
                if let issue = demo.feedback.issue { Text(issue).font(.callout).foregroundStyle(.red) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).surface(Palette.paper, radius: Radius.panel)
            localMapCard
            if demo.running {
                let layout = type.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    Button { demo.repeatLast() } label: { Label(text("重听", "Repeat"), systemImage: "speaker.wave.2") }.buttonStyle(SignButton())
                    Button { demo.pauseOrResume() } label: {
                        Label(demo.paused ? text("继续", "Resume") : text("暂停", "Pause"), systemImage: demo.paused ? "play.fill" : "pause.fill")
                    }.buttonStyle(SignButton()).accessibilityIdentifier("pauseDoorDemo")
                }
                if demo.needsReview {
                    Button(text("已站稳，继续", "I’m standing still. Continue")) { demo.confirmStationary() }
                        .buttonStyle(SignButton(tone: .primary)).accessibilityIdentifier("demoStationary")
                } else if demo.needsFacing {
                    Button(text("手机已朝向身体前方", "Phone is pointing straight ahead")) { demo.confirmFacing() }
                        .buttonStyle(SignButton(tone: .primary)).accessibilityIdentifier("demoFacing")
                }
                if !demo.paused { camera }
                Button(text("我已到门口，结束", "I’m at the doorway. Finish")) { demo.finish() }
                    .buttonStyle(SignButton()).accessibilityIdentifier("finishDoorDemo")
                Button(text("结束导航", "End navigation")) { demo.returnHome() }.buttonStyle(SignButton())
            } else {
                Button(text("完成", "Done")) { demo.returnHome() }.buttonStyle(SignButton(tone: .primary))
            }
        }
    }

    private var hasLocalMap: Bool {
        demo.localMap.pose != nil || !demo.localMap.path.isEmpty || !demo.localMap.landmarks.isEmpty
    }

    private var localMapCard: some View {
        DisclosureGroup(isExpanded: $showMap) {
            VStack(alignment: .leading, spacing: 12) {
                if hasLocalMap {
                    DemoLocalMapCanvas(snapshot: demo.localMap, language: demo.language,
                                       live: demo.running && !demo.paused)
                        .frame(height: type.isAccessibilitySize ? 260 : 224)
                        .clipShape(G2Rectangle(16))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(text("局部地图俯视示意", "Local map, top-down view"))
                        .accessibilityValue(mapSummary)
                    Text(mapSummary).font(.caption).foregroundStyle(.secondary)
                    let bearingOnly = demo.localMap.landmarks.filter { $0.point == nil }.count
                    if bearingOnly > 0 {
                        Text(text("另有 \(bearingOnly) 个地标只有方向观测，未放入地图。",
                                  "\(bearingOnly) more landmarks have direction observations only and are not plotted."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(text("开始导航并移动观察后，这里会显示本次轨迹和已定位地标。",
                              "Your recorded path and positioned landmarks will appear here as you observe and move."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(text("局部示意，非完整楼层图。轨迹表示已记录的位置，不表示可通行路线。",
                          "A local sketch, not a complete floor plan. The path shows recorded positions, not a walkable route."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(text("近场扇区只示方向，不表示测量边界或通行许可。观测会自动过期，暂停或结束后隐藏，不代表永久安全区域。",
                          "Near-field sectors indicate direction, not measured boundaries or permission to walk. Observations expire, hide when paused or stopped, and do not mark permanently safe space."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if hasLocalMap {
                    if let url = demo.mapExportURL {
                        ShareLink(item: url) {
                            Label(text("分享地图 JSON", "Share map JSON"), systemImage: "square.and.arrow.up")
                        }.font(.callout.weight(.semibold)).accessibilityIdentifier("demoShareMap")
                        if demo.running && !demo.paused {
                            Button { demo.exportLocalMap() } label: {
                                Label(text("更新导出文件", "Refresh export"), systemImage: "arrow.clockwise")
                            }.font(.callout).accessibilityIdentifier("demoRefreshMap")
                        }
                    } else {
                        Button { demo.exportLocalMap() } label: {
                            Label(text("准备导出 JSON", "Prepare JSON export"), systemImage: "square.and.arrow.up")
                        }.font(.callout.weight(.semibold)).accessibilityIdentifier("demoExportMap")
                    }
                }
            }.padding(.top, 12)
        } label: {
            Label(text("局部地图", "Local map"), systemImage: "map")
                .font(.headline).foregroundStyle(.primary)
        }.padding(20).surface(Palette.paper, radius: Radius.panel)
            .accessibilityIdentifier("demoLocalMap")
    }

    private var mapSummary: String {
        let positioned = demo.localMap.landmarks.filter { $0.point != nil }.count
        return text("\(demo.localMap.path.count) 个轨迹点 · \(positioned) 个已定位地标 · 箭头为手机朝向",
                    "\(demo.localMap.path.count) path points · \(positioned) positioned landmarks · Arrow: phone heading")
    }

    @ViewBuilder private var camera: some View {
        switch demo.capture {
        case .ready:
            Group {
                #if DEBUG && targetEnvironment(simulator)
                if let preview = demo.preview { Image(uiImage: preview).resizable().aspectRatio(contentMode: .fit) }
                else { CameraPreview(camera: demo.camera) }
                #else
                CameraPreview(camera: demo.camera)
                #endif
            }.frame(height: type.isAccessibilitySize ? 148 : 192).frame(maxWidth: .infinity).clipped()
                .overlay { Image(systemName: "viewfinder").font(.system(size: 64, weight: .thin)).foregroundStyle(.white.opacity(0.8)).shadow(radius: 1) }
                .clipShape(G2Rectangle(Radius.panel)).accessibilityHidden(true)
        case .denied:
            Button(text("打开相机权限设置", "Open camera settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }.buttonStyle(SignButton())
        case .starting: ProgressView().frame(maxWidth: .infinity).accessibilityLabel(text("正在打开相机", "Opening the camera"))
        default: Text(demo.captureDescription).font(.callout)
        }
    }
    private var instructions: some View {
        NavigationStack {
            List {
                Section(text("开始导航", "Start navigation")) {
                    Text(text("说出或输入目的地，也可选择常用设施。本演示带你到可识别的门口。", "Say or enter a destination, or select a common destination. This demo guides you to a recognizable doorway."))
                }
                Section(text("听一句，做一步", "One instruction at a time")) {
                    Text(text("手机朝身体前方。识图引导会简短描述现场并给出下一步。只有听到前进一步才迈一小步，站稳后等下一次提示。", "Point the phone straight ahead. Visual guidance briefly describes the view and gives the next instruction. Take one small step only when prompted, then stand still and wait."))
                }
                Section(text("语言与语音", "Language and speech")) {
                    Text(text("首页可切换中文与 English。云端视觉直接生成描述和指令，手机实时朗读。", "Switch between 中文 and English on the home page. Cloud vision generates the descriptions and instructions in that language, and the phone speaks them in real time."))
                }
                Section(text("相机与隐私", "Camera and privacy")) {
                    Text(text("导航时，这台 iPhone 会将选中的现场画面和目的地发送给云端视觉服务。暂停、进入后台或结束导航会停止采集和发送。", "During navigation, this iPhone sends selected camera views and the destination to the cloud vision service. Pausing, backgrounding, or ending navigation stops capture and sending."))
                }
                Section(text("局部地图", "Local map")) {
                    Text(text("导航页可展开局部地图，查看本次轨迹、手机朝向和有坐标的地标，并分享 JSON。地图在本机生成，跟踪坐标重置时会清空。局部示意不包含完整楼层结构，近场观测也不能作为持续通行保证。",
                              "Expand Local map to see this session's path, phone heading, and positioned landmarks, or share its JSON. The map is built on this phone and clears when tracking coordinates reset. It is not a complete floor plan, and near-field observations do not guarantee continued passage."))
                }
            }.listStyle(.insetGrouped).navigationTitle(text("使用说明", "Instructions")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(text("完成", "Done")) { showInfo = false } } }
        }.presentationDragIndicator(.visible)
    }
}

private struct DemoLocalMapCanvas: View {
    let snapshot: LocalMapSnapshot
    let language: GuidanceLanguage
    let live: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let uptime = ProcessInfo.processInfo.systemUptime
            Canvas { context, size in
                var drawing = context
                draw(context: &drawing, size: size, now: uptime)
            }
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
        }
    }

    private func draw(context: inout GraphicsContext, size: CGSize, now: Double) {
        let positioned = snapshot.landmarks.filter { $0.point.map(Self.finite) == true }
        var points = snapshot.path.map(\.position).filter(Self.finite) + positioned.compactMap(\.point)
        if let position = snapshot.pose?.position, Self.finite(position) { points.append(position) }
        let projection = Projection(points: points, size: size)
        drawGrid(context: &context, projection: projection, size: size)

        if live, let observed = snapshot.sectorPose, let expiry = snapshot.sectorExpiresAt,
           now >= observed.time, now <= expiry, now - observed.time <= 0.65, Self.finite(observed.position) {
            for sector in snapshot.sectors {
                let radius = min(2.4, max(0.18, sector.nearest ?? 1.2))
                var wedge = Path()
                wedge.move(to: projection.point(observed.position))
                for index in 0...8 {
                    let degrees = observed.heading + Double(sector.angle) - 7.5 + Double(index) * 15 / 8
                    let angle = degrees * .pi / 180
                    let edge = V3(observed.position.x + sin(angle) * radius, observed.position.y,
                                  observed.position.z - cos(angle) * radius)
                    wedge.addLine(to: projection.point(edge))
                }
                wedge.closeSubpath()
                let color: Color = sector.state == .occupied ? .orange : (sector.state == .free ? .teal : .gray)
                context.fill(wedge, with: .color(color.opacity(sector.state == .occupied ? 0.22 : 0.09)))
                context.stroke(wedge, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }

        var route = Path()
        var started = false
        for sample in snapshot.path where Self.finite(sample.position) {
            if started { route.addLine(to: projection.point(sample.position)) }
            else { route.move(to: projection.point(sample.position)); started = true }
        }
        context.stroke(route, with: .color(Palette.accent.opacity(0.7)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        if let first = snapshot.path.first, Self.finite(first.position) {
            let p = projection.point(first.position)
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.secondary), lineWidth: 1.5)
        }
        for (index, landmark) in positioned.enumerated() {
            guard let position = landmark.point else { continue }
            let p = projection.point(position)
            let diamond = Path { path in
                path.move(to: CGPoint(x: p.x, y: p.y - 5)); path.addLine(to: CGPoint(x: p.x + 5, y: p.y))
                path.addLine(to: CGPoint(x: p.x, y: p.y + 5)); path.addLine(to: CGPoint(x: p.x - 5, y: p.y)); path.closeSubpath()
            }
            context.fill(diamond, with: .color(.purple))
            if index < 8 {
                let label = "\(landmark.id) " + (landmark.label ?? landmarkName(landmark.kind))
                context.draw(Text(verbatim: label).font(.system(size: 10, weight: .medium)).foregroundStyle(.primary),
                             at: CGPoint(x: min(size.width - 8, max(8, p.x + 8)), y: max(16, p.y - 9)), anchor: .leading)
            }
        }
        if let pose = snapshot.pose, Self.finite(pose.position), pose.heading.isFinite {
            let p = projection.point(pose.position), angle = pose.heading * .pi / 180
            let forward = CGPoint(x: sin(angle), y: -cos(angle))
            let right = CGPoint(x: cos(angle), y: sin(angle))
            let arrow = Path { path in
                path.move(to: CGPoint(x: p.x + forward.x * 15, y: p.y + forward.y * 15))
                path.addLine(to: CGPoint(x: p.x - forward.x * 6 + right.x * 7, y: p.y - forward.y * 6 + right.y * 7))
                path.addLine(to: CGPoint(x: p.x - forward.x * 3, y: p.y - forward.y * 3))
                path.addLine(to: CGPoint(x: p.x - forward.x * 6 - right.x * 7, y: p.y - forward.y * 6 - right.y * 7)); path.closeSubpath()
            }
            context.fill(arrow, with: .color(Palette.accent))
            context.stroke(arrow, with: .color(Color(uiColor: .systemBackground)), lineWidth: 1.5)
        }
        let legend = language.text("蓝线：轨迹  ◆：地标", "Blue: path  ◆: landmarks")
        context.draw(Text(legend).font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: 12, y: 12), anchor: .topLeading)
        let scaleLength = projection.scale > 45 ? 1.0 : (projection.scale > 18 ? 2.0 : 5.0)
        let y = size.height - 17, x: CGFloat = 14, length = scaleLength * projection.scale
        let bar = Path { path in
            path.move(to: CGPoint(x: x, y: y - 3)); path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + length, y: y)); path.addLine(to: CGPoint(x: x + length, y: y - 3))
        }
        context.stroke(bar, with: .color(.secondary), lineWidth: 1)
        context.draw(Text("\(Int(scaleLength)) m").font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: x + length + 6, y: y), anchor: .leading)
    }

    private func drawGrid(context: inout GraphicsContext, projection: Projection, size: CGSize) {
        let spacing = max(20, projection.scale)
        var grid = Path()
        for x in stride(from: CGFloat(0), through: size.width, by: spacing) {
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in stride(from: CGFloat(0), through: size.height, by: spacing) {
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.10)), lineWidth: 0.5)
    }

    private func landmarkName(_ kind: FeatureKind) -> String {
        switch kind {
        case .door: return language.text("门口", "Doorway")
        case .aisle_entrance: return language.text("通道入口", "Passage")
        case .sign: return language.text("标牌", "Sign")
        case .junction: return language.text("路口", "Junction")
        case .chair: return language.text("椅子", "Chair")
        case .stool: return language.text("凳子", "Stool")
        case .person: return language.text("行人", "Person")
        case .steps: return language.text("台阶", "Steps")
        case .obstacle: return language.text("障碍", "Obstacle")
        }
    }

    private static func finite(_ point: V3) -> Bool { point.x.isFinite && point.z.isFinite }

    private struct Projection {
        let centerX: Double, centerZ: Double, scale: CGFloat, size: CGSize
        init(points: [V3], size: CGSize) {
            let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
            let minZ = points.map(\.z).min() ?? 0, maxZ = points.map(\.z).max() ?? 0
            centerX = (minX + maxX) / 2; centerZ = (minZ + maxZ) / 2; self.size = size
            scale = min((size.width - 50) / max(4, maxX - minX + 1), (size.height - 54) / max(4, maxZ - minZ + 1))
        }
        func point(_ position: V3) -> CGPoint {
            CGPoint(x: size.width / 2 + (position.x - centerX) * scale,
                    y: size.height / 2 + (position.z - centerZ) * scale)
        }
    }
}
