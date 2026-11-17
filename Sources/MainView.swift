import SwiftUI
import PhotosUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ReplayKit

enum AppVersion {
    static var short: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
    static var display: String { "v\(short) (\(build))" }
}

struct MainView: View {
    @StateObject private var engine = CastEngine()
    @Environment(\.colorScheme) private var scheme

    // 设置持久化：下次打开不用重填
    @AppStorage("nbc.host") private var host = ""
    @AppStorage("nbc.preset") private var presetIndex = 0
    @AppStorage("nbc.quality") private var qualityIndex = 2   // 0 流畅 1 均衡 2 清晰 3 极致
    @AppStorage("nbc.dupKey") private var duplicateKeyframes = false
    @AppStorage("nbc.chunk1400") private var chunk1400 = true
    @State private var gopIndex = 25            // 关键帧间隔（帧）
    @State private var fpsIndex = 20
    @State private var bitrateIndex = 1200      // kbps
    @State private var resolutionIndex = 0      // 0 预设 / 2 一半
    @State private var pingOnly = false
    @State private var showTools = false
    @State private var showAdvanced = false
    @State private var showDiag = false
    @State private var scanning = false
    @State private var tcpScanning = false
    @State private var probing = false
    @State private var scanSummary = ""
    @State private var diagText = Diag.tail(16)
    @State private var localIP = "-"

    // 图片：先选进 pending，预览确认后才生效
    @State private var pickedItem: PhotosPickerItem?
    @State private var pendingImage: UIImage?
    @State private var confirmedImage: UIImage?
    @State private var imageConfirmed = false
    @State private var showImagePreview = false

    // 视频：同样确认制
    @State private var pickedVideoItem: PhotosPickerItem?
    @State private var pendingVideoURL: URL?
    @State private var confirmedVideoURL: URL?
    @State private var videoConfirmed = false

    @State private var sourceIndex = 0         // 0 测试图 1 图片 2 视频 3 摄像头
    @State private var rotationIndex = 0       // 图片/视频/测试图 的方向
    @State private var cameraRotationIndex = 1  // 摄像头默认 90°（竖装/横装常态）
    @State private var cameraPositionIndex = 0 // 0 后置 1 前置

