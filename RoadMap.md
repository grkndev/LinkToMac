### Completed
- [X] Clipboard sync
- [x] Lock your mac from Android
- [x] Auto-Lock your mac when Android moves out of range
- [x] LAN-Direct Mode
- [x] Show battery percent on Android App
- [x] Notifications sync (Android → mac, with native banners)
- [x] Live BLE distance to the paired device on both dashboards
- [x] Read Messages on mac (Android → mac SMS mirroring — conversation threads in the Messages tab; read-only, replying is still upcoming)
### Upcoming
- [ ] FCM push-wake for minimum background battery — while the Mac is offline, drop the persistent relay socket (no idle ping all day) and let a high-priority push wake the phone when the Mac reconnects. Only way to reach ~0 idle battery; relay-path only (not LAN). Big lift: GMS/FCM dependency + the relay must be able to push.
- [ ] Mirror your Android screen to mac
- [ ] File transfer between your devices (Only images smaller than 256 KB/`paylaod limit`)
- [ ] Access Phone Gallery from mac
- [ ] Reply to Messages from mac (reading texts is done — sending a reply over the relay back to the phone's SMS stack is the remaining half.)
- [ ] Make Call from mac (Review your call history, search contacts, or dial to make calls—from your mac.)