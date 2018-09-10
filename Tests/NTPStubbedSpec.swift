//
//  NTPStubbedSpec.swift
//  TrueTime
//
//  Created by Michael Sanders on 4/24/18.
//  Copyright © 2018 Instacart. All rights reserved.
//

@testable import TrueTime
import CTrueTime
//import CocoaAsyncSocket
import Socket
import Nimble
import Quick
import Result

final class NTPStubbedSpec: QuickSpec {
    override func spec() {
        describe("fetchIfNeeded") {
            it("should ignore outliers for localhost") {
                self.testReferenceTimeOutliers(host: "localhost")
            }
//            it("should ignore outliers for IPv4 host") {
//                self.testReferenceTimeOutliers(hostName: "127.0.0.1")
//            }
//            it("should should ignore outliers for IPv6 host") {
//                self.testReferenceTimeOutliers(hostName: ":1")
//            }
//            it("should should ignore outliers for time.apple.com") {
////                self.testReferenceTimeOutliers(hostName: "time.apple.com")
//            }
//            it("should ignore invalid responses") {
//                self.testInvalidResponse(hostName: "localhost")
//            }
        }
    }
}

private extension NTPStubbedSpec {
    func testReferenceTimeOutliers(host: String, port: Int = .randomPort) {
        let clients = (0..<100).map { _ in TrueTimeClient() }
        let server = NTPServer(port: port)
        waitUntil(timeout: 60) { done in
            var results: [ReferenceTimeResult?] = Array(repeating: nil, count: clients.count)
            let start = Date()
            let finish = {
                let end = Date()
                let results: [ReferenceTimeResult] = results.compactMap { $0 }
                let times: [ReferenceTime] = results.map { $0.value }.compactMap { $0 }
                let errors: [NSError] = results.map { $0.error }.compactMap { $0 }
                expect(times).notTo(beEmpty(), description: "Expected times, got: \(errors)")
                print("Got \(times.count) times for \(results.count) results")

                let sortedTimes: [ReferenceTime] = times.sorted {
                    $0.time.timeIntervalSince1970 < $1.time.timeIntervalSince1970
                }

                if !sortedTimes.isEmpty {
                    let medianTime = sortedTimes[sortedTimes.count / 2]
                    let maxDelta = end.timeIntervalSince1970 - start.timeIntervalSince1970
                    for time in times {
                        let delta = abs(time.time.timeIntervalSince1970 - medianTime.time.timeIntervalSince1970)
                        expect(delta) <= maxDelta
                    }
                }

                done()
            }

//            proxy.socketDidAcceptNewSocketCallback = { _, newSocket in
//                acceptedServerSocket = newSocket
//                acceptedServerSocket?.readData(withTimeout: -1, tag: 0)
//            }
//            proxy.socketDidConnectToHostCallback = { socket, _, _ in
//                socket.readData(withTimeout: -1, tag: 0)
//            }
//            proxy.socketDidReadDataCallback = { socket, data, _ in
//                var packet = ntp_packet_t(data: data).nativeEndian
//                expect(packet.client_mode) == 3
//                expect(packet.version_number) == 3
//
////                packet.originate_time = .now()
//                print("Got packet \(packet)")
//                socket.write(packet.data, withTimeout: -1, tag: 0)
//            }
//            proxy.socketDidWriteDataWithTagCallback { socket, tag in
//            }
            server.run()
            for (idx, client) in clients.enumerated() {
                client.start(pool: [host], port: port)
                client.fetchIfNeeded { result in
                    results[idx] = result
                    if !results.contains(where: { $0 == nil }) {
                        finish()
                    }
                }
            }
        }
    }
}

final class NTPServer {
    static let quitCommand: String = "QUIT"
    static let shutdownCommand: String = "SHUTDOWN"
    static let bufferSize = 4096

    let port: Int
    var listenSocket: Socket? = nil
    var continueRunning = true
    var connectedSockets = [Int32: Socket]()
    let socketLockQueue = DispatchQueue(label: "com.ibm.serverSwift.socketLockQueue")

