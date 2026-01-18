import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @StateObject private var exportEngine = VideoExportEngine()
    @State private var tripData: TripData?
    @State private var previewTime: Double = 0
    @State private var showFileImporter = false
    
    @State private var interpolator: DataInterpolator?
    @State private var isPlaying = false
    @State private var playbackTimer: Timer?
    @State private var playbackSpeed: Double = 1.0
    
    // 用于精确回放的基准变量
    @State private var playbackStartWallTime: Date?
    @State private var playbackStartPreviewTime: Double = 0
    
    // 布局参数
    @State private var contentX: CGFloat = 0
    @State private var chartWidth: CGFloat = 560
    @State private var contentY: CGFloat = 0
    @State private var showSettings = false
    @State private var showEvents = true
    @State private var exportQuality: ExportQuality = .high
    
    // 片段导出
    @State private var showSegmentPanel = false
    @State private var segmentStartStr: String = "00:00"
    @State private var segmentEndStr: String = "00:30"
    
    var body: some View {
        VStack(spacing: 0) {
            if let trip = tripData {
                renderPlayer(trip)
            } else {
                renderDropZone()
            }
        }
        .frame(width: 600, height: 540) 
        .background(VisualEffectView(material: .underWindowBackground).ignoresSafeArea())
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { self.readJson(from: url) }
        }
    }
    
    @ViewBuilder
    func renderPlayer(_ trip: TripData) -> some View {
        let startTime = trip.trajectory.first?.ts ?? 0
        let endTime = trip.trajectory.last?.ts ?? 0
        
        VStack(spacing: 0) {
            // 1. 顶部栏
            HStack(spacing: 15) {
                if let logo = trip.metadata.brandLogoName {
                    Image(logo)
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .padding(6)
                        .background(Color.primary.opacity(0.1))
                        .cornerRadius(8)
                        .foregroundColor(.primary)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(trip.metadata.carModel)
                        .font(.system(size: 16, weight: .bold))
                    Text(formatDateSimple(trip.metadata.startTime))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                Button(action: { withAnimation { showSettings.toggle() } }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .medium))
                }.buttonStyle(.plain).foregroundColor(.secondary)
                
                Button(action: { stopPlayback(); tripData = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                }.buttonStyle(.plain).foregroundColor(.secondary)
            }
            .padding(.horizontal, 15)
            .frame(height: 50)
            
            // 2. 视频预览区
            ZStack {
                if exportEngine.isExporting {
                    Color.black.overlay(
                        VStack(spacing: 15) {
                            ProgressView(value: exportEngine.progress, total: 1.0)
                                .progressViewStyle(.linear)
                                .frame(width: 200)
                                .tint(.blue)
                            
                            VStack(spacing: 6) {
                                Text("正在编码透明视频...")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                
                                HStack(spacing: 12) {
                                    Text("\(Int(exportEngine.progress * 100))%")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    
                                    if !exportEngine.estimatedTimeRemaining.isEmpty {
                                        Text("预计剩余: \(exportEngine.estimatedTimeRemaining)")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                }
                                .foregroundColor(.secondary)
                            }
                        }
                    )
                } else {
                    let currentState = interpolator?.state(at: previewTime)
                    ExportFrameView(
                        state: currentState,
                        tripData: trip,
                        interpolator: interpolator,
                        currentTime: previewTime,
                        layout: LayoutConfig(speedX: contentX, gX: 0, cW: chartWidth, cY: contentY),
                        showEvents: showEvents
                    )
                    .background(Color.black)
                }
                
                if showSettings && !exportEngine.isExporting {
                    renderSettingsSidebar()
                        .transition(.opacity)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(y: 45)
                }
            }
            .frame(width: 600, height: 400)
            
            // 3. 底部控制区
            VStack(spacing: 12) {
                Slider(value: $previewTime, in: startTime...endTime, onEditingChanged: { d in if d { stopPlayback() } })
                    .tint(.blue)
                    .controlSize(.small)
                    .padding(.horizontal, 15)
                    .padding(.top, 12)
                
                HStack(spacing: 20) {
                    Button(action: togglePlayback) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 38))
                            .foregroundColor(.blue)
                    }.buttonStyle(.plain)
                    
                    Picker("", selection: $playbackSpeed) {
                        Text("1x").tag(1.0); Text("2x").tag(2.0); Text("5x").tag(5.0)
                    }.pickerStyle(.segmented).frame(width: 110).controlSize(.small)
                    
                    Spacer()
                    
                    Text("\(formatDuration(previewTime - startTime)) / \(formatDuration(endTime - startTime))")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        Button(action: { 
                            segmentStartStr = formatDuration(previewTime - startTime)
                            segmentEndStr = formatDuration(min(previewTime - startTime + 30, endTime - startTime))
                            showSegmentPanel.toggle() 
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "scissors")
                                Text("片段")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 75, height: 36)
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(.primary)
                            .cornerRadius(8)
                        }.buttonStyle(.plain)
                        .popover(isPresented: $showSegmentPanel, arrowEdge: .top) {
                            renderSegmentInput(startTime: startTime, endTime: endTime, trip: trip)
                        }

                        Button(action: { Task { await startExport(trip) } }) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up.fill")
                                Text("导出")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 85, height: 36)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.bottom, 12)
            }
            .frame(height: 90)
        }
    }
    
    private func formatDateSimple(_ isoString: String) -> String {
        let parts = isoString.split(separator: "T")
        return parts.count > 1 ? "\(parts[0]) \(String(parts[1].prefix(8)))" : isoString
    }
    
    @ViewBuilder
    private func renderSettingsSidebar() -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("图表设置").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
            
            Toggle("显示负体验事件", isOn: $showEvents)
                .font(.system(size: 13, weight: .medium))
                .toggleStyle(.switch)
                .controlSize(.small)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("导出视频质量").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                Picker("", selection: $exportQuality) {
                    ForEach(ExportQuality.allCases) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
        }
        .padding(15)
        .frame(width: 200)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.2), radius: 15, x: 0, y: 10)
    }
    
    @ViewBuilder
    private func renderSegmentInput(startTime: Double, endTime: Double, trip: TripData) -> some View {
        VStack(spacing: 18) {
            Text("导出片段设置")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.secondary)
            
            VStack(spacing: 12) {
                timeInputRow(label: "开始时间", value: $segmentStartStr)
                timeInputRow(label: "结束时间", value: $segmentEndStr)
            }
            
            Text("格式说明：MM:SS (例如 01:20)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            
            Button(action: {
                showSegmentPanel = false
                Task {
                    let s = parseDuration(segmentStartStr)
                    let e = parseDuration(segmentEndStr)
                    let realRange = (startTime + s)...(startTime + e)
                    await startExport(trip, range: realRange)
                }
            }) {
                Text("开始导出片段")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }.buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 240)
        .background(.ultraThinMaterial)
    }
    
    private func timeInputRow(label: String, value: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Spacer()
            TextField("00:00", text: value)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
                .padding(6)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(6)
        }
    }
    
    private func parseDuration(_ str: String) -> Double {
        let parts = str.split(separator: ":").map { String($0) }
        if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) {
            return m * 60 + s
        }
        return Double(str) ?? 0
    }
    
    @ViewBuilder
    func renderDropZone() -> some View {
        Button(action: { showFileImporter = true }) {
            VStack(spacing: 15) {
                Image(systemName: "plus.circle.fill").font(.system(size: 40)).foregroundStyle(.blue)
                Text("点击导入数据").font(.system(size: 15, weight: .medium))
            }
        }.buttonStyle(.plain).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    func togglePlayback() {
        if isPlaying { stopPlayback() }
        else {
            isPlaying = true
            playbackStartWallTime = Date()
            playbackStartPreviewTime = previewTime
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { _ in
                DispatchQueue.main.async {
                    guard let trip = self.tripData, let startTime = self.playbackStartWallTime else { return }
                    let endTime = trip.trajectory.last?.ts ?? 0
                    let elapsedWallTime = Date().timeIntervalSince(startTime)
                    let newTime = self.playbackStartPreviewTime + elapsedWallTime * self.playbackSpeed
                    if newTime < endTime { self.previewTime = newTime }
                    else { self.previewTime = endTime; self.stopPlayback() }
                }
            }
        }
    }
    
    func stopPlayback() { isPlaying = false; playbackTimer?.invalidate(); playbackTimer = nil; playbackStartWallTime = nil }
    
    func formatDuration(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let mins = Int(s) / 60; let secs = Int(s) % 60; return String(format: "%02d:%02d", mins, secs)
    }
    
    private func readJson(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let trip = try JSONDecoder().decode(TripData.self, from: data)
            DispatchQueue.main.async {
                self.tripData = trip
                self.interpolator = DataInterpolator(points: trip.trajectory)
                self.previewTime = trip.trajectory.first?.ts ?? 0
            }
        } catch { print("解析错误: \(error)") }
    }
    
    private func startExport(_ trip: TripData, range: ClosedRange<Double>? = nil) async {
        stopPlayback()
        let savePanel = NSSavePanel(); savePanel.allowedContentTypes = [.quickTimeMovie]; savePanel.nameFieldStringValue = range == nil ? "Puked_Full.mov" : "Puked_Segment.mov"
        if await savePanel.begin() == .OK, let url = savePanel.url {
            let config = LayoutConfig(speedX: contentX, gX: 0, cW: chartWidth, cY: contentY)
            _ = await exportEngine.export(trip: trip, outputURL: url, layout: config, showEvents: showEvents, quality: exportQuality, range: range)
        }
    }
}

