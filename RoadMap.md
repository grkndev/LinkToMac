### Completed
- [X] Clipboard sync
- [x] Lock your mac from Android
- [x] Auto-Lock your mac when Android moves out of range
- [x] LAN-Direct Mode
- [x] Show battery percent on Android App
- [x] Notifications sync (Android → mac, with native banners)
- [x] Live BLE distance to the paired device on both dashboards
- [x] Read Messages on mac (Android → mac SMS mirroring — conversation threads in the Messages tab; read-only, replying is still upcoming)
- [x] File transfer: clipboard images (bidirectional — a copied image on either device lands on the other's clipboard; auto-fitted under the 1 MiB relay frame cap; phone capture uses the shell daemon + a system Context to read the content:// URI)
- [x] Reply to Messages from mac (1:1 threads — an inline composer on the Mac sends over the relay/LAN, the phone transmits a real SMS via SmsManager and acks back; group threads stay read-only for now)
- [x] File transfer: share sheet (Android → Mac) — two share targets, "Send to Clipboard" (images, downscaled to paste) and "Send as a File" (any type, original quality, chunked + acked, saved to a folder chosen on the Mac), plus Direct Share entries in the sheet's top row. No app UI opens; a toast reports the outcome.
- [x] File transfer: Mac → phone — drag a file onto the dashboard window or the menu-bar icon, or use Finder ▸ Share ▸ "Send to Phone". Chunked + acked like the phone→Mac direction, with a live percentage; lands in the phone's Downloads/Link to Mac with a tap-to-open notification.
### Upcoming
- [ ] FCM push-wake for minimum background battery — while the Mac is offline, drop the persistent relay socket (no idle ping all day) and let a high-priority push wake the phone when the Mac reconnects. Only way to reach ~0 idle battery; relay-path only (not LAN). Big lift: GMS/FCM dependency + the relay must be able to push.
- [ ] Mirror your Android screen to mac
- [ ] Access Phone Gallery from mac
- [ ] Make Call from mac (Review your call history, search contacts, or dial to make calls—from your mac.)