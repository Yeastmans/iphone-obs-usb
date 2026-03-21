"""
iPhone OBS USB Camera Receiver
Receives JPEG frames from the iPhone app over USB (via iproxy tunnel)
and serves them as an MJPEG HTTP stream that OBS can read natively.

Usage:
    python receiver.py

Then in OBS: Add Source -> Media Source -> uncheck "Local File"
             Input: http://localhost:9090/stream
"""

import socket
import struct
import threading
import time
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Optional

# ── Config ──────────────────────────────────────────────────────────────────
IPHONE_HOST = "localhost"
IPHONE_PORT = 8080       # must match iproxy and the iOS app port
HTTP_PORT   = 9090       # OBS connects here
RECONNECT_DELAY = 2.0    # seconds between reconnect attempts
# ────────────────────────────────────────────────────────────────────────────

class FrameBuffer:
    """Thread-safe single-frame buffer."""

    def __init__(self):
        self._frame: Optional[bytes] = None
        self._lock = threading.Lock()
        self._event = threading.Event()

    def put(self, frame: bytes):
        with self._lock:
            self._frame = frame
        self._event.set()

    def get(self, timeout: float = 1.0) -> Optional[bytes]:
        self._event.wait(timeout)
        self._event.clear()
        with self._lock:
            return self._frame


buffer = FrameBuffer()
stats = {"fps": 0.0, "connected": False, "clients": 0}


# ── MJPEG HTTP Server ────────────────────────────────────────────────────────

BOUNDARY = b"--mjpegboundary"

class MJPEGHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        pass  # suppress default HTTP logs

    def do_GET(self):
        if self.path != "/stream":
            self.send_response(404)
            self.end_headers()
            return

        self.send_response(200)
        self.send_header("Content-Type", f"multipart/x-mixed-replace; boundary=mjpegboundary")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        stats["clients"] += 1
        print(f"[HTTP] Client connected ({stats['clients']} total)")

        try:
            while True:
                frame = buffer.get(timeout=2.0)
                if frame is None:
                    continue

                header = (
                    BOUNDARY + b"\r\n" +
                    b"Content-Type: image/jpeg\r\n" +
                    f"Content-Length: {len(frame)}\r\n\r\n".encode()
                )

                try:
                    self.wfile.write(header + frame + b"\r\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    break
        finally:
            stats["clients"] -= 1
            print(f"[HTTP] Client disconnected ({stats['clients']} remaining)")


def run_http_server():
    server = HTTPServer(("0.0.0.0", HTTP_PORT), MJPEGHandler)
    print(f"[HTTP] MJPEG stream at http://localhost:{HTTP_PORT}/stream")
    server.serve_forever()


# ── iPhone TCP Receiver ───────────────────────────────────────────────────────

def receive_frames():
    """Connect to iPhone via iproxy tunnel and receive JPEG frames."""
    frame_count = 0
    last_fps_time = time.time()

    while True:
        try:
            print(f"[TCP] Connecting to iPhone on {IPHONE_HOST}:{IPHONE_PORT}...")
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5.0)
            sock.connect((IPHONE_HOST, IPHONE_PORT))
            sock.settimeout(None)

            stats["connected"] = True
            print("[TCP] Connected to iPhone!")

            while True:
                # Read 4-byte length header
                raw_len = recv_exact(sock, 4)
                if raw_len is None:
                    break

                frame_len = struct.unpack(">I", raw_len)[0]

                if frame_len == 0 or frame_len > 50_000_000:  # sanity check (50MB max)
                    print(f"[TCP] Bad frame length: {frame_len}")
                    break

                # Read the JPEG frame
                jpeg_data = recv_exact(sock, frame_len)
                if jpeg_data is None:
                    break

                buffer.put(jpeg_data)

                # FPS counter
                frame_count += 1
                now = time.time()
                elapsed = now - last_fps_time
                if elapsed >= 1.0:
                    stats["fps"] = frame_count / elapsed
                    frame_count = 0
                    last_fps_time = now
                    print(f"[TCP] {stats['fps']:.1f} FPS | Clients: {stats['clients']}", end="\r")

        except (ConnectionRefusedError, OSError) as e:
            stats["connected"] = False
            if isinstance(e, ConnectionRefusedError):
                print(f"\n[TCP] iPhone not reachable. Is iproxy running? Retrying in {RECONNECT_DELAY}s...")
            else:
                print(f"\n[TCP] Connection lost: {e}. Reconnecting in {RECONNECT_DELAY}s...")

        except Exception as e:
            stats["connected"] = False
            print(f"\n[TCP] Unexpected error: {e}. Reconnecting in {RECONNECT_DELAY}s...")

        finally:
            try:
                sock.close()
            except:
                pass
            stats["connected"] = False

        time.sleep(RECONNECT_DELAY)


def recv_exact(sock: socket.socket, n: int) -> Optional[bytes]:
    """Read exactly n bytes from a socket."""
    data = bytearray()
    while len(data) < n:
        try:
            chunk = sock.recv(n - len(data))
            if not chunk:
                return None
            data.extend(chunk)
        except OSError:
            return None
    return bytes(data)


# ── Entry Point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print("=" * 50)
    print("  iPhone OBS USB Camera Receiver")
    print("=" * 50)
    print()
    print("STEP 1: Make sure iproxy is running:")
    print(f"        iproxy {IPHONE_PORT} {IPHONE_PORT}")
    print()
    print("STEP 2: Open the CameraStream app on your iPhone")
    print("        and tap 'Start Streaming'")
    print()
    print("STEP 3: In OBS, add a Media Source:")
    print(f"        URL: http://localhost:{HTTP_PORT}/stream")
    print()
    print("-" * 50)

    # Start HTTP server in background thread
    http_thread = threading.Thread(target=run_http_server, daemon=True)
    http_thread.start()

    # Run receiver in main thread (handles reconnection)
    try:
        receive_frames()
    except KeyboardInterrupt:
        print("\n[Receiver] Stopped.")
        sys.exit(0)