    private static let previewContext = CIContext(options: nil)
    private let accent = Color(red: 0.29, green: 0.47, blue: 0.98)
    private let accent2 = Color(red: 0.55, green: 0.36, blue: 0.96)

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    header
                    connectionCard
                    sourceCard
                    mirrorCard
                    metricsCard
                    diagCard
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 132)
            }
        }
        .overlay(alignment: .bottom) { actionBar }
        .sheet(isPresented: $showImagePreview) { imagePreviewSheet }
        .sheet(isPresented: $showTools) { toolsSheet }
        .onAppear {
            localIP = LanScanner.localIPv4() ?? "未连 Wi-Fi"
            if host.isEmpty { host = LanScanner.gatewayGuess() ?? "" }
            applyQuality(qualityIndex)
            diagText = Diag.tail(16)
            Diag.log("MainView 出现，版本 \(AppVersion.display)，IP=\(host.isEmpty ? "未填" : host)")
        }
        .onChange(of: pickedItem) { item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                await MainActor.run {
                    pendingImage = image
                    imageConfirmed = false
                }
            }
        }
        .onChange(of: pickedVideoItem) { item in
            guard let item else { return }
            // matching is nil (see photoFlow/videoFlow): reject non-video picks here.
            if let first = item.supportedContentTypes.first,
               !first.conforms(to: .movie), !first.conforms(to: .video) {
                Task { await MainActor.run { scanSummary = "请选择视频文件" } }
                return
            }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cast-video-\(UUID().uuidString).mp4")
                do {
                    try data.write(to: url)
                } catch {
                    await MainActor.run { scanSummary = "视频保存失败：\(error.localizedDescription)" }
                    return
                }
                await MainActor.run {
                    pendingVideoURL = url
                    videoConfirmed = false
                }
            }
        }
        .onChange(of: sourceIndex) { _ in applySource() }
        .onChange(of: rotationIndex) { _ in applySource() }
        .onChange(of: cameraPositionIndex) { _ in
            if sourceIndex == 3 { applySource() }
        }
    }

    // MARK: - 背景
    private var backgroundGradient: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.06, green: 0.07, blue: 0.10), Color(red: 0.10, green: 0.11, blue: 0.16)]
                : [Color(red: 0.96, green: 0.97, blue: 1.0), Color(red: 0.93, green: 0.94, blue: 0.98)],
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: - 顶部
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ninebot Cast")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.isRunning ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(engine.statusText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text("v\(AppVersion.short)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: - 卡片容器
    private func card<Content: View>(_ title: String,
                                     icon: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accent)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.055) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(scheme == .dark ? 0.07 : 0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.04), radius: 10, y: 4)
    }

    private func fieldBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selected ? accent.opacity(0.12) : Color.primary.opacity(0.045))
    }

    // MARK: - 连接
    private var connectionCard: some View {
        card("仪表连接", icon: "antenna.radiowaves.left.and.right") {
            HStack {
                Text("预设").foregroundColor(.secondary)
                Spacer()
                Picker("", selection: $presetIndex) {
                    ForEach(Array(DashboardPreset.all.enumerated()), id: \.element.id) { index, preset in
                        Text(preset.title).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .font(.subheadline)

            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("仪表 IP", text: $host)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .font(.body.monospacedDigit())
                Button {
                    fillGateway()
                } label: {
                    Text("用网关")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(accent.opacity(0.12)))
                        .foregroundColor(accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(fieldBackground(false))

            HStack {
                Text("本机 \(localIP)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    showTools = true
                } label: {
                    HStack(spacing: 4) {
                        Text("找不到 IP？")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundColor(accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 画面来源
    private var sourceCard: some View {
        card("画面来源", icon: "rectangle.on.rectangle") {
            HStack(spacing: 8) {
                sourceTile(0, "测试图", "chart.bar.doc.horizontal")
                sourceTile(1, "图片", "photo")
                sourceTile(2, "视频", "video")
                sourceTile(3, "摄像头", "camera")
            }

            rotationPicker

            if sourceIndex == 1 {
                photoFlow
            } else if sourceIndex == 2 {
                videoFlow
            } else if sourceIndex == 3 {
                cameraFlow
            } else {
                Text("彩条 + 移动方块，用来快速验证链路是否通。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func sourceTile(_ index: Int, _ title: String, _ icon: String) -> some View {
        Button {
            sourceIndex = index
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundColor(sourceIndex == index ? accent : Color.secondary)
            .background(fieldBackground(sourceIndex == index))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(sourceIndex == index ? accent.opacity(0.55) : Color.clear, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }

    private var rotationPicker: some View {
        HStack(spacing: 8) {
            Text("方向")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Button {
                        setRotation(step: i)
                    } label: {
                        Text(["0°", "90°", "180°", "270°"][i])
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .frame(width: 46, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(currentRotationStep == i ? accent : Color.clear)
                            )
                            .foregroundColor(currentRotationStep == i ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045)))
        }
    }

    /// 摄像头与其它来源各自记住自己的方向
    private var currentRotationStep: Int {
        sourceIndex == 3 ? cameraRotationIndex : rotationIndex
    }

    private var currentRotationDegrees: Int {
        [0, 90, 180, 270][currentRotationStep]
    }

    private func setRotation(step: Int) {
        if sourceIndex == 3 {
            cameraRotationIndex = step
        } else {
            rotationIndex = step
        }
        applySource()
    }

    // 图片流程：选 → 预览 → 确认 → 才真正投
    private var photoFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhotosPicker(selection: $pickedItem, matching: nil) {
                Label(confirmedImage == nil ? "选择图片" : "换一张图片",
                      systemImage: "photo.on.rectangle.angled")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(fieldBackground(false))
            }
            .buttonStyle(.plain)

            if let pendingImage, !imageConfirmed {
                Button {
                    showImagePreview = true
                } label: {
                    previewImageView(pendingImage)
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Text("点开预览")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(9)
                        }
                }
                .buttonStyle(.plain)

                Button {
                    confirmedImage = pendingImage
                    imageConfirmed = true
                    applySource()
                } label: {
                    Label("确认投这张图", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accent))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            } else if let confirmedImage, imageConfirmed {
                HStack(spacing: 12) {
                    previewImageView(confirmedImage)
                        .frame(width: 92, height: 60)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已确认 · 铺满 \(DashboardPreset.all[presetIndex].width)×\(DashboardPreset.all[presetIndex].height)")
                            .font(.caption.weight(.medium))
                        Text("超出部分裁掉，换方向自动重排")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    // 视频流程：选 → 确认 → 才真正投
    private var videoFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhotosPicker(selection: $pickedVideoItem, matching: nil) {
                Label(confirmedVideoURL == nil ? "选择视频" : "换一个视频",
                      systemImage: "video.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(fieldBackground(false))
            }
            .buttonStyle(.plain)

            if let pendingVideoURL, !videoConfirmed {
                Text(pendingVideoURL.lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Button {
                    confirmedVideoURL = pendingVideoURL
                    videoConfirmed = true
                    applySource()
                } label: {
                    Label("确认投这段视频", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accent))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            } else if let confirmedVideoURL, videoConfirmed {
                Text("已确认 · \(confirmedVideoURL.lastPathComponent)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text("原速循环播放，独立线程解码，不占发送节拍。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var cameraFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 2) {
                cameraTile(0, "后置", "camera")
                cameraTile(1, "前置", "camera.rotate")
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.045)))

            Text("首次使用会请求相机权限。退后台后摄像头会停采集（iOS 限制），画面停在最后一帧但流不断。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func cameraTile(_ index: Int, _ title: String, _ icon: String) -> some View {
        Button {
            cameraPositionIndex = index
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(cameraPositionIndex == index ? Color.primary.opacity(0.08) : Color.clear)
            )
            .foregroundColor(cameraPositionIndex == index ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 屏幕镜像（录屏广播扩展）
    private var mirrorCard: some View {
        card("屏幕镜像", icon: "rectangle.on.rectangle") {
            Text("把整块手机屏幕实时投到仪表：抖音、地图、视频都能投。只传画面，没有声音。")
                .font(.footnote)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                BroadcastPickerButton()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("点左边按钮 → 选 NinebotCast → 开始直播")
                        .font(.subheadline.weight(.semibold))
                    Text("停止：控制中心长按屏幕录制 → 停止，或回 App 再点一次按钮。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Text("开始前：仪表先进投屏接收态，强退九号出行（它占着 5012/5013 端口），并先停掉上面的普通投屏；先用测试图成功投一次，让系统弹过局域网权限。横屏铺满整个仪表（左右各裁掉一点）；竖屏画面在横屏仪表上是中间一条竖条，两边黑边。只支持五寸 H.264 模式。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 指标
    private var metricsCard: some View {
        card("运行状态", icon: "waveform.path.ecg") {
            HStack(spacing: 0) {
                metric(String(engine.sentFrames), "帧已发送")
                divider
                metric(String(engine.sentPackets), "包已发送")
                divider
                metric(engine.rtcpPongCount > 0 ? "\(max(0, engine.lastRTTMs))" : "—",
                       "往返 ms",
                       highlight: engine.rtcpPongCount > 0)
            }
            if engine.isRunning {
                HStack(spacing: 0) {
                    metric("\(engine.measuredFps)", "实测 fps")
                    divider
                    metric("\(engine.avgFrameKB)", "帧均 KB")
                    divider
                    metric("\(engine.backlogPackets)", "待发积压",
                           warn: engine.backlogPackets > 120)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: engine.rtcpPongCount > 0 ? "checkmark.circle.fill" : "clock")
                    .font(.system(size: 12))
                Text(engine.rtcpPongCount > 0
                     ? (engine.droppedFrames > 0
                        ? "仪表在线 · 已回应 \(engine.rtcpPongCount) 次心跳 · 主动丢 \(engine.droppedFrames) 帧"
                        : "仪表在线，已回应 \(engine.rtcpPongCount) 次心跳")
                     : "等仪表回应心跳（2 秒以上）")
                    .font(.caption)
            }
            .foregroundColor(engine.rtcpPongCount > 0 ? .green : .secondary)

            if !engine.dashboardReport.isEmpty {
                Text(engine.dashboardReport)
                    .font(.caption)
                    .foregroundColor(accent)
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("画质", selection: $qualityIndex) {
                        Text("流畅").tag(0)
                        Text("均衡").tag(1)
                        Text("清晰").tag(2)
                        Text("极致").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: qualityIndex) { value in
                        applyQuality(value)
                    }
                    Text("画质一键设好帧率和码率；下面还能单项微调")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    HStack {
                        Text("帧率").font(.subheadline)
                        Spacer()
                        Picker("", selection: $fpsIndex) {
                            Text("跟随预设").tag(0)
                            Text("10").tag(10)
                            Text("15").tag(15)
                            Text("20").tag(20)
                            Text("25").tag(25)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    HStack {
                        Text("码率").font(.subheadline)
                        Spacer()
                        Picker("", selection: $bitrateIndex) {
                            Text("跟随预设").tag(0)
                            Text("400k").tag(400)
                            Text("600k").tag(600)
                            Text("800k").tag(800)
                            Text("1.2M").tag(1200)
                            Text("2M").tag(2000)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    HStack {
                        Text("关键帧间隔").font(.subheadline)
                        Spacer()
                        Picker("", selection: $gopIndex) {
                            Text("10 帧").tag(10)
                            Text("25 帧").tag(25)
                            Text("50 帧").tag(50)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    HStack {
                        Text("分辨率").font(.subheadline)
                        Spacer()
                        Picker("", selection: $resolutionIndex) {
                            Text("跟随预设").tag(0)
                            Text("一半（更省解码）").tag(2)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    Toggle("关键帧重发（更稳但更占带宽）", isOn: $duplicateKeyframes)
                        .font(.subheadline)
                    Toggle("分片 1400 字节", isOn: $chunk1400)
                        .font(.subheadline)
                    Toggle("只发 ping（排查用）", isOn: $pingOnly)
                        .font(.subheadline)
                }
                .padding(.top, 8)
            } label: {
                Text("发送参数 · \(fpsLabel) / \(bitrateLabel)")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func metric(_ value: String, _ label: String,
                        highlight: Bool = false, warn: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(warn ? Color.orange : (highlight ? Color.green : Color.primary))
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(width: 1, height: 26)
    }

    private var fpsLabel: String { fpsIndex == 0 ? "预设帧率" : "\(fpsIndex)fps" }
    private var bitrateLabel: String { bitrateIndex == 0 ? "预设码率" : "\(bitrateIndex)kbps" }

    /// 画质档位 = 帧率 + 码率 + GOP 的组合，一键设定
    private func applyQuality(_ value: Int) {
        switch value {
        case 0: fpsIndex = 10; bitrateIndex = 400; gopIndex = 10
        case 1: fpsIndex = 15; bitrateIndex = 800; gopIndex = 25
        case 2: fpsIndex = 20; bitrateIndex = 1200; gopIndex = 25
        default: fpsIndex = 25; bitrateIndex = 2000; gopIndex = 10
        }
    }

    // MARK: - 诊断
    private var diagCard: some View {
        card("诊断", icon: "stethoscope") {
            DisclosureGroup(isExpanded: $showDiag) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(diagText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 14) {
                        Button("刷新") { diagText = Diag.tail(20) }
                        Button("复制") {
                            UIPasteboard.general.string = Diag.tail(60)
                        }
                        Spacer()
                        Button("清空") {
                            Diag.reset()
                            diagText = Diag.tail(4)
                        }
                        .foregroundColor(.red)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundColor(accent)
                }
                .padding(.top, 8)
            } label: {
                Text("展开日志（出问题把这段发我）")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var footer: some View {
        Text("UDP 5012 视频 · 5013 心跳 · 协议对齐官方 APK")
            .font(.caption2)
            .foregroundColor(.secondary.opacity(0.8))
            .padding(.top, 4)
    }

    // MARK: - 底部主按钮
    private var actionBar: some View {
        VStack(spacing: 10) {
            Button {
                if engine.isRunning {
                    engine.stop()
                } else {
                    engine.start(preset: DashboardPreset.all[presetIndex],
                                 host: host,
                                 duplicateKeyframes: duplicateKeyframes,
                                 packetSize: chunk1400 ? 1400 : 1380,
                                 gop: gopIndex,
                                 pingOnly: pingOnly,
                                 fpsOverride: fpsIndex,
                                 bitrateOverride: UInt32(max(0, bitrateIndex) * 1000),
                                 resolutionDivisor: resolutionIndex == 0 ? 1 : 2)
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text(engine.isRunning ? "停止投屏" : (pingOnly ? "开始（仅 ping）" : "开始投屏"))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(
                    Capsule(style: .continuous)
                        .fill(engine.isRunning
                              ? AnyShapeStyle(Color.red.gradient)
                              : AnyShapeStyle(LinearGradient(colors: [accent, accent2],
                                                             startPoint: .topLeading,
                                                             endPoint: .bottomTrailing)))
                )
                .foregroundColor(.white)
                .shadow(color: (engine.isRunning ? Color.red : accent).opacity(0.32),
                        radius: 14, y: 7)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [
                (scheme == .dark ? Color.black : Color.white).opacity(0.0),
                (scheme == .dark ? Color(red: 0.06, green: 0.07, blue: 0.10) : Color.white).opacity(0.95)
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - 图片预览 sheet
    private var imagePreviewSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let pendingImage {
                    previewImageView(pendingImage)
                        .frame(maxHeight: 340)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal)
                    Text("仪表上实际显示的样子（已按 \(rotationLabel) 铺满 \(DashboardPreset.all[presetIndex].width)×\(DashboardPreset.all[presetIndex].height)，超出部分裁掉）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Spacer()
                    Button {
                        confirmedImage = pendingImage
                        imageConfirmed = true
                        applySource()
                        showImagePreview = false
                    } label: {
                        Label("确认投这张图", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Capsule().fill(LinearGradient(colors: [accent, accent2],
                                                                     startPoint: .topLeading,
                                                                     endPoint: .bottomTrailing)))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("图片预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showImagePreview = false }
                }
            }
        }
    }

    private var rotationLabel: String { ["0°", "90°", "180°", "270°"][currentRotationStep] }

    // MARK: - 找 IP 工具 sheet
    private var toolsSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("仪表必须已由九号自己的巡航逻辑进入投屏接收态（官方 App 车辆页 → 仪表投屏导航 → 投屏导航，等仪表出地图）。然后从后台强退九号出行——它活着会占住本机 5012/5013 端口，包根本发不出去。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("按顺序试") {
                    Button {
                        fillGateway()
                    } label: {
                        Label("填入网关 .1（热点网关通常就是车机）", systemImage: "1.circle")
                    }
                    Button {
                        runProbe()
                    } label: {
                        Label(probing ? "体检中…" : "体检当前 IP（TCP 端口 + RTCP 5013）",
                              systemImage: "2.circle")
                    }
                    .disabled(probing)
                    Button {
                        runScan()
                    } label: {
                        Label(scanning ? "RTCP 扫描中…（约 2 秒）" : "扫全段 RTCP 5013",
                              systemImage: "3.circle")
                    }
                    .disabled(scanning)
                    Button {
                        runTcpScan()
                    } label: {
                        Label(tcpScanning ? "端口扫描中…（约 8 秒）" : "扫全段常见 TCP 端口",
                              systemImage: "4.circle")
                    }
                    .disabled(tcpScanning)
                }
                if !scanSummary.isEmpty {
                    Section("结果") {
                        Text(scanSummary)
                            .font(.footnote.monospaced())
                    }
                }
                Section {
                    Text("8443 只是车机常见网页端口之一，不同车型/固件不一样。真正的投屏通道只有 UDP 5012/5013。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("找仪表 IP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showTools = false }
                }
            }
        }
    }

    /// 按当前方向渲染「仪表上会看到的样子」
    private func previewImageView(_ image: UIImage) -> some View {
        let preset = DashboardPreset.all[presetIndex]
        let rotation = currentRotationDegrees
        let rendered = Self.renderPreview(image,
                                          rotation: rotation,
                                          width: preset.width,
                                          height: preset.height)
        return Image(uiImage: rendered)
            .resizable()
            .scaledToFill()
    }

    /// 用 CI 走一遍和投屏完全相同的旋转+铺满管线，所见即所得
    static func renderPreview(_ image: UIImage, rotation: Int, width: Int, height: Int) -> UIImage {
        guard var ci = CIImage(image: image) else {
            return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in }
        }
        switch rotation {
        case 90: ci = ci.oriented(.right)
        case 180: ci = ci.oriented(.down)
        case 270: ci = ci.oriented(.left)
        default: break
        }
        ci = FrameRenderer.aspectFillTransform(ci, destWidth: width, destHeight: height)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let cg = previewContext.createCGImage(ci, from: rect) {
            return UIImage(cgImage: cg)
        }
        return UIGraphicsImageRenderer(size: rect.size).image { _ in }
    }

    // MARK: - 来源应用逻辑（只有确认过的素材才会真正上屏）
    private func applySource() {
        let rotation = currentRotationDegrees
        switch sourceIndex {
        case 0:
            engine.useTestImage()
        case 1:
            if imageConfirmed, let confirmedImage {
                engine.usePhoto(confirmedImage, rotation: rotation)
            } else {
                engine.useTestImage()
            }
        case 2:
            if videoConfirmed, let confirmedVideoURL {
                engine.useVideo(url: confirmedVideoURL, rotation: rotation)
            } else {
                engine.useTestImage()
            }
        case 3:
            engine.useCamera(position: cameraPositionIndex == 0 ? .back : .front,
                             rotation: rotation)
        default:
            break
        }
    }

    // MARK: - 找 IP 工具
    private func fillGateway() {
        guard let gateway = LanScanner.gatewayGuess() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        host = gateway
        scanSummary = "已填入网关 \(gateway)（车机热点自己发 DHCP，网关通常就是它）。\n填好点「体检」验一下，再开始投屏。"
    }

    private func runProbe() {
        let ip = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            scanSummary = "先填一个 IP 再体检"
            return
        }
        guard ip != localIP else {
            scanSummary = "这是本机地址（\(ip)），换仪表的 IP"
            return
        }
        probing = true
        scanSummary = "体检 \(ip) …（端口 + RTCP，约 3 秒）"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LanScanner.probe(ip: ip)
            DispatchQueue.main.async {
                probing = false
                var lines: [String] = []
                if result.openPorts.isEmpty {
                    lines.append("TCP：常见端口都没开")
                } else {
                    lines.append("TCP 开放：\(result.openPorts.map { String($0) }.joined(separator: ", "))")
                }
                lines.append(result.rtcpPong
                             ? "RTCP 5013：有 pong（\(result.rttMs)ms）"
                             : "RTCP 5013：无回应（不在接收态，或 IP 不对）")
                if !result.pongHex.isEmpty {
                    lines.append(result.pongHex)
                }
                scanSummary = lines.joined(separator: "\n")
            }
        }
    }

    private func runTcpScan() {
        guard let prefix = LanScanner.localPrefix() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        tcpScanning = true
        scanSummary = "扫 \(prefix).1-254 的 8443/80/443/5000/8080/8000/9000 …"
        LanScanner.tcpScan(prefix: prefix) { ip in
            host = ip
            scanSummary = "发现有开放端口：\(ip)（已回填）"
        } completion: { hits in
            tcpScanning = false
            if hits.isEmpty {
                scanSummary = "\(prefix).0/24 没有主机开放这些端口。\n换「网关 .1」或「扫 RTCP 5013」试试——端口只是线索，投屏通道是 UDP 5012/5013。"
            } else {
                scanSummary = hits
                    .map { "\($0.ip)  端口 \($0.ports.map { String($0) }.joined(separator: "/"))" }
                    .joined(separator: "\n")
            }
        }
    }

    private func runScan() {
        guard let prefix = LanScanner.localPrefix() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        scanning = true
        scanSummary = "扫描 \(prefix).1-254 的 5013（含广播探测）…"
        LanScanner.scan(prefix: prefix) { hit in
            host = hit.ip
            scanSummary = "先回应的：\(hit.ip) \(hit.rttMs)ms\n\(hit.replyHex)"
        } completion: { hits in
            scanning = false
            if hits.isEmpty {
                scanSummary = "\(prefix).0/24 没有主机在 5013 回应（本机已排除）。\n仪表多半还没进入投屏接收态——先在仪表/官方 App 里进接收态，再扫一次。"
            } else {
                scanSummary = hits.map { "\($0.ip)  \($0.rttMs)ms  ×\($0.replyCount)  \($0.replyHex)" }
                    .joined(separator: "\n")
            }
        }
    }
}

/// 系统录屏选择器：点一下弹出广播列表，选 NinebotCast 即开始屏幕镜像。
/// preferredExtension 预选我们的录屏扩展，省得用户在列表里找。
struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        // 必须带一个非零 frame 创建：零 frame 创建时内部按钮按零尺寸布局，
        // 之后 SwiftUI 再改尺寸也不会重新布局，按钮就一直空白。
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.preferredExtension = "com.corpsezhao.ninebotcast.screencast"
        view.showsMicrophoneButton = false
        return view
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
