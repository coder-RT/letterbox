import CoreBluetooth
import Foundation
import LetterboxDomain
import LetterboxMesh
import LetterboxWire
import os

/// CoreBluetooth adapter for the mesh `LinkLayer` port.
///
/// Every device plays both roles at once:
///  - Peripheral: advertises Letterbox's service and exposes one characteristic.
///    Neighbours write frames to it; we notify frames to subscribed neighbours.
///  - Central: scans for that service, connects, subscribes to notifications,
///    and writes frames to the remote characteristic.
///
/// All CoreBluetooth state is confined to one serial queue, which is what makes
/// the `@unchecked Sendable` sound. Frames are chunked per link to fit the MTU and
/// queued with backpressure (`canSendWriteWithoutResponse` / `updateValue == false`).
public final class BLELinkLayer: NSObject, LinkLayer, @unchecked Sendable {
    /// Letterbox's own network. Devices running other apps never see these.
    nonisolated(unsafe) public static let serviceUUID = CBUUID(string: "0F0E3639-A3D4-4987-91B4-B820B92F58C2")
    nonisolated(unsafe) public static let characteristicUUID = CBUUID(string: "A8A91EB3-9188-420C-8CCA-F5DD018BABAD")

    private static let maxCentralLinks = 8
    /// Chunks waiting per outgoing link, and in total for notifications (SEC-08). A slow
    /// or flooded link drops new frames instead of growing memory without limit.
    private static let maxQueuedWriteChunks = 1024
    private static let maxQueuedNotifyChunks = 4096
    private static let minimumRSSI = -92

    public let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let queue = DispatchQueue(label: "app.letterbox.ble", qos: .userInitiated)
    private let log = Logger(subsystem: "app.letterbox", category: "ble")

    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var localCharacteristic: CBMutableCharacteristic?

    // Central role: remote peripherals we connected to.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var remoteCharacteristics: [UUID: CBCharacteristic] = [:]
    private var writeQueues: [UUID: [Data]] = [:]

    // Peripheral role: remote centrals subscribed to us.
    private var subscribers: [UUID: CBCentral] = [:]
    private var notifyQueue: [(chunk: Data, central: CBCentral)] = []

    private var reassemblers: [LinkID: FrameReassembler] = [:]
    private var nextFrameID: UInt16 = 0
    private var started = false

    public override init() {
        (events, continuation) = AsyncStream.makeStream(of: LinkEvent.self, bufferingPolicy: .bufferingNewest(1024))
        super.init()
    }

    // MARK: - LinkLayer

