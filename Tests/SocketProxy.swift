//
//  SocketProxy.swift
//  TrueTime
//
//  Created by Michael Sanders on 1/18/18.
//

import CocoaAsyncSocket

final class SocketProxy: NSObject {
    var socketDidAcceptNewSocketCallback: ((GCDAsyncSocket, GCDAsyncSocket) -> Void)?
    var socketDidConnectToHostCallback: ((GCDAsyncSocket, String, UInt16) -> Void)?
    var socketDidDisconnectCallback: ((GCDAsyncSocket, Error?) -> Void)?
    var socketDidReadDataCallback: ((GCDAsyncSocket, Data, Int) -> Void)?
    var socketDidWriteDataWithTagCallback: ((GCDAsyncSocket, Int) -> Void)?
}

extension SocketProxy: GCDAsyncSocketDelegate {
    func socket(_ socket: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
        socketDidAcceptNewSocketCallback?(socket, newSocket)
    }

    func socket(_ socket: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        socketDidConnectToHostCallback?(socket, host, port)
    }

    func socketDidDisconnect(_ socket: GCDAsyncSocket, withError error: Error?) {
        socketDidDisconnectCallback?(socket, error)
    }

    func socket(_ socket: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        socketDidReadDataCallback?(socket, data, tag)
    }

    func socket(_ socket: GCDAsyncSocket, didWriteDataWithTag tag: Int) {
        socketDidWriteDataWithTagCallback?(socket, tag)
    }
}
