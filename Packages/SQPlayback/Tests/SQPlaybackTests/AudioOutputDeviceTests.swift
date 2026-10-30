import Testing
@testable import SQPlayback

@Suite struct AudioOutputDeviceTests {
    private let devices = [AudioOutputDevice(uid: "builtin", name: "MacBook Speakers", id: 1),
                           AudioOutputDevice(uid: "usb-dac", name: "USB DAC", id: 2)]

    @Test func storedUIDSelectsThatDevice() {
        #expect(AudioOutputDevices.resolve(uid: "usb-dac", in: devices)?.id == 2)
    }

    @Test func missingDeviceFallsBackToSystemDefault() {
        #expect(AudioOutputDevices.resolve(uid: "unplugged-headphones", in: devices) == nil)
        #expect(AudioOutputDevices.resolve(uid: "usb-dac", in: []) == nil)
    }

    @Test func noUIDOrEmptyUIDMeansSystemDefault() {
        #expect(AudioOutputDevices.resolve(uid: nil, in: devices) == nil)
        #expect(AudioOutputDevices.resolve(uid: "", in: devices) == nil)
    }
}
