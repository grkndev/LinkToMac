package expo.modules.selfadb

import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

/**
 * Advertises a BLE presence beacon so the paired Mac can lock itself when this phone leaves the
 * room. The service UUID is derived from the pairing room (same derivation as the Mac), so only
 * our Mac matches and it rotates automatically on unpair. Non-connectable — it carries nothing
 * but the UUID; presence is the whole signal. Owned by [ClipForegroundService] so it survives the
 * app being swiped away.
 */
class BleAdvertiser(
  private val context: Context,
  private val log: (String) -> Unit,
) {
  private var advertiser: BluetoothLeAdvertiser? = null
  private var callback: AdvertiseCallback? = null

  fun start(room: String) {
    if (room.isEmpty()) return
    if (!hasAdvertisePermission()) {
      log("ble: missing Nearby Devices (advertise) permission")
      return
    }
    val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    if (adapter == null || !adapter.isEnabled) {
      log("ble: bluetooth off / no adapter")
      return
    }
    val adv = adapter.bluetoothLeAdvertiser
    if (adv == null) {
      log("ble: advertising not supported on this device")
      return
    }
    stop() // replace any running advertisement

    val uuid = serviceUuid(room)
    val settings = AdvertiseSettings.Builder()
      .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
      .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
      .setConnectable(false)
      .build()
    val data = AdvertiseData.Builder()
      .setIncludeDeviceName(false) // a 128-bit UUID already nearly fills the 31-byte advert
      .addServiceUuid(ParcelUuid(uuid))
      .build()
    val cb = object : AdvertiseCallback() {
      override fun onStartSuccess(settingsInEffect: AdvertiseSettings) = log("ble: advertising $uuid")
      override fun onStartFailure(errorCode: Int) = log("ble: advertise failed ($errorCode)")
    }
    try {
      adv.startAdvertising(settings, data, cb)
      advertiser = adv
      callback = cb
    } catch (e: SecurityException) {
      log("ble: advertise SecurityException ${e.message}")
    }
  }

  fun stop() {
    val a = advertiser
    val c = callback
    if (a != null && c != null) {
      try {
        a.stopAdvertising(c)
      } catch (e: Exception) {
        // adapter may already be off; nothing to clean up
      }
    }
    advertiser = null
    callback = null
  }

  private fun hasAdvertisePermission(): Boolean =
    Build.VERSION.SDK_INT < 31 ||
      context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED

  companion object {
    /** `SHA256(utf8(room))` → first 16 bytes → UUID. MUST match `ProximityConfig.serviceUUID` on the Mac. */
    fun serviceUuid(room: String): UUID {
      val digest = MessageDigest.getInstance("SHA-256").digest(room.toByteArray(Charsets.UTF_8))
      val bb = ByteBuffer.wrap(digest, 0, 16)
      return UUID(bb.long, bb.long) // msb = bytes[0..7], lsb = bytes[8..15], big-endian
    }
  }
}
