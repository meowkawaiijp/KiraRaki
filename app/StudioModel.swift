@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreImage
import ServiceManagement
import UniformTypeIdentifiers

enum InputKind: String, CaseIterable, Identifiable {
  case demo = "デモ"
  case file = "動画ファイル"
  case camera = "カメラ"
  case obs = "OBS"
  var id: Self { self }
  var icon: String {
    switch self {
    case .demo: return "sparkles.tv"
    case .file: return "film"
    case .camera: return "video"
    case .obs: return "rectangle.on.rectangle"
    }
  }
}
struct OBSInstance: Identifiable {
  let id: String
  let name: String
  let sourceID: String
  let targetUUID: String
  let filter: Bool
  let audioMix: Int
}
struct OBSTarget: Identifiable {
  let id: String
  let name: String
}
struct SavedPreset: Identifiable {
  var id: String
  var name: String
  var values: [String: Any]
}

final class StudioModel: ObservableObject {
  @Published var preset = KRDefaultPreset() as! [String: Any]
  @Published var input: InputKind = .demo
  @Published var surface: IOSurface?
  @Published var metadata: [String: Any] = [:]
  @Published var serviceStatus: [String: Any] = [:]
  @Published var detailed = false
  @Published var windowVisible = true
  @Published var message = "レンダーサービスに接続しています"
  @Published var fileURL: URL?
  @Published var duration = 0.0
  @Published var playhead = 0.0
  @Published var playing = true
  @Published var recording = false
  @Published var exportProgress: Double?
  @Published var exportCodec = "h264"
  @Published var audioSource = "video" {
    didSet {
      set("audioInput", audioSource == "video" ? 0 : audioSource == "obs" ? 1 : 2)
      player?.isMuted = audioSource != "video"
    }
  }
  @Published var selectedOBS = ""
  @Published var obsInstanceID = ""
  @Published var presets: [SavedPreset] = []
  @Published var selectedPreset = "neon"
  @Published var paletteText = "0ACDFF, FF1475, A626FF, FFB30D"
  @Published var midiLearnTarget = "lineWidth"
  let midi = MIDIController()
  let client = KRClient()
  private var timer: Timer?, statusTimer: Timer?
  private let normalizer = FrameNormalizer()
  private var fileTransform = CGAffineTransform.identity
  private var player: AVPlayer?, playerOutput: AVPlayerItemVideoOutput?
  private var audioReader: AVAssetReader?, audioOutput: AVAssetReaderTrackOutput?
  private var nextAudio: CMSampleBuffer?
  private var audioRequest = UUID()
  private var capture: AVCaptureSession?
  private let cameraDelegate = CameraDelegate()
  private var frame = 0
  private var lastPresetSend = Date.distantPast
  private var dirtyPreset = true
  private var lastConnected = false
  private var exporting: Process?
  private let support: URL
  private var reconnectTimer = 0
  private var obsFrameID: UInt64 = 0

