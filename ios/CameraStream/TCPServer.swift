import Foundation
import Network

// Packet types sent over the wire
// Protocol: [ 1-byte type ][ 4-byte big-endian length ][ data ]
enum PacketType: UInt8 {
    case video = 0x01   // H.264 Annex B
    case audio = 0x02   // AAC-ADTS
}

class TCPServer {

    private var listener:    NWListener?
    private var connections: [NWConnection] = []
    private let queue            = DispatchQueue(label: "tcp.server", qos: .userInteractive)
    private let connectionsLock  = NSLock()

    var onClientConnected:    (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    var onError:              ((Error) -> Void)?

    var clientCount: Int {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return connections.count
    }

    // MARK: - Lifecycle

    func start(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        listener = try NWListener(using: parameters,
                                   on: NWEndpoint.Port(integerLiteral: port))

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:   print("[TCPServer] Listening on port \(port)")
            case .failed(let e): print("[TCPServer] Failed: \(e)"); self?.onError?(e)
            default: break
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
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

    // MARK: - Send

    /// Send a typed packet to all connected clients.
    func sendPacket(type: PacketType, data: Data) {
        var typeByte = type.rawValue
        var length   = UInt32(data.count).bigEndian

        var header = Data(bytes: &typeByte, count: 1)
        header.append(Data(bytes: &length,  count: 4))

        let packet = header + data

        connectionsLock.lock()
        let active = connections
        connectionsLock.unlock()

        for conn in active {
            guard conn.state == .ready else { continue }
            conn.send(content: packet, completion: .contentProcessed { error in
                if let error = error {
                    print("[TCPServer] Send error: \(error)")
                }
            })
        }
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ connection: NWConnection) {
        print("[TCPServer] New client: \(connection.endpoint)")

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onClientConnected?()
            case .failed, .cancelled:
                self?.removeConnection(connection)
                self?.onClientDisconnected?()
            default: break
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
}
