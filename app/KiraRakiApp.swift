import CoreImage
import MetalKit
import SwiftUI

private let accent = Color(red: 0.15, green: 0.9, blue: 0.93)
private let panel = Color(red: 0.071, green: 0.079, blue: 0.11)

@main struct KiraRakiApp: App {
  @StateObject private var model = StudioModel()
  var body: some Scene {
    WindowGroup("KiraRaki") {
      StudioView(model: model).preferredColorScheme(.dark).tint(accent).frame(
        minWidth: 1050, minHeight: 700)
    }
    .defaultSize(width: 1350, height: 860)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("動画を開く…") { model.openMovie() }.keyboardShortcut("o")
      }
      CommandMenu("ライブ操作") {
        Button("エフェクト ON / OFF") { model.set("enabled", !model.flag("enabled")) }.keyboardShortcut(
          .space, modifiers: [])
        Button("再生 / 一時停止") { model.togglePlayback() }.keyboardShortcut(.space)
        Button("録画 開始 / 停止") { model.toggleRecording() }.keyboardShortcut("r")
        Button("ランダム生成") { model.randomize() }.keyboardShortcut("r", modifiers: [.shift, .command])
        Divider()
        ForEach(Array(model.presets.prefix(4).enumerated()), id: \.element.id) { index, preset in
          Button(preset.name) { model.applyPreset(preset.id) }.keyboardShortcut(
            KeyEquivalent(Character(String(index + 1))), modifiers: [])
        }
      }
    }
  }
}

