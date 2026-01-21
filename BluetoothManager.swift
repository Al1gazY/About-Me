//
//  BluetoothManager.swift
//  Healthsign
//
//  Created by Zhifu Ge on 2021-05-24.
//  Copyright © 2021 Zhifu Ge. All rights reserved.
//

import CoreBluetooth

protocol BluetoothManagerDelegate: AnyObject {
    func getCurrentPeripheral() -> CBPeripheral?
    func addPeripheral(_ peripheral: CBPeripheral)
    func removePeripheral(_ peripheral: CBPeripheral)
    func update(_ result: CLSFeatureResult)
    func append(reading: CLSReading)
    func append(measuredTmp: Double, reportedTmp: Double)
    func append(batteryInfo: BatteryInfo)
    func insert(deviceInfo: DeviceInfoItem)
    func stopThreshold()
}

// MARK: - BluetoothManager -
final class BluetoothManager: NSObject {
    private let centralManager: CBCentralManager
    private var clsCharacteristic: CBCharacteristic?
    private var tmpCharacteristic: CBCharacteristic?
    private var clsFeatureCharacteristic: CBCharacteristic?


    private var clsSaveFeatureCompletion: ((Error?) -> ())?
    private var clsGetFeatureCompletion: ((Error?) -> ())?
    private var clsStreamFeatureCompletion: ((Error?) -> ())?
    private var clsBrightnessFeatureCompletion: ((Error?) -> ())?
    private var clsGainControlFeatureCompletion: ((Error?) -> ())?

    weak var delegate: BluetoothManagerDelegate?

    private var currentStream: StreamType = .CLS

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func startScanningIfNeeded() {
        guard centralManager.state == .poweredOn else { return }
        if !centralManager.isScanning {
            centralManager.scanForPeripherals(
                withServices: Constants.requiredServices,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }
    }

    override init() {
        self.centralManager = CBCentralManager()
        super.init()
    }
}

// MARK: - API
extension BluetoothManager {
    func scanForPeripherals() {
        centralManager.delegate = self
    }

