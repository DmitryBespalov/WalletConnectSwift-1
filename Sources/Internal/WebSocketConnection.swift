//
//  Copyright © 2019 Gnosis Ltd. All rights reserved.
//

import Foundation
import Starscream
import Network

#if os(iOS)
import UIKit
#endif


class WebSocketConnection {
    let url: WCURL
    private let socket: WebSocket
    
    private var isConnected: Bool = false
    
    private let onConnect: (() -> Void)?
    private let onDisconnect: ((Error?) -> Void)?
    private let onTextReceive: ((String) -> Void)?
    // needed to keep connection alive
    private var pingTimer: Timer?
    // TODO: make injectable on server creation
    private let pingInterval: TimeInterval = 30
    
    private var requestSerializer: RequestSerializer = JSONRPCSerializer()
    private var responseSerializer: ResponseSerializer = JSONRPCSerializer()
    
    // serial queue for receiving the calls.
    private let serialCallbackQueue: DispatchQueue
    
#if os(iOS)
    private var backgroundNotificationObserver: Any?
    private var foregroundNotificationObserver: Any?
#endif
    
    var isOpen: Bool {
        return isConnected
    }
    
    init(url: WCURL,
         onConnect: (() -> Void)?,
         onDisconnect: ((Error?) -> Void)?,
         onTextReceive: ((String) -> Void)?) {
        self.url = url
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
        self.onTextReceive = onTextReceive
        serialCallbackQueue = DispatchQueue(label: "org.walletconnect.swift.connection-\(url.bridgeURL)-\(url.topic)")
        
        self.socket = WebSocket(request: URLRequest(url: url.bridgeURL), engine: WSEngine(transport: FoundationTransport(), certPinner: FoundationSecurity()))
        self.socket.callbackQueue = serialCallbackQueue
        self.socket.delegate = self
        
#if os(iOS)
        var didBecomeActiveName: NSNotification.Name
        if #available(iOS 13.0, *) {
            didBecomeActiveName = UIScene.didActivateNotification
        } else {
            didBecomeActiveName = UIApplication.didBecomeActiveNotification
        }
        self.foregroundNotificationObserver = NotificationCenter.default.addObserver(forName: didBecomeActiveName,
                                                                                     object: nil,
                                                                                     queue: OperationQueue.main) { [weak self] notification in
            self?.open()
        }
        var willResignActiveName: NSNotification.Name
        if #available(iOS 13.0, *) {
            willResignActiveName = UIScene.willDeactivateNotification
        } else {
            willResignActiveName = UIApplication.willResignActiveNotification
        }
        self.backgroundNotificationObserver = NotificationCenter.default.addObserver(forName: willResignActiveName,
                                                                                     object: nil,
                                                                                     queue: OperationQueue.main) { [weak self] notification in
            print("WebSocketConnect: ==> Shotting down socket before background")
            self?.close(closeCode: CloseCode.protocolError.rawValue)
        }
#endif
    }
    
    deinit {
        LogService.shared.log("WebSocketConnect: ==> deinit")
#if os(iOS)
        if let observer = self.backgroundNotificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.foregroundNotificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
#endif
        self.pingTimer?.invalidate()
    }
 
    func open() {
        self.socket.connect()
    }
    
    func close(closeCode: UInt16 = CloseCode.normal.rawValue) {
        self.socket.disconnect(closeCode: closeCode)
        self.pingTimer?.invalidate()
    }
    
    func send(_ text: String) {
        guard isConnected else { return }
        socket.write(string: text)
        log(text)
    }
    
    private func log(_ text: String) {
        if let request = try? requestSerializer.deserialize(text, url: url).json().string {
            LogService.shared.log("WC: ==> \(request)")
        } else if let response = try? responseSerializer.deserialize(text, url: url).json().string {
            LogService.shared.log("WC: ==> \(response)")
        } else {
            LogService.shared.log("WC: ==> \(text)")
        }
    }
}

extension WebSocketConnection: WebSocketDelegate {
    func didReceive(event: WebSocketEvent, client: WebSocket) {
        switch event {
        case .connected:
            DispatchQueue.main.sync {
                self.pingTimer = Timer.scheduledTimer(withTimeInterval: self.pingInterval,
                                                      repeats: true) { [weak self] _ in
                    LogService.shared.log("WC: ==> ping")
                    self?.socket.write(ping: Data())
                }
            }
            LogService.shared.log("WC: <== connected")
            isConnected = true
            onConnect?()
#if os(iOS)
        case .disconnected:
            DispatchQueue.main.sync {
                if UIApplication.shared.applicationState == .active {
                    didDisconnect(with: nil)
                } else {
                    LogService.shared.log("WC: <== connection disconnected in background. Will re-activate when possible.")
                }
            }
        case .error(let error):
            DispatchQueue.main.sync {
                if UIApplication.shared.applicationState == .active {
                    didDisconnect(with: error)
                } else {
                    LogService.shared.log("WC: <== connection error in background. Will re-activate when possible.")
                }
            }
            break
        case .cancelled:
            DispatchQueue.main.sync {
                if UIApplication.shared.applicationState == .active {
                    LogService.shared.log("WC: <== connection terminated from internal call. Disconnecting...")
                    didDisconnect(with: nil)
                } else {
                    LogService.shared.log("WC: <== connection cancelled in background. Will re-activate when possible.")
                }
            }
#else
        case .disconnected:
            didDisconnect(with: nil)
        case .error(let error):
            didDisconnect(with: error)
            break
        case .cancelled:
            didDisconnect(with: nil)
#endif
        case .text(let string):
            onTextReceive?(string)
        case .ping:
            LogService.shared.log("WC: <== ping")
            LogService.shared.log("WC: ==> pong client.respondToPingWithPong: \(client.respondToPingWithPong == true)")
            break
        case .pong:
            LogService.shared.log("WC: <== pong")
        case .reconnectSuggested:
            LogService.shared.log("WC: <== reconnectSuggested") //TODO: Should we?
        case .binary, .viabilityChanged:
            break
        }
    }
    
    private func didDisconnect(with error: Error? = nil) {
        LogService.shared.log("WC: <== disconnected")
        if let error = error {
            LogService.shared.log("^------ with error: \(error)")
        }
        self.isConnected = false
        self.pingTimer?.invalidate()
        onDisconnect?(error)
    }
}
