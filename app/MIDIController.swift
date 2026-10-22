import Combine
import CoreMIDI
import Foundation

final class MIDIController: ObservableObject {
  @Published var learning = false
  @Published var deviceNames = [String]()
  @Published var lastEvent = "MIDI待機中"
  @Published var bindings: [String: String] =
    UserDefaults.standard.dictionary(forKey: "midiBindings") as? [String: String] ?? [:]
  var onControl: ((String, Double) -> Void)?
  private var client = MIDIClientRef(), port = MIDIPortRef()
  private var sources = Set<MIDIEndpointRef>()
  private var running: UInt8 = 0, data = [UInt8]()
  init() {
    MIDIClientCreateWithBlock("KiraRaki" as CFString, &client) { [weak self] _ in
      DispatchQueue.main.async { self?.connectSources() }
    }
    MIDIInputPortCreateWithBlock(client, "KiraRaki Controls" as CFString, &port) {
      [weak self] list, _ in self?.read(list)
    }
    connectSources()
  }
  private func connectSources() {
    var names = [String]()
    var current = Set<MIDIEndpointRef>()
    for i in 0..<MIDIGetNumberOfSources() {
      let source = MIDIGetSource(i)
      current.insert(source)
      if !sources.contains(source) { MIDIPortConnectSource(port, source, nil) }
      var name: Unmanaged<CFString>?
      MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name)
      names.append(name?.takeRetainedValue() as String? ?? "MIDI \(i+1)")
    }
    for old in sources.subtracting(current) { MIDIPortDisconnectSource(port, old) }
    sources = current
    deviceNames = names
  }
  private func read(_ list: UnsafePointer<MIDIPacketList>) {
    let offset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
    var packet = UnsafeRawPointer(list).advanced(by: offset).assumingMemoryBound(
      to: MIDIPacket.self)
    for _ in 0..<list.pointee.numPackets {
      let start = UnsafeRawPointer(packet).advanced(
        by: MemoryLayout<MIDIPacket>.offset(of: \.data)!
      ).assumingMemoryBound(to: UInt8.self)
      for b in UnsafeBufferPointer(start: start, count: Int(packet.pointee.length)) {
        if b >= 0xf8 { continue }
        if b & 0x80 != 0 {
          running = b
          data.removeAll()
          continue
        }
        guard running >= 0x80 && running < 0xf0 else { continue }
        data.append(b)
        let status = running & 0xf0
        let needed = status == 0xc0 || status == 0xd0 ? 1 : 2
        if data.count == needed {
          if status == 0xb0 || status == 0x90 || status == 0x80 {
            let key = "\(status == 0xb0 ? "CC" : "Note"):\(Int(running & 15)+1):\(data[0])"
            let value = status == 0x80 ? 0 : Double(data[1]) / 127
            DispatchQueue.main.async { [weak self] in self?.lastEvent = "\(key)  \(Int(value*127))"
            }
            onControl?(key, value)
          }
          data.removeAll()
        }
      }
      packet = UnsafePointer(MIDIPacketNext(packet))
    }
  }
  func bind(_ key: String, target: String) {
    bindings[key] = target
    learning = false
    UserDefaults.standard.set(bindings, forKey: "midiBindings")
  }
  func clearBindings() {
    bindings.removeAll()
    UserDefaults.standard.removeObject(forKey: "midiBindings")
  }
  deinit {
    MIDIPortDispose(port)
    MIDIClientDispose(client)
  }
}