    public func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            self.centralManager = CBCentralManager(delegate: self, queue: self.queue)
            self.peripheralManager = CBPeripheralManager(delegate: self, queue: self.queue)
        }
    }

    public func stop() {
        queue.async {
            guard self.started else { return }
            self.started = false
            self.centralManager?.stopScan()
            for peripheral in self.peripherals.values {
                self.centralManager?.cancelPeripheralConnection(peripheral)
            }
            self.peripheralManager?.stopAdvertising()
            self.peripheralManager?.removeAllServices()
            self.peripherals.removeAll()
            self.remoteCharacteristics.removeAll()
            self.subscribers.removeAll()
            self.writeQueues.removeAll()
            self.notifyQueue.removeAll()
            self.reassemblers.removeAll()
        }
    }

    public func send(_ frame: Data, to link: LinkID) {
        queue.async { self.enqueue(frame, to: link) }
    }

    public func broadcast(_ frame: Data, excluding link: LinkID?) {
        queue.async {
            for id in self.allLinkIDs where id != link {
                self.enqueue(frame, to: id)
            }
        }
    }

    // MARK: - Link bookkeeping (queue only)

    private enum Link {
        case outgoing(UUID) // we are central, they are a peripheral
        case incoming(UUID) // they are central, subscribed to us

        init?(_ id: LinkID) {
            let parts = id.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let uuid = UUID(uuidString: String(parts[1])) else { return nil }
            switch parts[0] {
            case "c": self = .outgoing(uuid)
            case "p": self = .incoming(uuid)
            default: return nil
            }
        }

        var id: LinkID {
            switch self {
            case let .outgoing(uuid): "c:\(uuid.uuidString)"
            case let .incoming(uuid): "p:\(uuid.uuidString)"
            }
        }
    }

    private var allLinkIDs: [LinkID] {
        remoteCharacteristics.keys.map { Link.outgoing($0).id } + subscribers.keys.map { Link.incoming($0).id }
    }

    private func makeFrameID() -> UInt16 {
        nextFrameID &+= 1
        return nextFrameID
    }

    private func enqueue(_ frame: Data, to linkID: LinkID) {
        switch Link(linkID) {
        case let .outgoing(uuid):
            guard let peripheral = peripherals[uuid], remoteCharacteristics[uuid] != nil else { return }
            let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
            let chunks = LinkFramer.chunks(for: frame, frameID: makeFrameID(), mtu: mtu)
            guard (writeQueues[uuid]?.count ?? 0) + chunks.count <= Self.maxQueuedWriteChunks else {
                log.debug("write queue full, frame dropped")
                return
            }
            writeQueues[uuid, default: []].append(contentsOf: chunks)
            drainWrites(to: peripheral)
        case let .incoming(uuid):
            guard let central = subscribers[uuid] else { return }
            let chunks = LinkFramer.chunks(for: frame, frameID: makeFrameID(), mtu: central.maximumUpdateValueLength)
            guard notifyQueue.count + chunks.count <= Self.maxQueuedNotifyChunks else {
                log.debug("notify queue full, frame dropped")
                return
            }
            notifyQueue.append(contentsOf: chunks.map { ($0, central) })
            drainNotifications()
        case nil:
            return
        }
    }

    private func drainWrites(to peripheral: CBPeripheral) {
        let uuid = peripheral.identifier
        guard let characteristic = remoteCharacteristics[uuid] else { return }
        while peripheral.canSendWriteWithoutResponse, var pending = writeQueues[uuid], !pending.isEmpty {
            let chunk = pending.removeFirst()
            writeQueues[uuid] = pending
            peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
        }
    }

    private func drainNotifications() {
        guard let manager = peripheralManager, let characteristic = localCharacteristic else { return }
        while let next = notifyQueue.first {
            guard subscribers[next.central.identifier] != nil else {
                notifyQueue.removeFirst() // Unsubscribed meanwhile.
                continue
            }
            guard manager.updateValue(next.chunk, for: characteristic, onSubscribedCentrals: [next.central]) else {
                return // Transmit queue full; resumes in peripheralManagerIsReady.
            }
            notifyQueue.removeFirst()
        }
    }

    private func receiveChunk(_ chunk: Data, on linkID: LinkID) {
        var reassembler = reassemblers[linkID] ?? FrameReassembler()
        let frame = reassembler.accept(chunk)
        reassemblers[linkID] = reassembler
        if let frame { continuation.yield(.frame(frame, from: linkID)) }
    }

    private func linkDown(_ link: Link) {
        reassemblers[link.id] = nil
        continuation.yield(.down(link.id))
    }

    private func radioState(_ state: CBManagerState) -> RadioState {
        switch state {
        case .poweredOn: .ready
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        default: .unknown
        }
    }

    private func startScanning() {
        guard let central = centralManager, central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])
    }
}

// MARK: - Central role

extension BLELinkLayer: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        continuation.yield(.radio(radioState(central.state)))
        if central.state == .poweredOn {
            startScanning()
        } else {
            for uuid in remoteCharacteristics.keys { linkDown(.outgoing(uuid)) }
            peripherals.removeAll()
            remoteCharacteristics.removeAll()
            writeQueues.removeAll()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard started, peripherals[peripheral.identifier] == nil,
              peripherals.count < Self.maxCentralLinks,
              RSSI.intValue >= Self.minimumRSSI, RSSI.intValue != 127
        else { return }
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        peripherals[peripheral.identifier] = nil
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let uuid = peripheral.identifier
        peripherals[uuid] = nil
        writeQueues[uuid] = nil
        if remoteCharacteristics.removeValue(forKey: uuid) != nil {
            linkDown(.outgoing(uuid))
        }
        startScanning()
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.characteristicUUID], for: service)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.characteristicUUID }) else {
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        remoteCharacteristics[peripheral.identifier] = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
        log.debug("link up (central) \(peripheral.identifier, privacy: .public)")
        continuation.yield(.up(Link.outgoing(peripheral.identifier).id))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        receiveChunk(value, on: Link.outgoing(peripheral.identifier).id)
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainWrites(to: peripheral)
    }
}

// MARK: - Peripheral role

extension BLELinkLayer: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            for uuid in subscribers.keys { linkDown(.incoming(uuid)) }
            subscribers.removeAll()
            notifyQueue.removeAll()
            localCharacteristic = nil
            return
        }
        guard started, localCharacteristic == nil else { return }
        let characteristic = CBMutableCharacteristic(
            type: Self.characteristicUUID,
            properties: [.writeWithoutResponse, .write, .notify],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        localCharacteristic = characteristic
        peripheral.add(service)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else {
            log.error("add service failed: \(error!.localizedDescription, privacy: .public)")
            return
        }
        // No local name: the advertisement carries only the service UUID.
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        subscribers[central.identifier] = central
        log.debug("link up (peripheral) \(central.identifier, privacy: .public)")
        continuation.yield(.up(Link.incoming(central.identifier).id))
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        if subscribers.removeValue(forKey: central.identifier) != nil {
            linkDown(.incoming(central.identifier))
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == Self.characteristicUUID, let value = request.value else { continue }
            receiveChunk(value, on: Link.incoming(request.central.identifier).id)
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drainNotifications()
    }
}
