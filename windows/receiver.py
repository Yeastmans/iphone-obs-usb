"""
iPhone OBS USB Camera Receiver  (H.264 + AAC → MPEG-TS)
========================================================
Receives typed packets from the iPhone app over USB (via iproxy tunnel)
and serves them as an MPEG-TS HTTP stream that OBS reads natively
with both video and audio.

Packet wire format (from iOS):
    [ 1 byte type ][ 4 bytes big-endian length ][ data ]
    type 0x01 = H.264 Annex B video
    type 0x02 = AAC-ADTS audio

Usage:
    python receiver.py

In OBS: Add Source → Media Source → uncheck "Local File"
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
IPHONE_HOST    = "localhost"
IPHONE_PORT    = 8080
HTTP_PORT      = 9090
RECONNECT_DELAY = 2.0
# ────────────────────────────────────────────────────────────────────────────

# ── MPEG-TS constants ────────────────────────────────────────────────────────
TS_SYNC      = 0x47
TS_SIZE      = 188

PAT_PID      = 0x0000
PMT_PID      = 0x1000
VIDEO_PID    = 0x0100
AUDIO_PID    = 0x0101
PROGRAM_NUM  = 1

# ── Thread-safe TS frame buffer ─────────────────────────────────────────────

class TSBuffer:
    def __init__(self):
        self._chunks: list = []
        self._lock  = threading.Lock()
        self._event = threading.Event()

    def put(self, data: bytes):
        with self._lock:
            self._chunks.append(data)
            # Keep buffer bounded to ~1 second of data at ~8 Mbps
            if len(self._chunks) > 500:
                self._chunks = self._chunks[-200:]
        self._event.set()

    def get_all(self, timeout: float = 1.0) -> bytes:
        self._event.wait(timeout)
        self._event.clear()
        with self._lock:
            data = b"".join(self._chunks)
            self._chunks.clear()
        return data


ts_buffer = TSBuffer()
stats     = {"fps": 0.0, "connected": False, "clients": 0}


# ── MPEG-TS muxer ────────────────────────────────────────────────────────────

def crc32_mpeg2(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= (byte << 24)
        for _ in range(8):
            if crc & 0x80000000:
                crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            else:
                crc = (crc << 1) & 0xFFFFFFFF
    return crc


def _ts_packets(pid: int, section: bytes, counter: int) -> bytes:
    """Wrap a PSI section (PAT/PMT) in TS packet(s). Returns raw bytes."""
    payload   = b"\x00" + section          # pointer_field = 0
    out       = bytearray()
    first     = True

    while payload:
        adaptation = b""
        chunk      = payload[:184]
        payload    = payload[184:]

        # Last (or only) packet — stuff with 0xFF if short
        if not payload and len(chunk) < 184:
            stuffing = 184 - len(chunk)
            if stuffing == 1:
                adaptation = b"\x00"       # 1-byte adaptation field (length=0)
                af_bits    = 0x20
            else:
                adaptation = bytes([stuffing - 1, 0x00]) + bytes(stuffing - 2)
                af_bits    = 0x20
            chunk = chunk              # no change needed; stuffed via adaptation
        else:
            af_bits = 0x00

        pusi   = 0x40 if first else 0x00
        header = bytes([
            TS_SYNC,
            pusi | ((pid >> 8) & 0x1F),
            pid & 0xFF,
            0x10 | af_bits | (counter & 0x0F),
        ])
        pkt = header + adaptation + chunk
        pkt = pkt.ljust(TS_SIZE, b"\xFF")[:TS_SIZE]
        out += pkt
        first   = False
        counter = (counter + 1) & 0x0F

    return bytes(out)


class TSMuxer:
    def __init__(self):
        self._counters    = {PAT_PID: 0, PMT_PID: 0, VIDEO_PID: 0, AUDIO_PID: 0}
        self._start_time  = time.time()
        self._last_pat    = 0.0
        self._pat_section = self._build_pat()
        self._pmt_section = self._build_pmt()

    # ── PAT ──────────────────────────────────────────────────────────────

    def _build_pat(self) -> bytes:
        body = struct.pack(">HH", PROGRAM_NUM, PMT_PID | 0xE000)
        hdr  = struct.pack(">HBBB", 0x0001, 0xC1, 0x00, 0x00)
        sec  = bytes([0x00]) + struct.pack(">H", 0xB000 | (len(hdr) + len(body) + 4)) + hdr + body
        return sec + struct.pack(">I", crc32_mpeg2(sec))

    # ── PMT ──────────────────────────────────────────────────────────────

    def _build_pmt(self) -> bytes:
        streams = (
            bytes([0x1B]) + struct.pack(">H", VIDEO_PID | 0xE000) + b"\xF0\x00" +  # H.264
            bytes([0x0F]) + struct.pack(">H", AUDIO_PID | 0xE000) + b"\xF0\x00"    # AAC
        )
        hdr = (
            struct.pack(">HBBB", PROGRAM_NUM, 0xC1, 0x00, 0x00) +
            struct.pack(">H", VIDEO_PID | 0xE000) +   # PCR PID
            b"\xF0\x00"                                # program_info_length = 0
        )
        sec = bytes([0x02]) + struct.pack(">H", 0xB000 | (len(hdr) + len(streams) + 4)) + hdr + streams
        return sec + struct.pack(">I", crc32_mpeg2(sec))

    # ── PCR / PTS helpers ─────────────────────────────────────────────────

    def _pts90(self) -> int:
        return int((time.time() - self._start_time) * 90_000) & 0x1FFFFFFF

    def _pcr27(self) -> int:
        return int((time.time() - self._start_time) * 27_000_000) & 0x1FFFFFFFF

    @staticmethod
    def _encode_pts(pts: int) -> bytes:
        return bytes([
            0x21 | ((pts >> 29) & 0x0E),
            (pts >> 22) & 0xFF,
            0x01 | ((pts >> 14) & 0xFE),
            (pts >> 7)  & 0xFF,
            0x01 | ((pts << 1)  & 0xFE),
        ])

    @staticmethod
    def _pcr_adaptation(pcr27: int) -> bytes:
        pcr_base = (pcr27 // 300) & 0x1FFFFFFFF
        pcr_ext  = pcr27 % 300
        val      = (pcr_base << 15) | (0x3F << 9) | (pcr_ext & 0x1FF)
        pcr_b    = struct.pack(">Q", val << 16)[:6]
        return bytes([7, 0x10]) + pcr_b    # af_length=7, PCR_flag

    # ── PES builder ───────────────────────────────────────────────────────

    def _make_pes(self, stream_id: int, payload: bytes, pts: int) -> bytes:
        pts_bytes = self._encode_pts(pts)
        pes_hdr   = bytes([0x80, 0x80, 5]) + pts_bytes   # flags | PTS_DTS_flags | hdr_len | PTS
        pes_size  = 0 if stream_id == 0xE0 else (len(payload) + len(pes_hdr))
        return b"\x00\x00\x01" + bytes([stream_id]) + struct.pack(">H", pes_size) + pes_hdr + payload

    # ── TS packetiser ─────────────────────────────────────────────────────

    def _packetize(self, pid: int, pes: bytes, with_pcr: bool = False) -> bytes:
        out   = bytearray()
        first = True

        while pes:
            adaptation = b""

            if first and with_pcr:
                adaptation = self._pcr_adaptation(self._pcr27())

            af_len       = len(adaptation)
            payload_room = 184 - af_len
            chunk        = pes[:payload_room]
            pes          = pes[payload_room:]

            # Stuff final short packet
            if not pes and len(chunk) < payload_room and af_len == 0:
                need = payload_room - len(chunk)
                if need == 1:
                    adaptation = b"\x00"
                else:
                    adaptation = bytes([need - 1, 0x00]) + bytes(need - 2)
                af_len = len(adaptation)

            af_bits = 0x20 if adaptation else 0x00
            cc      = self._counters[pid] & 0x0F
            pusi    = 0x40 if first else 0x00

            header = bytes([
                TS_SYNC,
                pusi | ((pid >> 8) & 0x1F),
                pid & 0xFF,
                0x10 | af_bits | cc,
            ])
            pkt = header + adaptation + chunk
            pkt = pkt.ljust(TS_SIZE, b"\xFF")[:TS_SIZE]
            out += pkt

            self._counters[pid] = (self._counters[pid] + 1) & 0x0F
            first = False

        return bytes(out)

    # ── Public API ────────────────────────────────────────────────────────

    def mux_video(self, h264_annexb: bytes) -> bytes:
        """Returns MPEG-TS bytes for one H.264 access unit."""
        now = time.time()
        out = bytearray()

        # PAT + PMT every ~100 ms
        if now - self._last_pat >= 0.1:
            out += _ts_packets(PAT_PID, self._pat_section, self._counters[PAT_PID])
            self._counters[PAT_PID] = (self._counters[PAT_PID] + 1) & 0x0F
            out += _ts_packets(PMT_PID, self._pmt_section, self._counters[PMT_PID])
            self._counters[PMT_PID] = (self._counters[PMT_PID] + 1) & 0x0F
            self._last_pat = now

        pts = self._pts90()
        pes = self._make_pes(0xE0, h264_annexb, pts)
        out += self._packetize(VIDEO_PID, pes, with_pcr=True)
        return bytes(out)

    def mux_audio(self, aac_adts: bytes) -> bytes:
        """Returns MPEG-TS bytes for one AAC ADTS frame."""
        pts = self._pts90()
        pes = self._make_pes(0xC0, aac_adts, pts)
        return self._packetize(AUDIO_PID, pes)


muxer = TSMuxer()


# ── MPEG-TS HTTP Server ──────────────────────────────────────────────────────

class MpegTSHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        pass  # suppress default HTTP logs

    def do_GET(self):
        if self.path != "/stream":
            self.send_response(404)
            self.end_headers()
            return

        self.send_response(200)
        self.send_header("Content-Type", "video/mp2t")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        stats["clients"] += 1
        print(f"[HTTP] OBS connected ({stats['clients']} client(s))")

        try:
            while True:
                chunk = ts_buffer.get_all(timeout=2.0)
                if not chunk:
                    continue
                try:
                    self.wfile.write(chunk)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    break
        finally:
            stats["clients"] -= 1
            print(f"[HTTP] OBS disconnected ({stats['clients']} remaining)")


def run_http_server():
    server = HTTPServer(("0.0.0.0", HTTP_PORT), MpegTSHandler)
    print(f"[HTTP] MPEG-TS stream at http://localhost:{HTTP_PORT}/stream")
    server.serve_forever()


# ── iPhone TCP Receiver ───────────────────────────────────────────────────────

PACKET_VIDEO = 0x01
PACKET_AUDIO = 0x02

def receive_packets():
    frame_count   = 0
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
                # Read 5-byte header: [1-byte type][4-byte big-endian length]
                hdr = recv_exact(sock, 5)
                if hdr is None:
                    break

                pkt_type   = hdr[0]
                pkt_length = struct.unpack(">I", hdr[1:5])[0]

                if pkt_length == 0 or pkt_length > 50_000_000:
                    print(f"[TCP] Bad packet length: {pkt_length}")
                    break

                data = recv_exact(sock, pkt_length)
                if data is None:
                    break

                if pkt_type == PACKET_VIDEO:
                    ts_buffer.put(muxer.mux_video(data))
                    frame_count += 1
                    now     = time.time()
                    elapsed = now - last_fps_time
                    if elapsed >= 1.0:
                        stats["fps"] = frame_count / elapsed
                        frame_count  = 0
                        last_fps_time = now
                        print(f"[TCP] {stats['fps']:.1f} FPS | Clients: {stats['clients']}", end="\r")

                elif pkt_type == PACKET_AUDIO:
                    ts_buffer.put(muxer.mux_audio(data))

        except (ConnectionRefusedError, OSError) as e:
            stats["connected"] = False
            if isinstance(e, ConnectionRefusedError):
                print(f"\n[TCP] iPhone not reachable — is iproxy running? Retrying in {RECONNECT_DELAY}s...")
            else:
                print(f"\n[TCP] Connection lost: {e}. Reconnecting in {RECONNECT_DELAY}s...")
        except Exception as e:
            stats["connected"] = False
            print(f"\n[TCP] Unexpected error: {e}. Reconnecting in {RECONNECT_DELAY}s...")
        finally:
            try:
                sock.close()
            except Exception:
                pass
            stats["connected"] = False

        time.sleep(RECONNECT_DELAY)


def recv_exact(sock: socket.socket, n: int):
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
    print("=" * 52)
    print("  iPhone OBS USB Camera Receiver  (H.264 + AAC)")
    print("=" * 52)
    print()
    print("STEP 1: Make sure iproxy is running:")
    print(f"        iproxy {IPHONE_PORT} {IPHONE_PORT}")
    print()
    print("STEP 2: Open the OBS Camera app on your iPhone")
    print("        and tap 'Start Streaming'")
    print()
    print("STEP 3: In OBS, add a Media Source:")
    print(f"        URL: http://localhost:{HTTP_PORT}/stream")
    print()
    print("-" * 52)

    threading.Thread(target=run_http_server, daemon=True).start()

    try:
        receive_packets()
    except KeyboardInterrupt:
        print("\n[Receiver] Stopped.")
        sys.exit(0)