    init(port: Int) {
        self.port = port
    }

    deinit {
        stop()
    }

    func stop() {
        continueRunning = false
        for socket in connectedSockets.values {
            socket.close()
        }
        listenSocket?.close()
    }

    func run() {
        let queue = DispatchQueue.global(qos: .userInteractive)
        queue.async { [unowned self] in
            do {
                // Create an IPV6 socket...
                try self.listenSocket = Socket.create(family: .inet)

                guard let socket = self.listenSocket else {
                    print("Unable to unwrap socket...")
                    return
                }

//                try socket.connect(to: "localhost", port: Int32(self.port))
                try socket.listen(on: self.port)
                print("Listening on port: \(socket.listeningPort)")
//                var readData = Data(capacity: NTPServer.bufferSize)
//                let bytesRead = try socket.read(into: &readData)
//                print("Read data \(bytesRead)")

                repeat {
                    let newSocket = try socket.acceptClientConnection()

                    print("Accepted connection from: \(newSocket.remoteHostname) on port \(newSocket.remotePort)")
                    print("Socket Signature: \(newSocket.signature?.description ?? "nil")")
                    self.addNewConnection(socket: newSocket)
                } while self.continueRunning
            }
            catch let error {
                guard let socketError = error as? Socket.Error else {
                    print("Unexpected error...")
                    return
                }

                if self.continueRunning {
                    print("Error reported:\n \(socketError.description)")
                }
            }
        }
    }


    func addNewConnection(socket: Socket) {

        // Add the new socket to the list of connected sockets...
        socketLockQueue.sync { [unowned self, socket] in
            self.connectedSockets[socket.socketfd] = socket
        }

        // Get the global concurrent queue...
        let queue = DispatchQueue.global(qos: .default)

        // Create the run loop work item and dispatch to the default priority global queue...
        queue.async { [unowned self, socket] in

            var shouldKeepRunning = true

            var readData = Data(capacity: NTPServer.bufferSize)

            do {
                // Write the welcome string...
                try socket.write(from: "Hello, type 'QUIT' to end session\nor 'SHUTDOWN' to stop server.\n")

                repeat {
                    let bytesRead = try socket.read(into: &readData)

                    if bytesRead > 0 {
                        guard let response = String(data: readData, encoding: .utf8) else {

                            print("Error decoding response...")
                            readData.count = 0
                            break
                        }
                        if response.hasPrefix(NTPServer.shutdownCommand) {

                            print("Shutdown requested by connection at \(socket.remoteHostname):\(socket.remotePort)")

                            // Shut things down...
                            self.stop()

                            return
                        }
                        print("Server received from connection at \(socket.remoteHostname):\(socket.remotePort): \(response) ")
                        let reply = "Server response: \n\(response)\n"
                        try socket.write(from: reply)
                    }

                    if bytesRead == 0 {
                        shouldKeepRunning = false
                        break
                    }

                    readData.count = 0

                } while shouldKeepRunning

                print("Socket: \(socket.remoteHostname):\(socket.remotePort) closed...")
                socket.close()

                self.socketLockQueue.sync { [unowned self, socket] in
                    self.connectedSockets[socket.socketfd] = nil
                }

            }
            catch let error {
                guard let socketError = error as? Socket.Error else {
                    print("Unexpected error by connection at \(socket.remoteHostname):\(socket.remotePort)...")
                    return
                }
                if self.continueRunning {
                    print("Error reported by connection at \(socket.remoteHostname):\(socket.remotePort):\n \(socketError.description)")
                }
            }
        }
    }
}

private extension Int {
    static var randomPort: Int {
        return (1024..<Int(UInt16.max)).randomElement
    }
}

private extension CountableRange {
    var randomElement: Element {
        let distance = self.distance(from: startIndex, to: endIndex)
        let offset = arc4random_uniform(UInt32(distance))
        return self[index(startIndex, offsetBy: Int(offset))]
    }
}