struct StudioView: View {
  @ObservedObject var model: StudioModel
  @State private var saveSheet = false
  @State private var presetName = "My Preset"
  @State private var inspectorTab = 0
  var body: some View {
    VStack(spacing: 0) {
      topBar
      Divider().opacity(0.4)
      HStack(spacing: 0) {
        sidebar.frame(width: 208)
        Divider().opacity(0.4)
        VStack(spacing: 0) {
          preview
          transport
          quickControls
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        if model.detailed {
          Divider().opacity(0.4)
          inspector.frame(width: 300)
        }
      }
      Divider().opacity(0.4)
      statusBar
    }
    .background(Color(red: 0.04, green: 0.047, blue: 0.07))
    .onAppear { model.windowVisible = true }
    .onDisappear { model.windowVisible = false }
    .sheet(isPresented: $saveSheet) {
      VStack(alignment: .leading, spacing: 20) {
        Text("プリセットを保存").font(.title3.bold())
        TextField("名前", text: $presetName).textFieldStyle(.roundedBorder)
        HStack {
          Spacer()
          Button("キャンセル") { saveSheet = false }
          Button("保存") {
            model.savePreset(name: presetName)
            saveSheet = false
          }.keyboardShortcut(.defaultAction)
        }
      }.padding(28).frame(width: 350)
    }
  }
  private var topBar: some View {
    HStack(spacing: 12) {
      Image(systemName: "waveform.path").font(.system(size: 23, weight: .light)).foregroundStyle(
        accent)
      Text("KiraRaki").font(.system(size: 20, weight: .semibold, design: .rounded)).tracking(1)
      Text("CONTOUR STUDIO").font(.system(size: 9, weight: .medium)).tracking(2).foregroundStyle(
        .secondary)
      Spacer()
      HStack(spacing: 6) {
        Circle().fill(model.connected ? accent : .orange).frame(width: 5, height: 5)
        Text(model.connected ? "ENGINE ONLINE" : "ENGINE OFFLINE").font(
          .system(size: 9, weight: .semibold, design: .monospaced))
      }.padding(.horizontal, 10).padding(.vertical, 7).background(
        .white.opacity(0.04), in: Capsule())
      Button {
        model.detailed.toggle()
      } label: {
        Label(model.detailed ? "シンプル" : "詳細", systemImage: "slider.horizontal.3")
      }.buttonStyle(.bordered)
      Button {
        model.toggleRecording()
      } label: {
        HStack(spacing: 7) {
          Circle().fill(model.recording ? .white : .red).frame(width: 7, height: 7)
          Text(model.recording ? "録画停止" : "録画")
        }
      }.buttonStyle(.borderedProminent).tint(model.recording ? .red : Color.white.opacity(0.1))
        .disabled(!model.connected)
    }.padding(.horizontal, 22).padding(.vertical, 14)
  }
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 10) {
        eyebrow("INPUT / 入力")
        ForEach(InputKind.allCases) { kind in
          Button {
            model.selectInput(kind)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: kind.icon).frame(width: 18)
              Text(kind.rawValue)
              Spacer()
              if model.input == kind { Circle().fill(accent).frame(width: 5, height: 5) }
            }.padding(.horizontal, 12).padding(.vertical, 10).background(
              model.input == kind ? accent.opacity(0.09) : .clear,
              in: RoundedRectangle(cornerRadius: 8)
            ).foregroundStyle(model.input == kind ? accent : .secondary)
          }.buttonStyle(.plain)
        }
      }
      Divider().opacity(0.4)
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          eyebrow("PRESETS / プリセット")
          Spacer()
          Button {
            saveSheet = true
          } label: {
            Image(systemName: "plus.circle")
          }.buttonStyle(.plain).foregroundStyle(.secondary).help("プリセットを保存")
        }
        ForEach(model.presets) { preset in
          Button {
            model.applyPreset(preset.id)
          } label: {
            HStack(spacing: 10) {
              RoundedRectangle(cornerRadius: 2).fill(presetColor(preset.id)).frame(
                width: 3, height: 24)
              VStack(alignment: .leading, spacing: 3) {
                Text(preset.name).font(.system(size: 11, weight: .medium))
                if preset.id == model.selectedPreset {
                  Text("ACTIVE").font(.system(size: 8, design: .monospaced)).foregroundStyle(accent)
                }
              }
              Spacer()
            }.padding(.vertical, 5).foregroundStyle(
              preset.id == model.selectedPreset ? .white : .secondary)
          }.buttonStyle(.plain)
        }
        HStack {
          Button("読み込む") { model.importPreset() }
          Button("保存先…") { model.exportPreset() }
        }.font(.system(size: 10)).buttonStyle(.borderless).foregroundStyle(.secondary)
      }
      Spacer(minLength: 10)
      VStack(alignment: .leading, spacing: 10) {
        eyebrow("OUTPUT / 出力")
        Picker("表示", selection: intBinding("outputMode")) {
          Text("元映像と合成").tag(0)
          Text("黒背景 / 線のみ").tag(1)
          Text("透明 / RGBA").tag(2)
        }.labelsHidden()
        Picker("形式", selection: $model.exportCodec) {
          Text("MP4 · H.264").tag("h264")
          Text("MOV · ProRes 4444").tag("prores4444")
          Text("MOV · HEVC Alpha").tag("hevc-alpha")
        }.labelsHidden()
        if model.exportCodec == "h264" && model.integer("outputMode") == 2 {
          Text("MP4は透過を保持しません").font(.caption2).foregroundStyle(.orange)
        }
        Button {
          model.exportMovie()
        } label: {
          Label("高品質書き出し…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
        }.buttonStyle(.bordered).disabled(model.fileURL == nil || model.exportProgress != nil)
        if model.recording {
          Text(
            "保存 \(String(format: "%.1f", (model.serviceStatus["recordingBytes"] as? Double ?? 0)/1_000_000)) MB · \(String(format: "%.1f", model.serviceStatus["recordingMBps"] as? Double ?? 0)) MB/s"
          )
          .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
        }
        Button("操作ログから再現…") { model.exportMovie(replay: true) }.font(.caption).buttonStyle(
          .borderless
        ).foregroundStyle(.secondary).disabled(model.exportProgress != nil)
      }
    }.padding(18).background(panel)
  }
  private var preview: some View {
    VStack(spacing: 0) {
      HStack {
        HStack(spacing: 8) {
          Circle().fill(model.playing ? accent : .orange).frame(width: 5, height: 5)
          Text(model.sourceTitle).font(.system(size: 11, weight: .medium))
          if model.input == .demo {
            Text("DEMO").font(.system(size: 8, weight: .medium, design: .monospaced))
              .foregroundStyle(.secondary).padding(4).overlay(
                RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.12)))
          }
        }
        Spacer()
        Text("\(model.surface?.width ?? 1280) × \(model.surface?.height ?? 720)").font(
          .system(size: 10, design: .monospaced)
        ).foregroundStyle(.secondary)
      }.padding(18)
      ZStack {
        MetalPreview(surface: model.surface)
        if model.surface == nil {
          VStack(spacing: 14) {
            Image(systemName: "waveform.path").font(.system(size: 44, weight: .ultraLight))
              .foregroundStyle(accent.opacity(0.5))
            Text(
              model.input == .obs
                ? "OBSからの入力を待っています" : model.connected ? model.message : "レンダーサービスに接続してください"
            ).foregroundStyle(
              .secondary)
            if !model.connected {
              Button("サービスに接続") { model.registerService() }.buttonStyle(.bordered)
            }
          }
        }
        VStack {
          HStack {
            Spacer()
            Text(
              model.integer("outputMode") == 2
                ? "ALPHA" : model.flag("enabled") ? "LIVE EFFECT" : "BYPASS"
            ).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
              .foregroundStyle(model.flag("enabled") ? accent : .orange).padding(.horizontal, 9)
              .padding(.vertical, 6).background(
                .black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
          }
          Spacer()
        }.padding(14)
      }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(
        RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.08))
      ).padding(.horizontal, 18)
      Spacer(minLength: 8)
    }.frame(maxHeight: .infinity)
  }
  private var transport: some View {
    HStack(spacing: 14) {
      Button {
        model.togglePlayback()
      } label: {
        Image(systemName: model.playing ? "pause.fill" : "play.fill")
      }.buttonStyle(.plain).help("再生 / 一時停止 (⌘Space)")
      if model.input == .file {
        Text(time(model.playhead)).font(.system(size: 10, design: .monospaced)).foregroundStyle(
          .secondary)
        Slider(
          value: Binding(get: { model.playhead }, set: { model.seek($0) }),
          in: 0...max(1, model.duration)
        ).disabled(model.recording)
        Text(time(model.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(
          .secondary)
      } else {
        Text(model.input == .demo ? "内蔵デモ · 動く輪郭でエフェクトを確認" : "リアルタイム入力").font(.system(size: 10))
          .foregroundStyle(.secondary)
        Spacer()
      }
      Button {
        model.randomize()
      } label: {
        Label("Randomize", systemImage: "shuffle")
      }.font(.system(size: 10)).buttonStyle(.borderless).foregroundStyle(.secondary)
    }.padding(.horizontal, 24).padding(.vertical, 14)
  }
  private var quickControls: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        eyebrow("LOOK / 表現")
        Spacer()
        Toggle("エフェクト", isOn: boolBinding("enabled")).toggleStyle(.switch).controlSize(.mini)
      }
      HStack(alignment: .top, spacing: 30) {
        knob("変形強度", key: "distortion", range: 0...1, format: "%.0f%%", multiplier: 100)
        knob("描画密度", key: "density", range: 0...1, format: "%.0f%%", multiplier: 100)
        knob("線幅", key: "lineWidth", range: 0.5...18, format: "%.1f px")
      }
      HStack(spacing: 16) {
        Text("COLOR").font(.system(size: 9, weight: .semibold, design: .monospaced))
          .foregroundStyle(.secondary)
        Picker("色", selection: intBinding("colorMode")) {
          Text("時間色相").tag(0)
          Text("パレット").tag(1)
          Text("ランダム").tag(2)
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 270)
        Spacer()
        HStack(spacing: 5) {
          ForEach(model.preset["palette"] as? [String] ?? [], id: \.self) { hex in
            Circle().fill(Color(hex: hex)).frame(width: 13, height: 13)
          }
        }
      }
    }.padding(22).background(panel)
  }
  private var inspector: some View {
    VStack(spacing: 0) {
      Picker("設定", selection: $inspectorTab) {
        Text("描画").tag(0)
        Text("音 / MIDI").tag(1)
        Text("接続").tag(2)
      }.pickerStyle(.segmented).padding(16)
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          if inspectorTab == 0 { drawingInspector }
          if inspectorTab == 1 { AudioMIDIView(model: model, midi: model.midi) }
          if inspectorTab == 2 { connectionInspector }
        }.padding(18)
      }
    }.background(panel)
  }
  private var drawingInspector: some View {
    Group {
      VStack(alignment: .leading, spacing: 12) {
        eyebrow("GEOMETRY / 線の混合")
        ForEach(Array(["稲妻", "有機線", "グリッチ", "断片線"].enumerated()), id: \.offset) { index, name in
          HStack {
            Toggle(
              name,
              isOn: Binding(
                get: { model.arrayValue("shapes", index) > 0 },
                set: { model.setArray("shapes", index, $0 ? 0.7 : 0) })
            ).toggleStyle(.checkbox).frame(width: 85, alignment: .leading)
            Slider(value: arrayBinding("shapes", index), in: 0...1)
          }
        }
      }
      VStack(alignment: .leading, spacing: 12) {
        eyebrow("ANALYSIS / 解析")
        Picker("方式", selection: intBinding("analysisMode")) {
          Text("ハイブリッド").tag(0)
          Text("画像処理").tag(1)
          Text("AI中心").tag(2)
        }
        knob("検出閾値", key: "threshold", range: 0.01...0.6, format: "%.2f")
        ForEach(Array(["外輪郭", "内部特徴", "テクスチャ", "動き", "角点"].enumerated()), id: \.offset) {
          index, name in
          HStack {
            Text(name).font(.caption).frame(width: 75, alignment: .leading)
            Slider(value: arrayBinding("regions", index), in: 0...1)
          }
        }
      }
      VStack(alignment: .leading, spacing: 12) {
        eyebrow("PLACEMENT / 発生位置")
        ForEach(Array(["ランダム", "特徴点", "動き"].enumerated()), id: \.offset) { index, name in
          HStack {
            Text(name).font(.caption).frame(width: 75, alignment: .leading)
            Slider(value: arrayBinding("placement", index), in: 0...1)
          }
        }
      }
      VStack(alignment: .leading, spacing: 14) {
        eyebrow("TIME / 追従と持続")
        knob("追従度", key: "tracking", range: 0...1, format: "%.0f%%", multiplier: 100)
        knob("揺らぎ", key: "irregularity", range: 0...1, format: "%.0f%%", multiplier: 100)
        knob("寿命", key: "lifetime", range: 0.05...4, format: "%.2f s")
        knob("変化・更新頻度", key: "updateHz", range: 0.1...30, format: "%.1f Hz")
        Picker("検出途切れ", selection: intBinding("lossMode")) {
          Text("保持 → 減衰").tag(0)
          Text("すぐに消去").tag(1)
          Text("寿命まで保持").tag(2)
        }
      }
      VStack(alignment: .leading, spacing: 14) {
        eyebrow("LIGHT / 光と色")
        knob("発光", key: "glow", range: 0...2, format: "%.2f")
        knob("発光半径", key: "glowRadius", range: 1...18, format: "%.1f")
        knob("残像半減期", key: "trailHalfLife", range: 0...1.5, format: "%.2f s")
        knob("色相変化速度", key: "hueSpeed", range: -0.5...0.5, format: "%.3f")
        knob("色相オフセット", key: "hueOffset", range: 0...1, format: "%.2f")
        TextField("RGB値をカンマ区切り", text: $model.paletteText).textFieldStyle(.roundedBorder).font(
          .system(size: 10, design: .monospaced)
        ).onSubmit { model.updatePalette() }
        Button("パレットを適用") { model.updatePalette() }.font(.caption)
      }
      VStack(alignment: .leading, spacing: 12) {
        eyebrow("PRESET / 切替")
        knob("補間時間 (0 = 即時)", key: "transitionSeconds", range: 0...5, format: "%.1f s")
        Toggle("切替時に残像を消去", isOn: boolBinding("clearTrailsOnPreset"))
        HStack {
          Text("シード").font(.caption)
          TextField(
            "seed",
            value: Binding<Double>(get: { model.number("seed") }, set: { model.set("seed", $0) }),
            format: .number.precision(.fractionLength(0))
          ).textFieldStyle(.roundedBorder)
        }
      }
    }
  }
  private var connectionInspector: some View {
    Group {
      VStack(alignment: .leading, spacing: 12) {
        eyebrow("RENDER SERVICE")
        Label(
          model.connected ? "接続中 · Metal" : "未接続",
          systemImage: model.connected ? "checkmark.circle" : "exclamationmark.circle"
        ).foregroundStyle(model.connected ? accent : .orange)
        Button("サービスを登録 / 接続") { model.registerService() }
        Toggle("負荷に応じて自動調整", isOn: boolBinding("autoAdapt"))
        Text("設定画面を閉じても、OBSが接続している間は処理を継続します。").font(.caption).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 12) {
        eyebrow("OBS / 入力とプレビュー")
        Label(
          model.obsConnected ? "OBS映像を受信中" : "OBS入力待機中",
          systemImage: "rectangle.connected.to.line.below")
        Picker(
          "操作するOBS項目",
          selection: Binding(get: { model.obsInstanceID }, set: { model.selectOBSInstance($0) })
        ) {
          Text("選択してください").tag("")
          ForEach(model.obsInstances) { instance in
            Text((instance.filter ? "フィルタ: " : "ソース: ") + instance.name).tag(instance.id)
          }
        }
        if let instance = model.selectedOBSInstance {
          Picker(
            "解析する入力",
            selection: Binding(
              get: { instance.targetUUID }, set: { model.routeOBS(["targetUUID": $0]) })
          ) {
            Text("Macアプリの映像").tag("")
            ForEach(model.obsTargets) { target in Text(target.name).tag(target.id) }
          }.disabled(instance.filter)
          Picker(
            "OBS音声ミックス",
            selection: Binding(
              get: { instance.audioMix }, set: { model.routeOBS(["audioMix": $0]) })
          ) {
            Text("音声を取得しない").tag(0)
            ForEach(1...6, id: \.self) { Text("ミックス / トラック \($0)").tag($0) }
          }
        }
        Picker("プレビュー対象", selection: $model.selectedOBS) {
          Text("最新の入力").tag("")
          ForEach(obsSources, id: \.self) {
            Text($0.replacingOccurrences(of: "obs:", with: "")).tag($0)
          }
        }
        Text("OBSで「KiraRaki 輪郭フィルタ」を追加するか、「KiraRaki 線画ソース」で参照元を選択してください。").font(.caption)
          .foregroundStyle(.secondary)
        Text("現在の連携経路: GPU読戻し → IOSurface → Metal → OBS。推論完了待ちは描画スレッドで行いません。").font(.caption2)
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 12) {
        eyebrow("METRICS / 状態")
        statRow("輪郭候補", value: metric("candidates", format: "%.0f"))
        statRow("描画ストローク", value: metric("strokes", format: "%.0f"))
        statRow("GPU頂点数", value: metric("vertices", format: "%.0f"))
        statRow("解析幅", value: metric("analysisWidth", format: "%.0f px"))
        statRow(
          "AIマスク", value: model.metadata["visionReady"] as? Bool == true ? "有効" : "取得中 / 画像処理")
        statRow("記録フレーム", value: String((model.serviceStatus["recordedFrames"] as? Int) ?? 0))
        if let e = model.metadata["visionError"] as? String, !e.isEmpty {
          Text(e).font(.caption2).foregroundStyle(.orange)
        }
      }
      Text("遅延表示は内部推定値です。OBS合成出力までのp95と外部基準の測定は別途行います。").font(.caption2).foregroundStyle(.secondary)
    }
  }
  private var obsSources: [String] {
    ((model.serviceStatus["sources"] as? [[String: Any]]) ?? []).compactMap {
      $0["sourceID"] as? String
    }.filter { $0.hasPrefix("obs:") }
  }
  private var statusBar: some View {
    HStack(spacing: 16) {
      HStack(spacing: 5) {
        Circle().fill(model.connected ? accent : .orange).frame(width: 4, height: 4)
        Text(model.message).lineLimit(1)
      }.font(.system(size: 10)).foregroundStyle(.secondary)
      Spacer(minLength: 10)
      if let progress = model.exportProgress {
        ProgressView(value: progress).frame(width: 90)
        Text("\(Int(progress*100))%")
        Button("中止") { model.cancelExport() }.buttonStyle(.plain)
      }
      Text(metric("fps", format: "%.0f FPS"))
      Text(metric("processingMS", format: "GPU/CPU %.1f ms"))
      Text(metric("latencyMS", format: "推定 %.1f ms"))
      Text("OBS \(model.obsConnected ? "●" : "○")").foregroundStyle(
        model.obsConnected ? accent : .secondary)
      Text("ADAPT \(model.metadata["adaptationLevel"] as? Int ?? 0)").foregroundStyle(
        (model.metadata["adaptationLevel"] as? Int ?? 0) > 0 ? .orange : .secondary)
    }.font(.system(size: 9, design: .monospaced)).padding(.horizontal, 18).frame(height: 34)
      .background(panel)
  }
  private func metric(_ key: String, format: String) -> String {
    if let n = model.metadata[key] as? NSNumber { return String(format: format, n.doubleValue) }
    return "—"
  }
  private func boolBinding(_ key: String) -> Binding<Bool> {
    Binding(get: { model.flag(key) }, set: { model.set(key, $0) })
  }
  private func intBinding(_ key: String) -> Binding<Int> {
    Binding(get: { model.integer(key) }, set: { model.set(key, $0) })
  }
  private func arrayBinding(_ key: String, _ index: Int) -> Binding<Double> {
    Binding(get: { model.arrayValue(key, index) }, set: { model.setArray(key, index, $0) })
  }
  private func knob(
    _ name: String, key: String, range: ClosedRange<Double>, format: String, multiplier: Double = 1
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(name).font(.system(size: 11))
        Spacer()
        Text(String(format: format, model.number(key) * multiplier)).font(
          .system(size: 10, design: .monospaced)
        ).foregroundStyle(accent)
      }
      Slider(value: Binding(get: { model.number(key) }, set: { model.set(key, $0) }), in: range)
    }.frame(maxWidth: .infinity)
  }
  private func time(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00" }
    return String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
  }
}

