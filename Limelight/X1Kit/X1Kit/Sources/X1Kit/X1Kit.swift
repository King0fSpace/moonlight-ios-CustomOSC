// X1Kit.swift
//
// This file is part of X1Kit, a swift framework for using the Citrix X1 mouse.
//
// Copyright (c) 2019 Adrian Carpenter
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// swiftlint:disable line_length

import CoreBluetooth

@objc enum X1MouseButton: UInt8 {
    case left = 0
    case right = 1
    case middle = 2
}

@objc protocol X1KitMouseDelegate: AnyObject {
    func connectedStateDidChange(identifier: UUID, isConnected: Bool)
    func mouseDidMove(identifier: UUID, deltaX: Int16, deltaY: Int16)
    func mouseDown(identifier: UUID, button: X1MouseButton)
    func mouseUp(identifier: UUID, button: X1MouseButton)
    func wheelDidScroll(identifier: UUID, deltaZ: Int8)
}

class X1Mouse: NSObject {
    var centralManager: CBCentralManager?
    var x1Array: [CBPeripheral] = []
    @objc weak var delegate: X1KitMouseDelegate?

    static let X1Service = CBUUID(string: "2B080000-BDB5-F6EB-24AE-9D6AB282AB63")
    static let characteristicProtocolMode = CBUUID(string: "2A4E")
    static let characteristicReport = CBUUID(string: "2A4D")
    static let descriptorReportReference = CBUUID(string: "2908")
    static let wheelAndButtonsReport: UInt16 = 0x0101
    static let xyReport: UInt16 = 0x0201

    @objc func start() {
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
}

extension CBCharacteristic {
    private struct X1KitState {
        static var buttonsState: UInt8 = 0
    }

    var x1LastButtonsState: UInt8 {
        get {
            return X1KitState.buttonsState
        }

        set(newValue) {
            X1KitState.buttonsState = newValue
        }
    }
}

extension X1Mouse: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOff:
            x1Array.removeAll()

        case .poweredOn:
            guard let peripherals = centralManager?.retrieveConnectedPeripherals(withServices: [X1Mouse.X1Service]) else { return }

            for peripheral in peripherals {
                peripheral.delegate = self

                centralManager?.connect(peripheral)

                x1Array.append(peripheral)
            }

            centralManager?.scanForPeripherals(withServices: [X1Mouse.X1Service], options: nil)

        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !x1Array.contains(peripheral) else { return }

        x1Array.append(peripheral)

        peripheral.delegate = self

        centralManager?.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        delegate?.connectedStateDidChange(identifier: peripheral.identifier, isConnected: true)

        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        delegate?.connectedStateDidChange(identifier: peripheral.identifier, isConnected: false)

        centralManager?.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        centralManager?.connect(peripheral)
    }
}

extension X1Mouse: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }

        for service in services where service.uuid == X1Mouse.X1Service {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            switch characteristic.uuid {
            case X1Mouse.characteristicProtocolMode:
                // select boot mode protocol, allows direct access to mouse
                peripheral.writeValue(Data(bytes: [0], count: 1), for: characteristic, type: CBCharacteristicWriteType.withoutResponse)

            case X1Mouse.characteristicReport:
                peripheral.discoverDescriptors(for: characteristic)

            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        guard let descriptors = characteristic.descriptors else { return }

        for descriptor in descriptors {
            peripheral.readValue(for: descriptor)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        #if swift(>=5.5)
        guard let characteristic = descriptor.characteristic else { return }
        #else
        let characteristic = descriptor.characteristic
        #endif
        guard descriptor.uuid == X1Mouse.descriptorReportReference else { return }
        guard let value = descriptor.value as? NSData else { return }
        guard value.count == 2 else { return } /* report reference is 2 bytes long */

        let reportId = (UInt16(value[0]) << 8) | (UInt16(value[1]))

        switch reportId {
        case X1Mouse.xyReport,
             X1Mouse.wheelAndButtonsReport:
            peripheral.setNotifyValue(true, for: characteristic)

            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }

        default:
            break
        }
    }

    func extendSign(value: UInt16, totalBits: Int) -> Int16 {
        return Int16.init(bitPattern: value << (16 - totalBits)) >> (16 - totalBits)
    }

    func bitState(value: UInt8, forBit bit: UInt8) -> UInt8 {
        guard bit<=7 else { return 0 }

        if value & (1 << bit)==(1 << bit) {
            return 1 << bit
        } else {
            return 0
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid==X1Mouse.characteristicReport else { return }
        guard let descriptors = characteristic.descriptors as [CBDescriptor]? else { return }

        for descriptor in descriptors where descriptor.uuid == X1Mouse.descriptorReportReference {
            guard let value = descriptor.value as? NSData else { continue }
            guard value.count==2 else { continue } /* report reference is 2 bytes */

            let reportId = (UInt16(value[0]) << 8) | (UInt16(value[1]))

            switch reportId {
            case X1Mouse.xyReport:
                guard let reportData = characteristic.value as NSData? else { continue }
                guard reportData.count == 3 else { continue }

                // unpack the x & y deltas (12 bits each)

                let deltaX: Int16 = extendSign(value: ((UInt16(reportData[0])) | ((UInt16(reportData[1]) & 0xF) << 8)), totalBits: 12)
                let deltaY: Int16 = extendSign(value: ((UInt16(reportData[2]) << 4) | (UInt16(reportData[1]) >> 4)), totalBits: 12)

                delegate?.mouseDidMove(identifier: peripheral.identifier, deltaX: deltaX, deltaY: deltaY)

             case X1Mouse.wheelAndButtonsReport:
                guard let reportData = characteristic.value as NSData? else { continue }

                var wheelByte = reportData.count - 2

                if (reportData.count != 3) && (reportData.count != 5) {
                    continue
                }

                // newer mice/firmware send xy deltas in this report

                if reportData.count == 5 {
                    let deltaX: Int16 = extendSign(value: ((UInt16(reportData[1])) | ((UInt16(reportData[2]) & 0xF) << 8)), totalBits: 12)
                    let deltaY: Int16 = extendSign(value: ((UInt16(reportData[3]) << 4) | (UInt16(reportData[2]) >> 4)), totalBits: 12)

                    delegate?.mouseDidMove(identifier: peripheral.identifier, deltaX: deltaX, deltaY: deltaY)

                    wheelByte = reportData.count - 1
                }

                // check to see if any bits in the button state have changed

                for bit: UInt8 in 0...2 {
                    guard let button = X1MouseButton(rawValue: bit) else { continue }

                    if bitState(value: reportData[0], forBit: bit) == bitState(value: characteristic.x1LastButtonsState, forBit: bit) {
                        continue
                    }

                    if bitState(value: reportData[0], forBit: bit) == (1<<bit) {
                        delegate?.mouseDown(identifier: peripheral.identifier, button: button)
                    } else {
                        delegate?.mouseUp(identifier: peripheral.identifier, button: button)
                    }

                    characteristic.x1LastButtonsState = UInt8.init(reportData[0])
                }

                // check whether wheel moved

                if Int8.init(bitPattern: reportData[wheelByte]) != 0 {
                    delegate?.wheelDidScroll(identifier: peripheral.identifier, deltaZ: Int8.init(bitPattern: reportData[wheelByte]))
                }

            default:
                break
            }
        }
    }
}
