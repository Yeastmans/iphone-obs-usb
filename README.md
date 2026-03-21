# iPhone OBS USB Camera — Free & Open Source

Stream your iPhone camera to OBS over USB. No subscriptions. No watermarks. No BS.

---

## How It Works

```
iPhone App → USB → iproxy tunnel → Python receiver → MJPEG stream → OBS
```

Apple's `usbmuxd` (installed with iTunes) tunnels TCP traffic over USB automatically.
No kernel drivers needed. No Apple APIs violated.

---

## One-Time Setup

### 1. Get the iPhone App (IPA)

Since you're on Windows, GitHub Actions compiles it for free:

1. Fork or push this repo to your GitHub account
2. Go to **Actions** tab → **Build iOS App** → **Run workflow**
3. Wait ~5 minutes for the build to finish
4. Download the `CameraStream-IPA` artifact (a `.zip` containing the `.ipa`)

### 2. Install the IPA on Your iPhone (Sideloadly)

1. Download [Sideloadly](https://sideloadly.io) (free, Windows)
2. Install [iTunes](https://www.apple.com/itunes/) on Windows (needed for USB drivers)
3. Plug your iPhone into your PC via USB and trust the computer when prompted
4. Open Sideloadly, drag the `.ipa` in, enter your Apple ID, click **Start**
5. On your iPhone: **Settings → General → VPN & Device Management** → trust the app

> **Note:** Free Apple IDs expire apps every 7 days. Re-run Sideloadly to refresh.
> If you want permanent installs, a $99/year Apple Developer account removes this limit.

### 3. Install iproxy (Windows)

`iproxy` tunnels the iPhone's TCP port to your Windows machine over USB.

1. Download [libimobiledevice for Windows](https://github.com/libimobiledevice-win32/imobiledevice-net/releases)
   — grab the latest `ideviceinstaller` zip, it includes `iproxy.exe`
2. Extract and put `iproxy.exe` somewhere on your PATH (or just use full path)

### 4. Install Python

Download [Python 3.8+](https://python.org) for Windows. No extra packages needed.

---

## Every Time You Use It

**Step 1 — Start iproxy** (run in a terminal, leave it open):
```
iproxy 8080 8080
```

**Step 2 — Start the Python receiver** (run in another terminal):
```
python windows\receiver.py
```

**Step 3 — On your iPhone:**
- Open the **OBS Camera** app
- Choose resolution (720p / 1080p / 4K)
- Tap **Start Streaming**

**Step 4 — In OBS:**
- Add Source → **Media Source**
- Uncheck **Local File**
- Input: `http://localhost:9090/stream`
- Click OK

That's it. Your iPhone camera is live in OBS.

---

## Resolution & Quality

| Setting | Resolution | Use case |
|---------|-----------|----------|
| 720p | 1280×720 | Low latency, small files |
| 1080p | 1920×1080 | Best balance (default) |
| 4K | 3840×2160 | Maximum quality (iPhone 12 Pro+) |

JPEG quality is set to maximum (1.0) by default in `CameraCapture.swift`.
This is near-lossless — you won't see compression artifacts at this setting.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `iproxy` says device not found | Make sure iTunes is installed, trust your iPhone on PC |
| Python receiver says "not reachable" | Check iproxy is running, check iPhone app is streaming |
| OBS shows black | Try stopping/starting the media source in OBS |
| App untrusted on iPhone | Settings → General → VPN & Device Management → trust it |
| High latency | Switch to 720p in the iPhone app |
| App expires after 7 days | Re-run Sideloadly to re-sign it |

---

## Project Structure

```
├── ios/
│   ├── CameraStream/
│   │   ├── AppDelegate.swift      # App entry point
│   │   ├── ViewController.swift   # UI (start/stop, resolution picker)
│   │   ├── CameraCapture.swift    # AVFoundation camera capture
│   │   ├── TCPServer.swift        # Network framework TCP server
│   │   └── Info.plist             # App permissions
│   └── project.yml                # XcodeGen project spec
├── windows/
│   └── receiver.py                # Python MJPEG receiver + HTTP server
└── .github/workflows/
    └── build-ios.yml              # GitHub Actions build (free)
```

---

## License

MIT — do whatever you want with it.
