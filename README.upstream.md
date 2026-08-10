# Sleep/Wake Tracker Plugin for KOReader

A comprehensive plugin that tracks your reading habits by logging device sleep (suspend/standby) and wake (resume/leave standby) events. It provides detailed statistics, battery tracking, and data management features.

## Features

- **Automatic Logging:** 
  - Records "SLEEP" and "WAKE" timestamps automatically on suspend/resume.
  - Also tracks standby transitions (`onEnterStandby`/`onLeaveStandby`) on supported devices.
  - **Battery Tracking:** Logs battery percentage at every event to track drain.
  - **Resilient Recording:** Events are always logged even when battery reading is unavailable (uses a placeholder value), so timestamps are never lost.

- **Detailed Statistics:**
  - **Daily Summary:** Shows total active time, total sleep time, net battery change per category, and average drain rates.
  - **Cycle Analysis:** Groups Wake/Sleep events into clean cycles with accurate duration and battery drain per session.
    - Example: `唤醒于 10:00:00 → 休眠于 11:30:00 (1时 30分 00秒) [-5.0%]`
  - **Calibration:** Day-start vs day-end battery comparison for accurate net change calculation.
  - **Battery Estimation:** Average drain rate and estimated remaining battery time.

- **Data Management:**
  - **Export to CSV:** Back up your entire history to a CSV file.
    - Export Path: Saves to the root of your device storage (e.g., `/mnt/us` on Kindle, `/mnt/onboard` on Kobo).
    - Filename: `.sleepwaketracker_export.csv` (hidden file to keep your library clean).
    - Events with unknown battery levels are exported with an empty battery field.
  - **Import from CSV:** Restore your history from a backup file (supports append or overwrite modes).
    - Invalid or missing battery values in CSV are safely skipped (never defaults to 0%).
  - **Delete Logs:** Options to clear today's log or wipe all history.

- **Navigation:**
  - **Today's View:** Instant access to the current day's activity.
  - **History Browser:** Hierarchical navigation by Year -> Month -> Day.
  - **Gesture/Dispatcher Support:** Assign actions to gestures for quick access.

## Installation

### On Kobo, Kindle, PocketBook, etc.

1. Connect your device to your computer via USB.
2. Navigate to the KOReader plugins directory:
   - **Kobo:** `.add/koreader/plugins/`
   - **Kindle:** `koreader/plugins/`
3. Create a new folder named `sleepwaketracker.koplugin`.
4. Copy the following files into that folder:
   - `main.lua`
   - `_meta.lua`
   - `README.md`
5. Eject your device safely and restart KOReader.

## Usage

1. **Accessing the Menu:**
   - Go to **Tools** -> **休眠/唤醒追踪器 (Sleep/Wake Tracker)**.

2. **Viewing Data:**
   - **显示今日事件 (Show Today's Events)**: View current session stats and list of cycles.
   - **显示昨日事件 (Show Yesterday's Events)**: View yesterday's activity.
   - **浏览历史 (Browse History)**: Navigate past logs. Years and Months are grouped for easy access.

3. **Managing Data:**
   - Go to **数据管理 (Data Management)** submenu.
   - **导出为 CSV (Export to CSV)**: Saves `.sleepwaketracker_export.csv` to your device root.
     - Connect via USB to copy this file to your PC.
   - **从 CSV 导入 (Import from CSV)**: Supports both overwrite and append modes.
   - **清除日志 (Clear Logs)**: Delete today's log or all history.

## CSV Format

The exported CSV uses the following format:
```csv
日期,时间,事件,电量
2026-01-07,14:30:00,WAKE,85.0
2026-01-07,15:00:00,SLEEP,80.0
2026-01-07,15:05:00,WAKE,
```

- Battery field is empty when the reading was unavailable at the time of the event.
- During import, rows with empty or invalid battery values are skipped to prevent data corruption.

## Technical Details

- **Device Support:** Automatically detects storage root for Kindle (`/mnt/us`), Kobo (`/mnt/onboard`), PocketBook (`/mnt/ext1`), and Android (`/sdcard`).
- **Data Storage:** All events are stored in a single file `koreader/settings/sleepwaketracker/all_events.log` with automatic log rotation (1 MB per file, 3 backups retained). Events older than 365 days are automatically cleaned up.
- **Performance:** Minimal impact. Battery updates on wake use tail-only file I/O (no full rewrite). Only runs momentarily during suspend/resume/standby events.
- **Multi-instance Safety:** Cache is invalidated before cross-instance file reads to prevent data loss.