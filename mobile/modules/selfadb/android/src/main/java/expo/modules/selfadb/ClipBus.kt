package expo.modules.selfadb

import android.util.Log

/**
 * Process-wide bridge between the foreground service (which survives the app
 * being swiped away) and the Expo module (which only exists while the JS
 * runtime is alive). The service always posts here; the module attaches/detaches
 * its callbacks in OnCreate/OnDestroy. When the app is gone the callbacks are
 * null and the service simply carries on (logging + future relay forwarding).
 */
object ClipBus {
  @Volatile var onClip: ((String, Double) -> Unit)? = null
  @Volatile var onLog: ((String) -> Unit)? = null

  fun clip(text: String, ts: Double) {
    onClip?.invoke(text, ts)
  }

  fun log(msg: String) {
    Log.i("LinkToMac", msg) // always in logcat, even when the app is closed
    onLog?.invoke(msg)
  }
}
