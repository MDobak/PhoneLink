package com.mdobak.phonelink

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast

/**
 * The "Send to Mac" share target. Files go to the Downloads folder on the Mac. A shared link opens
 * in the Mac browser. Other shared text goes to the Mac clipboard.
 */
class SendActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else -> emptyList()
        }
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim()
        val s = Hub.session
        val mac = s?.macName
        val msg = when {
            mac == null -> "Not connected to your Mac."
            uris.isNotEmpty() -> {
                val sources = Transfers.open(this, uris)
                when {
                    sources.isEmpty() -> "Cannot read the shared files."
                    !Transfers.upload(sources, null) -> "Not connected to your Mac."
                    sources.size == 1 -> "Sending to " + mac
                    else -> "Sending " + sources.size + " files to " + mac
                }
            }
            !text.isNullOrEmpty() -> {
                val link = linkIn(text)
                if (link != null) { s.send(json("t" to "url.open", "url" to link)); "Opening on " + mac }
                else { s.send(json("t" to "clip", "text" to text)); "Copied to the clipboard on " + mac }
            }
            else -> "Nothing to send."
        }
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
        finish()
    }

    /** Apps often share "Title https://...". */
    private fun linkIn(text: String): String? {
        val m = Regex("https?://\\S+").find(text) ?: return null
        // Share the link only when the text is mostly the link.
        return if (m.value.length * 2 >= text.length || text.lines().size <= 2) m.value else null
    }
}
