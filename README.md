# Screen Capture Daemon for macOS

A lightweight, automated background screen capture system for macOS that records all connected displays at configurable frame rates and automatically stitches segments into daily videos. 

**Part of a recording suite:** Best used alongside the [Webcam Capture Daemon](https://github.com/msmolkin/webcam-capture-daemon) for a complete visual log of your activity.

This tool is designed to be a "set and forget" alternative to manual OBS recording, handling display changes, system sleep/wake, and daily rotations automatically.

## Features

- **Multi-Monitor Support:** Automatically detects and captures all connected screens.
- **Dynamic Framerate:** Configurable FPS for primary vs. secondary displays (e.g., 2 FPS for primary, 0.33 FPS for others).
- **Background Operation:** Runs as a macOS LaunchAgent, starting automatically at boot.
- **Robustness:** Handles display connect/disconnect, system sleep, and mid-capture crashes.
- **Daily Rotation:** Automatically rotates files at midnight and stitches all segments from the previous day into a single video per screen.
- **Configurable:** Change capture settings via a simple `config.env` file without modifying scripts.

## Installation

### 1. Requirements

- **macOS**
- **ffmpeg** (Install via Homebrew: `brew install ffmpeg`)

### 2. Setup Scripts

Copy the scripts to a location in your `PATH` (e.g., `/usr/local/bin/`):

```bash
cp screen-capture-daemon.sh /usr/local/bin/
cp daily-stitch.sh /usr/local/bin/
chmod +x /usr/local/bin/screen-capture-daemon.sh /usr/local/bin/daily-stitch.sh
```

### 3. Configuration

Create the config directory and copy the default settings:

```bash
mkdir -p ~/.config/screen-capture
cp config.env ~/.config/screen-capture/config.env
```

Edit `~/.config/screen-capture/config.env` to adjust your desired FPS:
```bash
PRIMARY_FPS=2
SECONDARY_FPS=1/3
```

### 4. First-Time Run & Critical Permissions

**This is the most important step.** Before loading the background service, you should grant the same screen-capture permissions to the exact processes that macOS will attribute the capture request to.

1.  **Grant Screen Recording to your terminal app** so you can do the first manual run:
    - **Terminal** or **iTerm2**
2.  **Grant Screen Recording to `/bin/bash`**. This matters because when the daemon runs via LaunchAgent, macOS TCC attributes the screen capture to the responsible process (`/bin/bash`), not just to `ffmpeg`.
3.  **Optionally grant Screen Recording to `ffmpeg`** if macOS surfaces it in the list. This is not always the deciding process, but it is useful for direct manual tests.
4.  **Run the script manually once from your terminal:**
    ```bash
    /usr/local/bin/screen-capture-daemon.sh
    ```

#### **The "Bypass" Prompt**
On newer macOS versions (Sonoma, Sequoia, and later), you will see this specific system prompt:

> **"bash" is requesting to bypass the system private window picker and directly access your screen and audio.**

![macOS Permissions Prompt](permissions-prompt.png)

- **You must click "Allow".**
- This prompt appears because the daemon records in the background without using the interactive system picker.
- If you do not click "Allow" here, the script may only record black frames, stall before first frame, or create empty files even if the general "Screen Recording" toggle is on in System Settings.

Once you've clicked "Allow" and verified it's capturing (by checking `~/screen-recordings/`), press `Ctrl+C` to stop the manual run.

### 5. Install the LaunchAgent

Now that the critical permissions are granted, you can set it to run automatically in the background:

Copy the `.plist` file to your user's LaunchAgents directory:

```bash
mkdir -p ~/Library/LaunchAgents
cp com.michaelcli.screen-capture.plist ~/Library/LaunchAgents/
```

Load the service:
```bash
launchctl load -w ~/Library/LaunchAgents/com.michaelcli.screen-capture.plist
```

### 6. Verify System Settings

If the daemon is running but creating empty files, stalling before first frame, or not creating output files at all, double-check that these are toggled **ON** in:
- **System Settings > Privacy & Security > Screen Recording**
  - **Terminal** or **iTerm2**
  - **/bin/bash**
  - **ffmpeg** if present

Note: If `/bin/bash` does not appear in the list, or you never saw the "Bypass" prompt, running the script manually (Step 4) should trigger its appearance in the list or the prompt to appear. After changing permissions, restart the daemon:
```bash
launchctl stop com.michaelcli.screen-capture
launchctl start com.michaelcli.screen-capture
```

### Replication Notes

If you want to reproduce the working setup on another Mac, these are the changes and expectations that mattered in practice:

- The LaunchAgent should run `/bin/bash /usr/local/bin/screen-capture-daemon.sh` directly in the Aqua session.
- `/bin/bash` needs Screen Recording permission because launchd-owned background captures are attributed to `bash` by TCC.
- `screen-capture-daemon.sh` should use non-interactive `ffmpeg` calls (`-nostdin` and `</dev/null`) so the process does not get stopped by terminal/job-control input.
- The daemon should use a launchd-safe `PATH`, write logs to `~/screen-recordings/logs/`, and keep a real stale-lock check instead of blindly deleting the lock directory.
- The AVFoundation input should explicitly use `-pixel_format uyvy422`.
- Shorter rolling segments are safer than a single all-day segment because recovery is faster and failures are easier to isolate.
- Re-enumerating AVFoundation devices while a capture is already running can destabilize the active capture, so the current script only re-enumerates on segment restart.

## How It Works

1. **`screen-capture-daemon.sh`**:
   - Monitors for connected displays using `ffmpeg -list_devices`.
   - Starts one `ffmpeg` process per display.
   - Saves recordings in `~/screen-recordings/YYYY-MM-DD/`.
   - Automatically handles screen changes by re-enumerating devices.
   - Clears stale lockfiles on startup if a crash occurred.

2. **`daily-stitch.sh`**:
   - Triggered at midnight by the daemon.
   - Uses `ffmpeg concat` to merge all segments from the previous day into single high-level files: `~/screen-recordings/YYYY-MM-DD-screenX-full.mp4`.

## Troubleshooting

- **Check logs:** Logs are stored in `~/screen-recordings/logs/` and stdout/stderr are redirected to `/tmp/screen-capture-daemon.out` and `.err`.
- **Stale Lockfile:** If the daemon won't start, run:
  ```bash
  rmdir /tmp/screen-capture-daemon-$(id -u).lock
  ```

## Companion Tool

For a complete setup, check out the [Webcam Capture Daemon](https://github.com/msmolkin/webcam-capture-daemon), which records your camera at a low framerate to complement your screen recordings.

## Support

If you find this tool useful, consider supporting the development:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/msmolkin)

## License
MIT
