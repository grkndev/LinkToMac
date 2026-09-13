package expo.modules.selfadb

import android.app.Activity
import android.app.KeyguardManager
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast

/**
 * Reads the system clipboard once, sends it to the Mac, and gets out of the way. Launched from
 * the sticky notification's "Send clipboard" action.
 *
 * This is the manual counterpart to [ProcessTextActivity]: it needs no selection, so it's the
 * one path that catches a *programmatic* copy (an in-app "Copy link" / "Copy IBAN" button),
 * which the text-selection toolbar can never see.
 *
 * Two constraints shape it, both from AOSP's `ClipboardService.clipboardAccessAllowed`:
 *
 *  - **Real window focus is required.** The check is `mWm.isUidFocused(uid)`, so a
 *    `Theme.NoDisplay` activity — which is never given a window — would read `null` every time.
 *    The manifest therefore gives this one `Theme.Translucent.NoTitleBar`: an actual window,
 *    just invisible. For the same reason the read happens in [onWindowFocusChanged] rather than
 *    `onCreate`, which runs before focus arrives.
 *  - **A locked device is closed entirely.** `isDeviceLocked` makes the read fail regardless of
 *    focus, so we say so instead of silently sending nothing.
 *
 * It must also stay out of the user's way entirely — they tapped a notification action, not the
 * app. Three manifest bits do that: an empty `taskAffinity` (its own task, so FLAG_ACTIVITY_NEW_TASK
 * can't drag the app's task to the front — that's what made the app visibly open), a theme with
 * `windowAnimationStyle=@null` (no task open/close animation), and `noHistory` +
 * `excludeFromRecents` (never in the recents list). What remains is unavoidable: this window
 * takes input focus for the few milliseconds it lives, because that focus IS the permission.
 *
 * The notification action's PendingIntent targets this activity directly because Android 12+
 * bans notification trampolines through a service or receiver.
 */
class ClipboardReadActivity : Activity() {

  /** onWindowFocusChanged can fire more than once; only the first one does the work. */
  private var handled = false

  override fun onWindowFocusChanged(hasFocus: Boolean) {
    super.onWindowFocusChanged(hasFocus)
    if (!hasFocus || handled) return
    handled = true
    Toast.makeText(this, captureNow(), Toast.LENGTH_SHORT).show()
    finish()
  }

  /** Reads the clipboard and hands it off; returns what to tell the user. */
  private fun captureNow(): String {
    val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
    if (keyguard.isDeviceLocked) return LOCKED

    val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val text = clipboard.primaryClip
      ?.takeIf { it.itemCount > 0 }
      ?.getItemAt(0)
      ?.coerceToText(this)
      ?.toString()

    if (text.isNullOrBlank()) {
      // Either the clipboard really is empty, or the focus gate denied us and handed back null.
      // We can't tell the two apart from here, so say the honest, actionable thing.
      ClipBus.log("manual capture: clipboard empty or unreadable")
      return EMPTY
    }

    ClipForegroundService.submitClip(this, text)
    return if (ClipBus.peerOnline()) SENT else QUEUED
  }

  private companion object {
    const val SENT = "Sent to your Mac"
    const val QUEUED = "Your Mac isn't connected"
    const val LOCKED = "Unlock your phone first"
    const val EMPTY = "Nothing to send"
  }
}
