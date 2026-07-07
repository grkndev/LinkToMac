import { useEffect, useRef, useState } from 'react';
import { Alert, AppState } from 'react-native';

import SelfAdb from './client';

/**
 * The Settings screen's permission / toggle state machine: seeds every switch from the native
 * side on mount, re-checks the system-granted ones whenever the app returns to the foreground
 * (permission prompts and system settings screens background us), and exposes the toggle
 * handlers. Keeps the screen itself purely declarative rows.
 */
export function usePermissionSettings() {
  const [notifIconVisible, setNotifIconVisible] = useState(true);
  const [notifGranted, setNotifGranted] = useState<boolean | null>(null);
  const [notifMirrorOn, setNotifMirrorOn] = useState(true);
  const [notifAccess, setNotifAccess] = useState<boolean | null>(null);
  const [smsMirrorOn, setSmsMirrorOn] = useState(true);
  const [smsAccess, setSmsAccess] = useState<boolean | null>(null);
  const [sendImagesOn, setSendImagesOn] = useState(true);
  const [batteryOk, setBatteryOk] = useState<boolean | null>(null);
  const [proximityOn, setProximityOn] = useState(false);
  // True while a proximity toggle is mid-flight. The permission prompt below
  // backgrounds the app, so the AppState "active" re-check would otherwise read
  // a not-yet-started beacon and clobber the switch back OFF (issue #2).
  const togglingProximity = useRef(false);

  useEffect(() => {
    // System-granted state that can change behind our back (prompts / settings screens):
    // read on mount AND re-read on every return to the foreground.
    const recheckGrants = () => {
      SelfAdb.hasIgnoreBatteryOptimizations()
        .then(setBatteryOk)
        .catch(() => {});
      SelfAdb.hasPostNotifications()
        .then(setNotifGranted)
        .catch(() => {});
      SelfAdb.hasNotificationAccess()
        .then(setNotifAccess)
        .catch(() => {});
      SelfAdb.hasSmsAccess()
        .then(setSmsAccess)
        .catch(() => {});
      // The OS may have revoked Nearby Devices behind our back -> reflect the real
      // beacon state. Skip while a toggle is in flight so we don't read the beacon
      // before it has started and snap the switch back OFF (issue #2).
      if (!togglingProximity.current) {
        SelfAdb.getProximityAdvertise()
          .then(setProximityOn)
          .catch(() => {});
      }
    };

    // App-owned prefs only change through this screen — reading them once on mount is enough.
    SelfAdb.getStatusNotificationVisible()
      .then(setNotifIconVisible)
      .catch(() => {});
    SelfAdb.getNotificationForwarding()
      .then(setNotifMirrorOn)
      .catch(() => {});
    SelfAdb.getSmsForwarding()
      .then(setSmsMirrorOn)
      .catch(() => {});
    SelfAdb.getSendImages()
      .then(setSendImagesOn)
      .catch(() => {});
    recheckGrants();

    const sub = AppState.addEventListener('change', (next) => {
      if (next === 'active') recheckGrants();
    });
    return () => sub.remove();
  }, []);

  const toggleNotifIcon = (visible: boolean) => {
    setNotifIconVisible(visible);
    SelfAdb.setStatusNotificationVisible(visible).catch(() => {});
  };

  const toggleNotifMirror = (on: boolean) => {
    setNotifMirrorOn(on);
    SelfAdb.setNotificationForwarding(on).catch(() => {});
  };

  const toggleSmsMirror = (on: boolean) => {
    setSmsMirrorOn(on);
    SelfAdb.setSmsForwarding(on).catch(() => {});
  };

  const toggleSendImages = (on: boolean) => {
    setSendImagesOn(on);
    SelfAdb.setSendImages(on).catch(() => {});
  };

  // Auto-lock needs Nearby Devices to advertise the BLE beacon; ask before enabling.
  const toggleProximity = (on: boolean) => {
    if (!on) {
      setProximityOn(false);
      SelfAdb.setProximityAdvertise(false).catch(() => {});
      return;
    }
    // Reflect the user's intent immediately, then hold the AppState re-check off
    // (togglingProximity) until the beacon has actually started, so the first tap
    // sticks even though the permission prompt backgrounds us (issue #2).
    togglingProximity.current = true;
    setProximityOn(true);
    SelfAdb.requestNearbyDevicesPermission()
      .then((granted) => {
        if (!granted) {
          setProximityOn(false);
          Alert.alert(
            'Permission needed',
            'Allow “Nearby devices” so your Mac can tell when this phone leaves.',
          );
          return;
        }
        return SelfAdb.setProximityAdvertise(true);
      })
      .catch(() => setProximityOn(false))
      .finally(() => {
        togglingProximity.current = false;
      });
  };

  const requestNotifPermission = () => {
    SelfAdb.requestPostNotifications()
      .then(setNotifGranted)
      .catch(() => {});
  };

  const requestSmsPermission = () => {
    SelfAdb.requestSmsAccess()
      .then(setSmsAccess)
      .catch(() => {});
  };

  return {
    notifIconVisible,
    toggleNotifIcon,
    notifGranted,
    requestNotifPermission,
    notifMirrorOn,
    toggleNotifMirror,
    notifAccess,
    smsMirrorOn,
    toggleSmsMirror,
    smsAccess,
    requestSmsPermission,
    sendImagesOn,
    toggleSendImages,
    batteryOk,
    proximityOn,
    toggleProximity,
  };
}