struct ExportFrameView: View {
    let state: InterpolatedState?; let tripData: TripData?; let interpolator: DataInterpolator?; let currentTime: Double; let layout: LayoutConfig; let showEvents: Bool
    
    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                HStack(spacing: 25) {
                    HStack(spacing: 8) {
                        Image(systemName: "speedometer").font(.system(size: 22)).foregroundColor(.blue)
                        HStack(alignment: .lastTextBaseline, spacing: 3) {
                            Text(String(format: "%.1f", state?.speedKmh ?? 0))
                                .font(.system(size: 22, weight: .regular, design: .monospaced))
                            Text("KM/H").font(.system(size: 9, weight: .bold)).foregroundColor(.gray)
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "clock").font(.system(size: 16)).foregroundColor(.gray)
                        HStack(alignment: .lastTextBaseline, spacing: 0) {
                            Text(formatMainTime(currentTime)).font(.system(size: 16, weight: .regular, design: .monospaced))
                            Text(formatSubTime(currentTime)).font(.system(size: 16, weight: .thin, design: .monospaced)).foregroundColor(.gray)
                        }
                    }
                }
                Spacer()
                HStack(spacing: 25) {
                    accelItem(label: "X轴加速度", value: state?.gForceLongitudinal ?? 0, color: Color(red: 0.2, green: 0.9, blue: 0.4))
                    accelItem(label: "Y轴加速度", value: state?.gForceLateral ?? 0, color: Color(red: 1.0, green: 0.3, blue: 0.3))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.white.opacity(0.08))
            .cornerRadius(12)
            .frame(width: layout.cW)
            .foregroundColor(.white)
            
            WaveformChartView(trip: tripData, interpolator: interpolator, currentTime: currentTime, showEvents: showEvents)
                .frame(width: layout.cW)
            
            HStack(spacing: 20) {
                HStack(spacing: 4) { Circle().fill(Color(red: 0.2, green: 0.9, blue: 0.4)).frame(width: 4); Text("X-ACCEL").font(.system(size: 8, weight: .bold)) }
                HStack(spacing: 4) { Circle().fill(Color(red: 1.0, green: 0.3, blue: 0.3)).frame(width: 4); Text("Y-ACCEL").font(.system(size: 8, weight: .bold)) }
            }.foregroundColor(.gray).padding(.bottom, 10)
        }
        .offset(x: layout.speedX, y: layout.cY)
        .frame(width: 600, height: 400)
    }
    
    private func accelItem(label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(color.opacity(0.8))
            Text(String(format: "%.2f G", value)).font(.system(size: 16, weight: .regular, design: .monospaced)).foregroundColor(color)
        }
    }
    
    private func formatMainTime(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts); let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
    }
    private func formatSubTime(_ ts: Double) -> String {
        let ms = Int((ts.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: ".%03d", ms)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = material; view.state = .active; return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