  init() {
    support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("KiraRaki", isDirectory: true)
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    installBuiltins()
    loadPresets()
    if let data = try? Data(contentsOf: support.appendingPathComponent("last-preset.json")),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let validated = try? checkedPreset(object)
    {
      preset = validated
    }
    syncPalette()
    audioSource = integer("audioInput") == 1 ? "obs" : integer("audioInput") == 2 ? "none" : "video"
    client.onFrame = { [weak self] surface, meta in
      DispatchQueue.main.async {
        guard let self else { return }
        self.surface = surface
        self.metadata = meta as? [String: Any] ?? [:]
      }
    }
    client.onError = { [weak self] error in
      DispatchQueue.main.async {
        self?.message = error
        self?.surface = nil
      }
    }
    cameraDelegate.onBuffer = { [weak self] pixel, pts in
      DispatchQueue.main.async {
        guard let self, self.input == .camera,
          self.windowVisible || self.recording
            || (self.serviceStatus["appFeedDemand"] as? Bool ?? false)
        else { return }
        guard let normalized = self.normalizer.normalize(pixel) else {
          self.message = "映像をRec.709に変換できませんでした"
          return
        }
        _ = self.client.submitPixelBuffer(
          normalized, pts: pts, source: "app-main",
          mode: self.integer("outputMode"))
      }
    }
    midi.onControl = { [weak self] key, value in
      DispatchQueue.main.async { self?.handleMIDI(key, value) }
    }
    client.connect()
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      self?.tick()
    }
    statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      self?.refreshStatus()
    }
  }
  var connected: Bool { client.connected }
  var obsConnected: Bool { serviceStatus["obsConnected"] as? Bool ?? false }
  var sourceTitle: String {
    input == .file
      ? fileURL?.lastPathComponent ?? "動画を選択"
      : input == .demo ? "Contour Playground" : input.rawValue
  }
  func number(_ key: String) -> Double { (preset[key] as? NSNumber)?.doubleValue ?? 0 }
  func integer(_ key: String) -> Int { Int(number(key)) }
  func flag(_ key: String) -> Bool { preset[key] as? Bool ?? false }
  func set(_ key: String, _ value: Any, origin: String = "ui") {
    preset[key] = value
    dirtyPreset = true
    if key == "outputMode", !obsInstanceID.isEmpty {
      client.routeOBS(["outputMode": value], instance: obsInstanceID)
    }
    if origin.hasPrefix("midi") {
      client.configure(preset, origin: origin)
      dirtyPreset = false
    }
  }
  func setArray(_ key: String, _ index: Int, _ value: Double) {
    var values = preset[key] as? [Double] ?? []
    guard values.indices.contains(index) else { return }
    values[index] = value
    set(key, values)
  }
  func arrayValue(_ key: String, _ index: Int) -> Double {
    let a = preset[key] as? [Double] ?? []
    return a.indices.contains(index) ? a[index] : 0
  }
  func installBuiltins() {
    func values(_ extras: [String: Any]) -> [String: Any] {
      var p = KRDefaultPreset() as! [String: Any]
      p.merge(extras) { _, new in new }
      return p
    }
    presets = [
      SavedPreset(
        id: "neon", name: "Motion Lightning",
        values: values([
          "tracking": 0.9, "lifetime": 1.0, "glow": 0.18, "trailHalfLife": 0.035,
          "colorMode": 1, "palette": ["0ACDFF", "FF1475", "FFDD18"],
        ])),
      SavedPreset(
        id: "organic", name: "Soft Organics",
        values: values([
          "shapes": [0, 1, 0, 0.15], "distortion": 0.25, "glow": 0.45, "trailHalfLife": 0.28,
          "lineWidth": 2, "hueSpeed": 0.025,
        ])),
      SavedPreset(
        id: "glitch", name: "Digital Fracture",
        values: values([
          "shapes": [0.7, 0, 1, 0.85], "distortion": 0.7, "glow": 0.35, "trailHalfLife": 0.04,
          "palette": ["00FFCC", "FF287A", "C8FF40"], "colorMode": 1,
        ])),
      SavedPreset(
        id: "ink", name: "Electric Ink",
        values: values([
          "shapes": [0.1, 1, 0, 0], "lineWidth": 1.5, "distortion": 0.08, "density": 0.65,
          "glow": 0.08, "trailHalfLife": 0, "palette": ["E2F3FF"], "colorMode": 1,
        ])),
    ]
  }
  func applyPreset(_ id: String) {
    guard let chosen = presets.first(where: { $0.id == id }) else { return }
    let duration = number("transitionSeconds")
    let mode = integer("outputMode")
    let audio = integer("audioInput")
    preset = chosen.values
    preset["transitionSeconds"] = duration
    preset["outputMode"] = mode
    preset["audioInput"] = audio
    selectedPreset = id
    syncPalette()
    client.configure(preset, origin: "preset")
    dirtyPreset = false
    persist()
  }
  func randomize() {
    let seed = UInt64.random(in: 1...9_000_000_000)
    var rng = SeededRandom(seed: seed)
    preset["seed"] = seed
    preset["distortion"] = rng.nextDouble() * 0.75 + 0.1
    preset["density"] = rng.nextDouble() * 0.5 + 0.15
    preset["shapes"] = (0..<4).map { _ in rng.nextDouble() }
    preset["hueOffset"] = rng.nextDouble()
    preset["glow"] = rng.nextDouble() * 1.2
    client.configure(preset, origin: "randomize")
    dirtyPreset = false
  }
  func savePreset(name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let id = UUID().uuidString
    let item = SavedPreset(id: id, name: name, values: preset)
    presets.append(item)
    selectedPreset = id
    let object: [String: Any] = ["id": id, "name": name, "preset": preset]
    do {
      let data = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: support.appendingPathComponent("preset-\(id).json"), options: .atomic)
    } catch { message = error.localizedDescription }
  }
  private func loadPresets() {
    for url
      in (try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil))
      ?? [] where url.lastPathComponent.hasPrefix("preset-")
    {
      if let data = try? Data(contentsOf: url),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let p = object["preset"] as? [String: Any], let valid = try? checkedPreset(p)
      {
        presets.append(
          SavedPreset(
            id: object["id"] as? String ?? UUID().uuidString,
            name: object["name"] as? String ?? "Preset", values: valid))
      }
    }
  }
  func exportPreset() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "KiraRaki-preset.json"
    if panel.runModal() == .OK, let url = panel.url {
      do {
        try JSONSerialization.data(withJSONObject: preset, options: [.prettyPrinted, .sortedKeys])
          .write(to: url, options: .atomic)
      } catch { message = error.localizedDescription }
    }
  }
  func importPreset() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    if panel.runModal() == .OK, let url = panel.url {
      do {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let p = value as? [String: Any], let validated = try? checkedPreset(p) else { return }
        preset = validated
        syncPalette()
        client.configure(preset, origin: "preset")
      } catch { message = error.localizedDescription }
    }
  }
  func syncPalette() {
    paletteText = (preset["palette"] as? [String] ?? []).joined(separator: ", ")
  }
  func updatePalette() {
    let colors = paletteText.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
    }
    var p = preset
    p["palette"] = colors
    do {
      preset = try checkedPreset(p)
      dirtyPreset = true
    } catch { message = error.localizedDescription }
  }
  private func persist() {
    if let data = try? JSONSerialization.data(withJSONObject: preset, options: [.sortedKeys]) {
      try? data.write(to: support.appendingPathComponent("last-preset.json"), options: .atomic)
    }
  }

  func selectInput(_ kind: InputKind) {
    if recording {
      message = "入力を切り替える前に録画を停止してください"
      return
    }
    if kind == .file {
      openMovie()
      return
    }
    stopInput()
    input = kind
    surface = nil
    client.reset("app-main")
    frame = 0
    if kind == .camera {
      audioSource = "none"
      startCamera()
    }
    if kind == .obs { audioSource = "obs" }
  }
  func openMovie() {
    if recording {
      message = "入力を切り替える前に録画を停止してください"
      return
    }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    stopInput()
    fileTransform = .identity
    input = .file
    audioSource = "video"
    fileURL = url
    client.reset("app-main")
    let asset = AVURLAsset(url: url)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
    ])
    let item = AVPlayerItem(asset: asset)
    item.add(output)
    playerOutput = output
    player = AVPlayer(playerItem: item)
    player?.isMuted = audioSource != "video"
    duration = 0
    Task { @MainActor [weak self] in
      do {
        let value = try await asset.load(.duration)
        guard let self, self.fileURL == url, self.input == .file else { return }
        self.duration = CMTimeGetSeconds(value)
        if let track = try await asset.loadTracks(withMediaType: .video).first {
          let transform = try await track.load(.preferredTransform)
          if self.fileURL == url && self.input == .file { self.fileTransform = transform }
        }
      } catch { self?.message = error.localizedDescription }
    }
    playhead = 0
    playing = true
    player?.play()
    prepareAudio(asset: asset, start: 0)
    message = "動画を読み込みました"
  }
  private func prepareAudio(asset: AVAsset, start: Double) {
    audioReader?.cancelReading()
    nextAudio = nil
    audioRequest = UUID()
    let request = audioRequest
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard self.audioRequest == request, self.input == .file, let track = tracks.first else {
          return
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
          track: track,
          outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
          ])
        reader.add(output)
        if start > 0 {
          reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600), duration: .positiveInfinity)
        }
        if reader.startReading() {
          self.audioReader = reader
          self.audioOutput = output
          self.nextAudio = output.copyNextSampleBuffer()
        }
      } catch { self.message = error.localizedDescription }
    }
  }
  func seek(_ position: Double) {
    guard !recording, let player else { return }
    let position = max(0, min(duration, position))
    player.seek(
      to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero,
      toleranceAfter: .zero)
    playhead = position
    client.reset("app-main")
    if let asset = player.currentItem?.asset { prepareAudio(asset: asset, start: position) }
  }
  func togglePlayback() {
    if !playing && input == .file && duration > 0 && playhead >= duration { seek(0) }
    playing.toggle()
    if playing { player?.play() } else { player?.pause() }
  }
  private func stopInput() {
    player?.pause()
    player = nil
    playerOutput = nil
    audioReader?.cancelReading()
    audioReader = nil
    nextAudio = nil
    capture?.stopRunning()
    capture = nil
    audioRequest = UUID()
  }
  private func startCamera() {
    AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
      DispatchQueue.main.async {
        guard let self else { return }
        guard allowed else {
          self.message = "システム設定でカメラの使用を許可してください"
          return
        }
        do {
          guard let device = AVCaptureDevice.default(for: .video) else {
            self.message = "カメラが接続されていません"
            return
          }
          let session = AVCaptureSession()
          session.sessionPreset = .hd1920x1080
          let deviceInput = try AVCaptureDeviceInput(device: device)
          session.addInput(deviceInput)
          let output = AVCaptureVideoDataOutput()
          output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
          ]
          output.alwaysDiscardsLateVideoFrames = true
          output.setSampleBufferDelegate(
            self.cameraDelegate, queue: DispatchQueue(label: "kira.camera"))
          session.addOutput(output)
          self.capture = session
          DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
          self.message = device.localizedName
        } catch { self.message = error.localizedDescription }
      }
    }
  }
  private func tick() {
    guard windowVisible || recording || (serviceStatus["appFeedDemand"] as? Bool ?? false) else {
      player?.pause()
      return
    }
    if input == .file && playing && player?.rate == 0 && (duration <= 0 || playhead < duration) {
      player?.play()
    }
    if dirtyPreset && Date().timeIntervalSince(lastPresetSend) > 0.05 && connected {
      client.configure(preset, origin: "ui")
      dirtyPreset = false
      lastPresetSend = Date()
    }
    switch input {
    case .demo:
      guard connected, playing else { return }
      if let pixel = makeDemo(frame: frame) {
        _ = client.submitPixelBuffer(
          pixel, pts: UInt64(frame) * 1_000_000_000 / 30, source: "app-main",
          mode: integer("outputMode"))
        frame += 1
      }
    case .file:
      guard let player, let output = playerOutput else { return }
      let time = player.currentTime()
      playhead = max(0, CMTimeGetSeconds(time))
      if output.hasNewPixelBuffer(forItemTime: time),
        let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
      {
        guard let normalized = normalizer.normalize(pixel, transform: fileTransform) else {
          message = "映像をRec.709に変換できませんでした"
          return
        }
        _ = client.submitPixelBuffer(
          normalized,
          pts: UInt64(playhead * 1e9), source: "app-main", mode: integer("outputMode"))
      }
      var count = 0
      while let sample = nextAudio,
        CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) <= playhead, count < 12
      {
        if audioSource == "video", let block = CMSampleBufferGetDataBuffer(sample) {
          let n = CMBlockBufferGetDataLength(block)
          var data = Data(count: n)
          _ = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(
              block, atOffset: 0, dataLength: n, destination: $0.baseAddress!)
          }
          client.sendStereoAudio(
            data,
            pts: UInt64(
              max(0, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) * 1e9),
            source: "app-main")
        }
        nextAudio = audioOutput?.copyNextSampleBuffer()
        count += 1
      }
      if duration > 0 && playhead >= duration && playing {
        playing = false
        player.pause()
      }
    case .obs: client.requestPreview(selectedOBS, mode: integer("outputMode"))
    case .camera: break
    }
  }
  func refreshStatus() {
    client.connect()
    client.fetchStatus { [weak self] response in
      DispatchQueue.main.async {
        guard let self else { return }
        self.serviceStatus = response as? [String: Any] ?? [:]
        let online = self.connected
        if online && !self.lastConnected {
          self.client.configure(self.preset, origin: "reconnect")
          self.message = "Metalエンジンに接続しました"
        }
        if !online {
          self.message = "レンダーサービス未接続 · 接続ボタンで開始"
          self.surface = nil
        }
        let feed =
          self.windowVisible || self.recording
          || (self.serviceStatus["appFeedDemand"] as? Bool ?? false)
        if let capture = self.capture, capture.isRunning != feed {
          DispatchQueue.global(qos: .userInitiated).async {
            if feed { capture.startRunning() } else { capture.stopRunning() }
          }
        }
        if let selected = self.selectedOBSInstance { self.selectedOBS = selected.sourceID }
        self.lastConnected = online
        self.recording = self.serviceStatus["recording"] as? Bool ?? false
        if let error = self.serviceStatus["recordError"] as? String, !error.isEmpty {
          self.message = error
        }
      }
    }
    persist()
  }
  var obsInstances: [OBSInstance] {
    ((serviceStatus["obsInstances"] as? [[String: Any]]) ?? []).compactMap { d in
      guard let id = d["instanceID"] as? String else { return nil }
      return OBSInstance(
        id: id, name: d["name"] as? String ?? id, sourceID: d["sourceID"] as? String ?? "",
        targetUUID: d["targetUUID"] as? String ?? "", filter: d["filter"] as? Bool ?? false,
        audioMix: d["audioMix"] as? Int ?? 0)
    }.sorted { $0.name < $1.name }
  }
  var obsTargets: [OBSTarget] {
    var seen = Set<String>()
    return ((serviceStatus["obsSources"] as? [[String: Any]]) ?? []).compactMap { d in
      guard let id = d["uuid"] as? String, seen.insert(id).inserted else { return nil }
      return OBSTarget(id: id, name: d["name"] as? String ?? id)
    }.sorted { $0.name < $1.name }
  }
  var selectedOBSInstance: OBSInstance? { obsInstances.first { $0.id == obsInstanceID } }
  func selectOBSInstance(_ id: String) {
    obsInstanceID = id
    selectedOBS = selectedOBSInstance?.sourceID ?? ""
  }
  func routeOBS(_ changes: [String: Any]) {
    guard !obsInstanceID.isEmpty else { return }
    client.routeOBS(changes, instance: obsInstanceID)
  }
  func registerService() {
    do {
      let service = SMAppService.agent(plistName: "jp.meowkawaii.KiraRaki.render.plist")
      if service.status == .requiresApproval {
        SMAppService.openSystemSettingsLoginItems()
        message = "ログイン項目でKiraRakiを有効にしてください"
      } else {
        try service.register()
        message = "レンダーサービスを登録しました"
      }
      client.connect()
    } catch { message = error.localizedDescription }
  }
  func toggleRecording() {
    if recording {
      client.stopRecording { [weak self] result in
        DispatchQueue.main.async {
          self?.recording = false
          let d = result as? [String: Any] ?? [:]
          self?.message = (d["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "録画を保存しました"
        }
      }
      return
    }
    let panel = NSSavePanel()
    let ext = exportCodec == "h264" ? "mp4" : "mov"
    panel.allowedContentTypes = [UTType(filenameExtension: ext)!]
    panel.nameFieldStringValue =
      "KiraRaki-\(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-" )).\(ext)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let options: [String: Any] = [
      "path": url.path, "codec": exportCodec, "audio": audioSource != "none",
      "sourceID": input == .obs ? selectedOBS : "app-main",
      "inputPath": input == .file ? fileURL?.path ?? "" : "",
      "inputStartNS": UInt64(playhead * 1e9), "replayEnabled": true, "audioSource": audioSource,
    ]
    client.startRecording(options) { [weak self] result in
      DispatchQueue.main.async {
        let d = result as? [String: Any] ?? [:]
        self?.recording = d["recording"] as? Bool ?? false
        self?.message = d["error"] as? String ?? "録画中 · 操作ログと元映像を保存しています"
      }
    }
  }
  func exportMovie(replay: Bool = false) {
    guard exportProgress == nil else { return }
    var inputURL = fileURL
    var events: URL?
    var presetValues = preset
    if replay {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = true
      panel.message = "録画と同時に保存された .kirareplay フォルダを選択"
      guard panel.runModal() == .OK, let chosen = panel.url else { return }
      let folder = chosen.pathExtension == "json" ? chosen.deletingLastPathComponent() : chosen
      do {
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let source = manifest["inputPath"] as? String, !source.isEmpty,
          let saved = manifest["preset"] as? [String: Any]
        else {
          message = "再現用の入力映像が保存されていません"
          return
        }
        inputURL =
          source.hasPrefix("/")
          ? URL(fileURLWithPath: source) : folder.appendingPathComponent(source)
        presetValues = saved
        presetValues["outputMode"] = integer("outputMode")
        events = folder.appendingPathComponent("events.jsonl")
      } catch {
        message = error.localizedDescription
        return
      }
    }
    guard let source = inputURL else {
      message = "書き出す動画ファイルを選択してください"
      return
    }
    let panel = NSSavePanel()
    let ext = exportCodec == "h264" ? "mp4" : "mov"
    panel.allowedContentTypes = [UTType(filenameExtension: ext)!]
    panel.nameFieldStringValue =
      source.deletingPathExtension().lastPathComponent + "-KiraRaki." + ext
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    guard source.standardizedFileURL != destination.standardizedFileURL else {
      message = "元動画とは別の保存先を指定してください"
      return
    }
    let staging = destination.deletingLastPathComponent().appendingPathComponent(
      ".KiraRaki-" + UUID().uuidString + "." + ext)
    do {
      let presetURL = support.appendingPathComponent("export-\(UUID().uuidString).json")
      try JSONSerialization.data(withJSONObject: presetValues).write(to: presetURL)
      let process = Process()
      process.executableURL = Bundle.main.bundleURL.appendingPathComponent(
        "Contents/MacOS/KiraRakiCLI")
      var args = [
        "export", "--input", source.path, "--output", staging.path, "--preset", presetURL.path,
        "--shader", Bundle.main.url(forResource: "Effects", withExtension: "metal")!.path,
        "--codec", exportCodec, "--mode", String(integer("outputMode")),
      ]
      if audioSource == "none" { args += ["--mute"] }
      if let events { args += ["--events", events.path] }
      process.arguments = args
      let pipe = Pipe()
      let output = ExportOutputBuffer()
      process.standardOutput = pipe
      process.standardError = pipe
      pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
        let data = h.availableData
        guard !data.isEmpty else {
          h.readabilityHandler = nil
          return
        }
        for progress in output.consume(data) {
          DispatchQueue.main.async {
            guard self?.exporting === process else { return }
            self?.exportProgress = progress
          }
        }
      }
      process.terminationHandler = { [weak self] p in
        pipe.fileHandleForReading.readabilityHandler = nil
        var success = p.terminationStatus == 0
        var error = output.message
        if success {
          do {
            if FileManager.default.fileExists(atPath: destination.path) {
              _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
              try FileManager.default.moveItem(at: staging, to: destination)
            }
          } catch let failure {
            success = false
            error = failure.localizedDescription
          }
        }
        if !success { try? FileManager.default.removeItem(at: staging) }
        try? FileManager.default.removeItem(at: presetURL)
        DispatchQueue.main.async {
          self?.exportProgress = nil
          self?.exporting = nil
          self?.message = success ? "書き出しが完了しました" : (error.isEmpty ? "書き出しを中断しました" : error)
          if success { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        }
      }
      exportProgress = 0
      exporting = process
      try process.run()
      message = "高品質オフラインレンダリング中"
    } catch {
      exportProgress = nil
      exporting = nil
      message = error.localizedDescription
    }
  }
  func cancelExport() { exporting?.terminate() }
  private func handleMIDI(_ key: String, _ value: Double) {
    if midi.learning {
      midi.bind(key, target: midiLearnTarget)
      message = "MIDI割当: \(key) → \(midiLearnTarget)"
      return
    }
    guard let target = midi.bindings[key] else { return }
    let bounds: [String: ClosedRange<Double>] = [
      "lineWidth": 0.5...18, "distortion": 0...1, "density": 0...1, "threshold": 0.01...0.5,
      "glow": 0...2, "trailHalfLife": 0...1, "hueOffset": 0...1, "hueSpeed": 0...0.5,
      "lifetime": 0.05...3, "updateHz": 0.1...30,
      "strokeLength": 60...900, "jaggedSpacing": 8...180, "motionResponse": 0...1,
      "irregularity": 0...1,
    ]
    if target == "enabled" {
      set(target, value > 0.5, origin: "midi:\(key):\(Int(value*127))")
    } else if let range = bounds[target] {
      set(
        target, range.lowerBound + (range.upperBound - range.lowerBound) * value,
        origin: "midi:\(key):\(Int(value*127))")
    }
  }
}

