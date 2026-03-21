import Foundation
import Network

class TCPServer {

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "tcp.server", qos: .userInteractive)
    private let connectionsLock = NSLock()

    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    var onError: ((Error) -> Void)?

    var clientCount: Int {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return connections.count
    }

    func start(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[TCPServer] Listening on port \(port)")
            case .failed(let error):
                print("[TCPServer] Failed: \(error)")
                self?.onError?(error)
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil

        connectionsLock.lock()
        connections.forEach { $0.cancel() }
        connections.removeAll()
        connectionsLock.unlock()
    }

    private func handleNewConnection(_ connection: NWConnection) {
        print("[TCPServer] New client: \(connection.endpoint)")

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onClientConnected?()
            case .failed, .cancelled:
                self?.removeConnection(connection)
                self?.onClientDisconnected?()
            default:
                break
            }
        }

        connection.start(queue: queue)

        connectionsLock.lock()
        connections.append(connection)
        connectionsLock.unlock()
    }

    private func removeConnection(_ connection: NWConnection) {
        connectionsLock.lock()
        connections.removeAll { $0 === connection }
        connectionsLock.unlock()
    }

    // Send a JPEG frame to all connected clients
    // Protocol: [4 bytes big-endian length][JPEG data]
    func sendFrame(_ jpegData: Data) {
        var length = UInt32(jpegData.count).bigEndian
        let header = Data(bytes: &length, count: 4)
        let packet = header + jpegData

        connectionsLock.lock()
        let activeConnections = connections
        connectionsLock.unlock()

        for connection in activeConnections {
            guard connection.state == .ready else { continue }
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error = error {
                    print("[TCPServer] Send error: \(error)")
                }
            })
        }
    }
}