    func disconnect(peripheral: CBPeripheral) {
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func connect(peripheral: CBPeripheral) {
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanningIfNeeded()
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        onMain { [weak self] in self?.delegate?.addPeripheral(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(Constants.requiredServices)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        onMain { [weak self] in self?.delegate?.removePeripheral(peripheral) }
        startScanningIfNeeded()
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            return
        }

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let characteristics = service.characteristics else {
            return
        }

        for characteristic in characteristics {
            if characteristic.uuid == Constants.clsCharacteristicUUID {
                clsCharacteristic = characteristic
            }

            if characteristic.uuid == Constants.currentTemperatureCharacteristicUUID {
                tmpCharacteristic = characteristic
            }

            if characteristic.uuid == Constants.clsFeatureCharacteristicUUID {
                clsFeatureCharacteristic = characteristic
                getCLSFeatureValue { error in }
            }

            if characteristic.uuid == Constants.thermometerLocationCharacteristicUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }

            if characteristic.uuid == Constants.batteryLevelCharacteristicUUID {
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            }

            if Constants.deviceInfoCharacteristicUUIDs.contains(characteristic.uuid) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }

        if characteristic.uuid == Constants.clsCharacteristicUUID {
            print("RX CLS Data: \(data.hexEncodedString())")

            let transmitEnabled = Store.shared.transmitEnabled
            //guard let clsReading = CLSReading(data, transmitEnabled: transmitEnabled, transmitThousandHzEnabled: Store.shared.transmitThousandHzEnabled) else { return }
            let transmitThousandHzEnabled = Store.shared.transmitThousandHzEnabled
            guard let clsReading = CLSReading(
                data,
                transmitEnabled: transmitEnabled,
                transmitThousandHzEnabled: transmitThousandHzEnabled,
                currentStream: self.currentStream
            ) else { return }
            let motionDetectionEnabled = UserDefaults.standard.bool(forKey: "motionDetectionEnabled")

            let aclThreshold = UserDefaults.standard.double(forKey: "aclThreshold")
            if let aclReading = clsReading.aclReading, motionDetectionEnabled, aclReading.R > aclThreshold {
                onMain { [weak self] in self?.delegate?.stopThreshold() }
            } else {
                onMain { [weak self] in self?.delegate?.append(reading: clsReading) }
            }

        } else if characteristic.uuid == Constants.currentTemperatureCharacteristicUUID {
            // Flags (bit0: 0 = Celsius, 1 = Fahrenheit)
            guard data.count >= 5 else { return }
            let flags = data[0]
            let isFahrenheit = (flags & 0x01) == 0x01

            // IEEE-11073 32-bit float at offset 1 (little-endian):
            // bytes 1..3 = mantissa (24-bit two’s complement), byte 4 = exponent (8-bit two’s complement)
            let m0 = UInt32(data[1])
            let m1 = UInt32(data[2]) << 8
            let m2 = UInt32(data[3]) << 16
            var mantissaBits = (m0 | m1 | m2) & 0x00FF_FFFF // 24‑bit mantissa
            if (mantissaBits & 0x0080_0000) != 0 {
                mantissaBits |= 0xFF00_0000 // sign‑extend to 32 bits
            }
            let mantissa = Int32(bitPattern: mantissaBits)
            let exponent = Int32(Int8(bitPattern: data[4]))
            let value = Double(mantissa) * pow(10.0, Double(exponent))

            // Convert to °C if device sent °F
            let rawMeasuredC: Double = isFahrenheit ? ((value - 32.0) * (5.0/9.0)) : value

            // Apply Settings → Temperature Calibration (if enabled for the selected device)
            let calibratedMeasuredC = Store.shared.applyTempCalibrationIfEnabled(to: rawMeasuredC)

            // Reported is computed from the calibrated measured temperature
            let reportedC = DataFunctions.reportedTmp(for: calibratedMeasuredC)

            onMain { [weak self] in
                self?.delegate?.append(measuredTmp: calibratedMeasuredC, reportedTmp: reportedC)
            }
        } else if characteristic.uuid == Constants.clsFeatureCharacteristicUUID {
            guard data.count == 12 else { return }
            let result = CLSFeatureResult(data)
            onMain { [weak self] in self?.delegate?.update(result) }
        } else if characteristic.uuid == Constants.batteryLevelCharacteristicUUID {
            guard data.count > 2 else { return }
            let vBat = Int(data[2]) << 8 + Int(data[1])
            let vPercent = Int(data[0])
            let voltage = Double(vBat) * (79.0/59.0) * (3.6/16383)
            onMain { [weak self] in self?.delegate?.append(batteryInfo: BatteryInfo(level: vPercent, voltage: voltage)) }
        } else if let valueString = String(data: data, encoding: .utf8) {
            let priority: Int
            switch characteristic.uuid {
            case Constants.manufacturerNameCharacteristicUUID:
                priority = 0
            case Constants.modelNumberCharacteristicUUID:
                priority = 1
            case Constants.serialNumberCharacteristicUUID:
                priority = 2
            case Constants.hardwareRevisionCharacteristicUUID:
                priority = 3
            case Constants.firmwareRevisionCharacteristicUUID:
                priority = 4
            default:
                priority = .max
            }

            let deviceInfo = DeviceInfoItem(
                name: characteristic.uuid.description
                    .replacingOccurrences(of: "String", with: "")
                    .trimmingCharacters(in: .whitespaces),
                value: valueString,
                priority: priority
            )
            onMain { [weak self] in self?.delegate?.insert(deviceInfo: deviceInfo) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            //print("peripheral:didWriteValueFor:characteristic", error)
        }

        guard characteristic == clsFeatureCharacteristic else { return }
        //print(characteristic)

        clsGetFeatureCompletion?(error)
        clsGetFeatureCompletion = nil

        clsSaveFeatureCompletion?(error)
        clsSaveFeatureCompletion = nil

        clsStreamFeatureCompletion?(error)
        clsStreamFeatureCompletion = nil

        clsBrightnessFeatureCompletion?(error)
        clsBrightnessFeatureCompletion = nil

        clsGainControlFeatureCompletion?(error)
        clsGainControlFeatureCompletion = nil
    }
}

extension BluetoothManager {
    func setTemperatureCharacteristic(notifying: Bool) {
        guard
            let peripheral = delegate?.getCurrentPeripheral(),
            let tmpCharacteristic = self.tmpCharacteristic
        else {
            return
        }

        peripheral.setNotifyValue(notifying, for: tmpCharacteristic)
    }

    func setClsCharacteristic(notifying: Bool) {
        guard
            let peripheral = delegate?.getCurrentPeripheral(),
            let clsCharacteristic = clsCharacteristic
        else {
            return
        }

        peripheral.setNotifyValue(notifying, for: clsCharacteristic)
    }

    func getCLSFeatureValue(completion: @escaping(Error?) -> ()) {
        guard
            let peripheral = delegate?.getCurrentPeripheral(),
            let clsFeatureCharacteristic = clsFeatureCharacteristic
        else {
            completion(NSError(domain: "Something went wrong", code: 0))
            return
        }

        //print(clsFeatureCharacteristic)
        clsGetFeatureCompletion = completion
        peripheral.writeValue(CLSFeature.readData, for: clsFeatureCharacteristic, type: .withResponse)
        peripheral.readValue(for: clsFeatureCharacteristic)
    }

    func saveCLSFeatureValue(completion: @escaping(Error?) -> ()) {
        guard
            let peripheral = delegate?.getCurrentPeripheral(),
            let clsFeatureCharacteristic = clsFeatureCharacteristic
        else {
            completion(NSError(domain: "Something went wrong", code: 0))
            return
        }

        //print(clsFeatureCharacteristic)
        clsSaveFeatureCompletion = completion
        peripheral.writeValue(CLSFeature.saveData, for: clsFeatureCharacteristic, type: .withResponse)
    }

    func setClsStream(_ stream: StreamType, sampleRate: SamplingHz, save: Bool, completion: @escaping(Error?) -> ()) {
        guard
            let peripheral = delegate?.getCurrentPeripheral(),
            let clsFeatureCharacteristic = clsFeatureCharacteristic
        else {
            completion(NSError(domain: "Something went wrong", code: 0))
            return
        }

        self.currentStream = stream

        clsStreamFeatureCompletion = completion
        let data = CLSFeature.setStreamControlData(stream, sampleRate: sampleRate, save: save)
        peripheral.writeValue(data, for: clsFeatureCharacteristic, type: .withResponse)
    }

    func stopClsStream() {
        clsStreamFeatureCompletion = nil
    }

    func setClsBrightness(auto: Bool, grn1: UInt8, ylw: UInt8, grn2: UInt8, grn3: UInt8, save: Bool, completion: @escaping(Error?) -> ()) {
        guard
            let peripheral = delegate?.getCurrentPeripheral(),
            let clsFeatureCharacteristic = clsFeatureCharacteristic
        else {
            completion(NSError(domain: "Something went wrong", code: 0))
            return
        }

        clsBrightnessFeatureCompletion = completion
        let data = CLSFeature.setBrightnessControlData(auto: auto, grn1: grn1, ylw: ylw, grn2: grn2, grn3: grn3, save: save)
        peripheral.writeValue(data, for: clsFeatureCharacteristic, type: .withResponse)
    }

    func setClsGainControl(auto: Bool, grn1: UInt8, ylw: UInt8, grn2: UInt8, grn3: UInt8, save: Bool, completion: @escaping(Error?) -> ()) {
        guard
            let peripheral = delegate?.getCurrentPeripheral(),
            let clsFeatureCharacteristic = clsFeatureCharacteristic
        else {
            completion(NSError(domain: "Something went wrong", code: 0))
            return
        }

        clsGainControlFeatureCompletion = completion
        let data = CLSFeature.setGainControlData(auto: auto, grn1: grn1, ylw: ylw, grn2: grn2, grn3: grn3, save: save)
        peripheral.writeValue(data, for: clsFeatureCharacteristic, type: .withResponse)
    }
}

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}

// MARK: - Constants -
private enum Constants {
    // Device info
    static let deviceInformationServiceUUID = CBUUID(string: "180A")
    static let manufacturerNameCharacteristicUUID = CBUUID(string: "2A29")
    static let modelNumberCharacteristicUUID = CBUUID(string: "2A24")
    static let serialNumberCharacteristicUUID = CBUUID(string: "2A25")
    static let hardwareRevisionCharacteristicUUID = CBUUID(string: "2A27")
    static let firmwareRevisionCharacteristicUUID = CBUUID(string: "2A26")
    static var deviceInfoCharacteristicUUIDs: [CBUUID] {
        [
            manufacturerNameCharacteristicUUID,
            modelNumberCharacteristicUUID,
            serialNumberCharacteristicUUID,
            hardwareRevisionCharacteristicUUID,
            firmwareRevisionCharacteristicUUID
        ]
    }

    // HTS
    static let htsUUID = CBUUID(string: "1809")
    static let currentTemperatureCharacteristicUUID = CBUUID(string: "2A1C")
    static let thermometerLocationCharacteristicUUID = CBUUID(string: "2A1D")

    // CLS
    static let clsUUID = CBUUID(string: "FD2C")
    static let clsCharacteristicUUID = CBUUID(string: "2A5F")
    static let clsFeatureCharacteristicUUID = CBUUID(string: "2A60")

    // Radio test mode
    static let batteryServiceUUID = CBUUID(string: "180F")
    static let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")
    static let radioTestModeCharacteristicUUID = CBUUID(string: "2A21")

    static var requiredServices: [CBUUID] {
        [clsUUID, htsUUID, deviceInformationServiceUUID, batteryServiceUUID]
    }
}
