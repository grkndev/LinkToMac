package expo.modules.selfadb

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast

/**
 * Our entry in the text-selection toolbar, next to Copy and Share. Select text anywhere, tap
 * it, and the selection goes straight to the Mac.
 *
 * This is the one capture path that needs nothing at all — no ADB, no Wi-Fi, no runtime
 * permission, no special access — because the text arrives in [Intent.EXTRA_PROCESS_TEXT]
 * rather than being read off the clipboard. Nothing here touches [android.content.ClipboardManager],
 * so the focus gate that forces the rest of the pipeline through a shell daemon never applies.
 * That's also why `Theme.NoDisplay` is correct in the manifest: we need no window, and asking
 * for one would only make the tap flicker.
 *
 * Known gaps, all by AOSP design and with no workaround:
 *  - Password fields: `TextView.canProcessText()` -> `canShare()` -> `canCopy()` returns false
 *    under `PasswordTransformationMethod`, so no toolbar entry appears at all (not ours, not
 *    Copy, not Share). `textVisiblePassword` fields behave normally.
 *  - Views with `getId() == View.NO_ID`: `canProcessText()` requires an id, so some custom
 *    views never show the action.
 *  - Programmatic copies (an in-app "Copy link" button) leave no selection, so there is no
 *    toolbar to hang off — the notification's "Send clipboard" action covers those instead
 *    (see [ClipboardReadActivity]).
 *
 * The label shown in the toolbar is deliberately left off the manifest entry so it inherits
 * the application label — that makes the dev and release installs distinguishable ("LinkToMac
 * (Dev)" vs "Link to Mac") without the module having to know which variant it was built into.
 */
class ProcessTextActivity : Activity() {

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val text = intent?.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
    if (text.isNullOrBlank()) {
      finish()
      return
    }

    ClipForegroundService.submitClip(this, text)
    // Be honest about what just happened: the send is queued, not acknowledged. With a
    // no-display activity and an unchanged screen, no feedback at all reads as a dead button.
    Toast.makeText(this, if (ClipBus.peerOnline()) SENT else QUEUED, Toast.LENGTH_SHORT).show()

    // No setResult(): we're not transforming the selection, so editable and read-only fields
    // behave identically.
    finish()
  }

  private companion object {
    const val SENT = "Sent to your Mac"
    const val QUEUED = "Your Mac isn't connected"
  }
}