private struct AudioMIDIView: View {
  @ObservedObject var model: StudioModel
  @ObservedObject var midi: MIDIController
  @State private var feature = "rms"
  @State private var target = "distortion"
  @State private var gain = 1.0
  @State private var minimum = 0.0
  @State private var maximum = 1.0
  @State private var attack = 0.02
  @State private var release = 0.2
  @State private var invert = false
  private let targets = [
    "lineWidth", "distortion", "density", "glow", "trailHalfLife", "hueOffset", "hueSpeed",
    "lifetime", "updateHz",
  ]
  var body: some View {
    Group {
      VStack(alignment: .leading, spacing: 12) {
        eyebrow("AUDIO / 音声入力")
        Picker("入力", selection: $model.audioSource) {
          Text("動画の音声").tag("video")
          Text("OBSミックス").tag("obs")
          Text("無音").tag("none")
        }
        Text("OBSのミックス1〜6は、OBS側のKiraRakiプロパティで選択します。").font(.caption2).foregroundStyle(.secondary)
        ForEach(Array(["RMS", "LOW", "MID", "HIGH", "ATTACK"].enumerated()), id: \.offset) {
          i, name in
          HStack {
            Text(name).font(.system(size: 8, design: .monospaced)).frame(
              width: 45, alignment: .leading)
            ProgressView(value: audioLevel(i)).tint(accent)
          }
        }
      }
      VStack(alignment: .leading, spacing: 12) {
        eyebrow("MODULATION / 音反応")
        Picker("特徴量", selection: $feature) {
          Text("音量").tag("rms")
          Text("低域").tag("low")
          Text("中域").tag("mid")
          Text("高域").tag("high")
          Text("アタック").tag("onset")
        }
        Picker("割当先", selection: $target) { ForEach(targets, id: \.self) { Text($0).tag($0) } }
        numberField("ゲイン", value: $gain)
        HStack {
          numberField("最小", value: $minimum)
          numberField("最大", value: $maximum)
        }
        HStack {
          numberField("Attack (s)", value: $attack)
          numberField("Release (s)", value: $release)
        }
        Toggle("反転", isOn: $invert)
        Button("マッピングを追加") {
          var maps = model.preset["audioMappings"] as? [[String: Any]] ?? []
          maps.append([
            "feature": feature, "target": target, "gain": gain, "min": minimum, "max": maximum,
            "attack": attack, "release": release, "invert": invert,
          ])
          model.set("audioMappings", maps)
        }
        Button("ビート発光プリセット") {
          model.set(
            "audioMappings",
            [
              [
                "feature": "onset", "target": "glow", "gain": 3.0, "min": 0.2, "max": 1.8,
                "attack": 0.005, "release": 0.25, "invert": false,
              ],
              [
                "feature": "low", "target": "distortion", "gain": 2.0, "min": 0.1, "max": 0.8,
                "attack": 0.02, "release": 0.2, "invert": false,
              ],
            ])
        }
        ForEach(
          Array((model.preset["audioMappings"] as? [[String: Any]] ?? []).enumerated()),
          id: \.offset
        ) { index, map in
          HStack {
            Text("\(map["feature"] as? String ?? "") → \(map["target"] as? String ?? "")").font(
              .system(size: 10, design: .monospaced))
            Spacer()
            Button {
              var a = model.preset["audioMappings"] as? [[String: Any]] ?? []
              a.remove(at: index)
              model.set("audioMappings", a)
            } label: {
              Image(systemName: "minus.circle")
            }.buttonStyle(.plain)
          }
        }
      }
      VStack(alignment: .leading, spacing: 12) {
        eyebrow("MIDI / 外部コントロール")
        Text(
          midi.deviceNames.isEmpty ? "接続されたMIDI入力はありません" : midi.deviceNames.joined(separator: "\n")
        ).font(.caption).foregroundStyle(.secondary)
        Picker("割当先", selection: $model.midiLearnTarget) {
          ForEach(targets + ["enabled"], id: \.self) { Text($0).tag($0) }
        }
        Button(midi.learning ? "入力待機中… / 解除" : "MIDI Learn") { midi.learning.toggle() }.tint(
          midi.learning ? .orange : accent)
        Text(midi.lastEvent).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
        ForEach(midi.bindings.keys.sorted(), id: \.self) { key in
          Text("\(key) → \(midi.bindings[key] ?? "")").font(.system(size: 9, design: .monospaced))
        }
        Button("MIDI割当を解除") { midi.clearBindings() }.font(.caption)
      }
    }
  }
  private func audioLevel(_ i: Int) -> Double {
    let a = model.metadata["audio"] as? [Double] ?? []
    return a.indices.contains(i) ? a[i] : 0
  }
  private func numberField(_ name: String, value: Binding<Double>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(name).font(.caption2).foregroundStyle(.secondary)
      TextField(name, value: value, format: .number.precision(.fractionLength(0...3)))
        .textFieldStyle(.roundedBorder)
    }
  }
}
private func eyebrow(_ text: String) -> some View {
  Text(text).font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
}
private func statRow(_ name: String, value: String) -> some View {
  HStack {
    Text(name).font(.caption).foregroundStyle(.secondary)
    Spacer()
    Text(value).font(.system(size: 10, design: .monospaced))
  }
}
private func presetColor(_ id: String) -> Color {
  switch id {
  case "organic": return .purple
  case "glitch": return .pink
  case "ink": return .white
  default: return accent
  }
}
extension Color {
  fileprivate init(hex: String) {
    let n = UInt64(hex, radix: 16) ?? 0
    self.init(
      red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255,
      blue: Double(n & 255) / 255)
  }
}