private struct SeededRandom {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func nextDouble() -> Double {
    state &+= 0x9e37_79b9_7f4a_7c15
    var z = state
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return Double((z ^ (z >> 31)) >> 11) / 9_007_199_254_740_992
  }
}
final class CameraDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  var onBuffer: ((CVPixelBuffer, UInt64) -> Void)?
  func captureOutput(
    _ output: AVCaptureOutput, didOutput sample: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if let pixel = CMSampleBufferGetImageBuffer(sample) {
      onBuffer?(
        pixel,
        UInt64(max(0, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) * 1e9))
    }
  }
}
private let demoCI = CIContext(options: [.cacheIntermediates: false])
private func makeDemo(frame: Int) -> CVPixelBuffer? {
  let w = 1280
  let h = 720
  var pixel: CVPixelBuffer?
  CVPixelBufferCreate(
    kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
    [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel)
  guard let pixel else { return nil }
  CVPixelBufferLockBaseAddress(pixel, [])
  defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
  guard
    let context = CGContext(
      data: CVPixelBufferGetBaseAddress(pixel), width: w, height: h, bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
      space: CGColorSpace(name: CGColorSpace.itur_709)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)
  else { return nil }
  let t = Double(frame) / 30
  context.setFillColor(CGColor(red: 0.035, green: 0.045, blue: 0.075, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: w, height: h))
  context.setStrokeColor(CGColor(gray: 0.14, alpha: 1))
  context.setLineWidth(1)
  for i in stride(from: 0, to: w, by: 60) {
    context.move(to: CGPoint(x: i, y: 0))
    context.addLine(to: CGPoint(x: i, y: h))
  }
  for i in stride(from: 0, to: h, by: 60) {
    context.move(to: CGPoint(x: 0, y: i))
    context.addLine(to: CGPoint(x: w, y: i))
  }
  context.strokePath()
  context.saveGState()
  context.translateBy(x: 650 + sin(t * 0.6) * 65, y: 370)
  context.rotate(by: sin(t * 0.3) * 0.12)
  context.setFillColor(CGColor(red: 0.25, green: 0.31, blue: 0.38, alpha: 1))
  context.setStrokeColor(CGColor(red: 0.75, green: 0.82, blue: 0.87, alpha: 1))
  context.setLineWidth(3)
  let head = CGRect(x: -65, y: 85, width: 130, height: 150)
  context.fillEllipse(in: head)
  context.strokeEllipse(in: head)
  let body = CGMutablePath()
  body.move(to: CGPoint(x: -80, y: 70))
  body.addCurve(
    to: CGPoint(x: -140, y: -180), control1: CGPoint(x: -150, y: 20),
    control2: CGPoint(x: -120, y: -130))
  body.addLine(to: CGPoint(x: 150, y: -180))
  body.addCurve(
    to: CGPoint(x: 80, y: 70), control1: CGPoint(x: 130, y: -120), control2: CGPoint(x: 140, y: 30))
  body.closeSubpath()
  context.addPath(body)
  context.drawPath(using: .fillStroke)
  for i in 0..<10 {
    let y = Double(i) * 19 - 155
    context.move(to: CGPoint(x: -90, y: y))
    context.addCurve(
      to: CGPoint(x: 100, y: y), control1: CGPoint(x: -25, y: y + sin(t + Double(i)) * 18),
      control2: CGPoint(x: 55, y: y - 20))
    context.strokePath()
  }
  context.strokeEllipse(in: CGRect(x: -38, y: 160, width: 14, height: 11))
  context.strokeEllipse(in: CGRect(x: 26, y: 160, width: 14, height: 11))
  context.move(to: CGPoint(x: -25, y: 125))
  context.addQuadCurve(to: CGPoint(x: 30, y: 125), control: CGPoint(x: 0, y: 108))
  context.strokePath()
  context.restoreGState()
  context.saveGState()
  context.translateBy(x: 280, y: 350)
  context.rotate(by: t * 0.2)
  context.setStrokeColor(CGColor(gray: 0.65, alpha: 1))
  context.setLineWidth(3)
  for i in 0..<5 {
    let d = Double(i) * 24
    context.stroke(CGRect(x: -80 - d / 2, y: -80 - d / 2, width: 160 + d, height: 160 + d))
  }
  context.restoreGState()
  context.setStrokeColor(CGColor(gray: 0.7, alpha: 1))
  for i in 0..<3 {
    let r = 30 + Double(i) * 26
    context.strokeEllipse(
      in: CGRect(x: 1020 - r, y: 310 + sin(t + Double(i)) * 40 - r, width: r * 2, height: r * 2))
  }
  return pixel
}

private func checkedPreset(_ value: [String: Any]) throws -> [String: Any] {
  var error: NSError?
  guard let result = KRValidatePreset(value, &error) as? [String: Any] else {
    throw error
      ?? NSError(domain: "KiraRaki", code: 1, userInfo: [NSLocalizedDescriptionKey: "プリセットが不正です"])
  }
  return result
}

private final class ExportOutputBuffer {
  private let lock = NSLock()
  private var pending = Data()
  private var errors = [String]()
  func consume(_ data: Data) -> [Double] {
    lock.lock()
    defer { lock.unlock() }
    pending.append(data)
    var progress = [Double]()
    while let newline = pending.firstIndex(of: 10) {
      let line = pending.prefix(upTo: newline)
      pending.removeSubrange(...newline)
      if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let value = object["progress"] as? Double
      {
        progress.append(value)
      } else if let text = String(data: line, encoding: .utf8), !text.isEmpty {
        errors.append(text)
        if errors.count > 25 { errors.removeFirst() }
      }
    }
    if pending.count > 1_000_000 { pending.removeAll() }
    return progress
  }
  var message: String {
    lock.lock()
    defer { lock.unlock() }
    return errors.suffix(5).joined(separator: "\n")
  }
}

private final class FrameNormalizer {
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let color = CGColorSpace(name: CGColorSpace.itur_709)!
  private var pool: CVPixelBufferPool?
  private var dimensions = CGSize.zero
  func normalize(_ pixel: CVPixelBuffer, transform: CGAffineTransform = .identity) -> CVPixelBuffer?
  {
    var image = CIImage(cvPixelBuffer: pixel).transformed(by: transform)
    let extent = image.extent
    image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    let size = CGSize(width: extent.width.rounded(), height: extent.height.rounded())
    guard size.width > 0, size.height > 0, size.width <= 7680, size.height <= 4320 else {
      return nil
    }
    if size != dimensions || pool == nil {
      dimensions = size
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ]
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    }
    guard let pool else { return nil }
    var result: CVPixelBuffer?
    guard
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &result) == kCVReturnSuccess,
      let result
    else { return nil }
    context.render(image, to: result, bounds: CGRect(origin: .zero, size: size), colorSpace: color)
    CVBufferSetAttachment(
      result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
      .shouldPropagate)
    CVBufferSetAttachment(
      result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
      .shouldPropagate)
    CVBufferSetAttachment(
      result, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
      .shouldPropagate)
    return result
  }
}
