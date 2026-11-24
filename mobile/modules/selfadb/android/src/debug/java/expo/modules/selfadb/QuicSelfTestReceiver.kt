package expo.modules.selfadb

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import androidx.core.content.ContextCompat

/**
 * Debug builds only (the `src/debug` source set): lets `mobile/scripts/quic-device-test.sh` start the on-device QUIC self-test with
 * `adb shell am broadcast -n <package>/expo.modules.selfadb.QuicSelfTestReceiver -a expo.modules.selfadb.QUIC_SELFTEST --es tamper fp`.
 * The foreground service is not exported, so `adb` cannot start it directly. A running service is asked straight away; otherwise it
 * is started with the same action.
 */
class QuicSelfTestReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return
    if (intent.action == ClipForegroundService.ACTION_QUIC_STATUS) {
      ClipForegroundService.instance?.logQuicStatus()
      return
    }
    if (intent.action == ClipForegroundService.ACTION_LAN_DISCOVERY) {
      ClipForegroundService.instance?.debugSetDiscovery(intent.getBooleanExtra("on", true))
      return
    }
    if (intent.action == "expo.modules.selfadb.MEDIA_FAKE") {
      FakeMedia.start(context)
      return
    }
    if (intent.action == "expo.modules.selfadb.MEDIA_FAKE_STOP") {
      FakeMedia.stop()
      return
    }
    if (intent.action == ClipForegroundService.ACTION_SEND_FILE) {
      intent.getStringExtra("name")?.let { ClipForegroundService.instance?.debugSendFile(it) }
      return
    }
    if (intent.action == ClipForegroundService.ACTION_LAN_STATUS) {
      ClipForegroundService.instance?.debugLogLink()
      return
    }
    if (intent.action == ClipForegroundService.ACTION_LAN_FORGET) {
      ClipForegroundService.instance?.debugForgetLan()
      return
    }
    if (intent.action != ClipForegroundService.ACTION_QUIC_SELFTEST) return
    val tamper = intent.getStringExtra(ClipForegroundService.EXTRA_TAMPER)
    val running = ClipForegroundService.instance
    if (running != null) {
      running.runQuicSelfTest(tamper)
    } else {
      ContextCompat.startForegroundService(
        context,
        Intent(context, ClipForegroundService::class.java).setAction(ClipForegroundService.ACTION_QUIC_SELFTEST)
          .putExtra(ClipForegroundService.EXTRA_TAMPER, tamper),
      )
    }
  }
}
