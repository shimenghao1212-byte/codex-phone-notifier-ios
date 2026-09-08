import AccessorySetupKit
import CoreBluetooth
import UIKit

/// One native session, with callbacks on the same queue as BluetoothReceiver.
/// No polling, periodic wake-ups, background audio, or persistent device database.
@available(iOS 18.0, *)
final class AccessorySetupCoordinator {
    private let session: ASAccessorySession?
    private(set) var authorization: AccessoryAuthorization
    var changed: (() -> Void)?
    var picked: ((UUID) -> Void)?
    var failed: ((String) -> Void)?
    private var pickedID: UUID?
    private var pickerRevision: UInt64 = 0
    private var waiters: [UUID: (CheckedContinuation<Bool, Never>, DispatchWorkItem)] = [:]

    init(centralAlreadyCreated: Bool = false) {
        authorization = AccessoryAuthorization(centralAlreadyCreated: centralAlreadyCreated)
        // Apple documents both spellings in different places. The actual iOS
        // framework checks the Kit spelling during init, before any callback.
        guard AccessoryAuthorization.supportsBluetooth(info: Bundle.main.infoDictionary ?? [:],
                  serviceUUID: BluetoothReceiver.serviceUUID.uuidString) else {
            session = nil
            authorization.invalidate()
            return
        }
        session = ASAccessorySession()
        #if DEBUG && targetEnvironment(simulator)
        NSLog("CodexStartup: native accessory session constructed")
        #endif
    }

    func activate() {
        guard let session else {
            failed?("安装包的蓝牙授权配置不完整，请安装修复版本。")
            changed?()
            return
        }
        session.activate(on: .main) { [weak self] event in self?.handle(event) }
    }

    @MainActor
    func waitUntilReady() async -> Bool {
        if authorization.phase != .loading { return authorization.phase == .ready }
        // Only a user-triggered control action waits. This deadline is canceled on activation;
        // it is not a reconnect/keepalive timer and never repeats while the phone is idle.
        guard waiters.count < 4 else { return false }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            let timeout = DispatchWorkItem { [weak self] in self?.finishWaiter(id, ready: false) }
            waiters[id] = (continuation, timeout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
        }
    }

    func claimCentral(for id: UUID?) -> Bool { authorization.claimCentral(for: id) }

    func showPicker(selected: UUID?, name: String) {
        guard let session else { return }
        guard UIApplication.shared.applicationState == .active else {
            failed?("请在 App 内完成一次电脑授权。"); return
        }
        guard authorization.beginPicker(selected: selected) else { return }
        pickerRevision &+= 1
        let revision = pickerRevision
        pickedID = nil
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = BluetoothReceiver.serviceUUID
        descriptor.supportedOptions = [.bluetoothPairingLE]
        guard let artwork = UIImage(named: "CodexMark") ?? UIImage(systemName: "desktopcomputer") else {
            authorization.finishPicker(); changed?(); return
        }
        let item: ASPickerDisplayItem
        if let id = authorization.migrationID {
            let migration = ASMigrationDisplayItem(name: String(name.prefix(80)), productImage: artwork,
                                                   descriptor: descriptor)
            migration.peripheralIdentifier = id
            item = migration
        } else {
            item = ASPickerDisplayItem(name: "Codex 电脑", productImage: artwork, descriptor: descriptor)
        }
        changed?()
        session.showPicker(for: [item]) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.pickerRevision == revision else { return }
                // Successful selection is handled by events. On failure there may be no
                // pickerDidDismiss, so always release the gate without starting Bluetooth.
                if let error {
                    self.pickedID = nil
                    self.authorization.finishPicker()
                    self.failed?("电脑授权未完成：\(error.localizedDescription)")
                    self.changed?()
                }
            }
        }
    }

    private func finishWaiter(_ id: UUID, ready: Bool) {
        guard let (continuation, timeout) = waiters.removeValue(forKey: id) else { return }
        timeout.cancel()
        continuation.resume(returning: ready)
    }

    private func refresh() {
        guard let session else { return }
        authorization.refresh(session.accessories.compactMap { accessory in
            guard accessory.state == .authorized,
                  accessory.descriptor.bluetoothServiceUUID == BluetoothReceiver.serviceUUID,
                  let id = accessory.bluetoothIdentifier else { return nil }
            return AccessoryAuthorization.Computer(id: id, name: accessory.displayName)
        })
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            refresh()
            for id in Array(waiters.keys) { finishWaiter(id, ready: true) }
        case .accessoryAdded, .accessoryChanged, .accessoryRemoved:
            refresh()
            if authorization.pickerActive, event.eventType == .accessoryAdded,
               let accessory = event.accessory, accessory.state == .authorized,
               accessory.descriptor.bluetoothServiceUUID == BluetoothReceiver.serviceUUID {
                pickedID = accessory.bluetoothIdentifier
            }
        case .migrationComplete:
            // Wait for this explicit event, not an earlier accessoryAdded event.
            let migrating = authorization.migrationID
            authorization.migrationCompleted()
            refresh()
            if authorization.permits(migrating) { pickedID = migrating }
        case .pickerDidDismiss:
            authorization.finishPicker()
            if let id = pickedID, authorization.permits(id) { picked?(id) }
            pickedID = nil
        case .invalidated:
            authorization.invalidate()
            for id in Array(waiters.keys) { finishWaiter(id, ready: false) }
            failed?("系统配件服务暂时不可用，请重新打开 App。")
        default: break
        }
        changed?()
    }
}