struct MetalPreview: NSViewRepresentable {
  var surface: IOSurface?
  func makeCoordinator() -> Renderer { Renderer() }
  func makeNSView(context: Context) -> MTKView {
    let v = MTKView(frame: .zero, device: context.coordinator.device)
    v.colorPixelFormat = .bgra8Unorm
    v.framebufferOnly = false
    v.isPaused = true
    v.enableSetNeedsDisplay = true
    v.delegate = context.coordinator
    return v
  }
  func updateNSView(_ view: MTKView, context: Context) {
    context.coordinator.surface = surface
    view.needsDisplay = true
  }
  final class Renderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()!
    lazy var queue = device.makeCommandQueue()!
    lazy var ci = CIContext(mtlDevice: device)
    var surface: IOSurface?
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
      guard let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else {
        return
      }
      let size = view.drawableSize
      let rect = CGRect(origin: .zero, size: size)
      let background = CIImage(color: CIColor(red: 0.025, green: 0.03, blue: 0.045)).cropped(
        to: rect)
      var image = background
      if let surface {
        let source = CIImage(ioSurface: surface)
        let factor = min(size.width / CGFloat(surface.width), size.height / CGFloat(surface.height))
        let scaled = source.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let shifted = scaled.transformed(
          by: CGAffineTransform(
            translationX: (size.width - scaled.extent.width) / 2,
            y: (size.height - scaled.extent.height) / 2))
        if let checker = CIFilter(
          name: "CICheckerboardGenerator",
          parameters: [
            "inputColor0": CIColor(red: 0.08, green: 0.09, blue: 0.11),
            "inputColor1": CIColor(red: 0.12, green: 0.13, blue: 0.15), "inputWidth": 18,
          ])?.outputImage
        {
          image = checker.cropped(to: shifted.extent).composited(over: background)
        }
        image = shifted.composited(over: image)
      }
      ci.render(
        image, to: drawable.texture, commandBuffer: command, bounds: rect,
        colorSpace: CGColorSpace(name: CGColorSpace.itur_709)!)
      command.present(drawable)
      command.commit()
    }
  }
}
