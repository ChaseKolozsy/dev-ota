package io.github.chasekolozsy.devota.car

import android.content.Context
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent

/**
 * DevOTA's media session. The car's AVRCP next / previous / play-pause reach
 * it only while DevOTA is the app that most recently played audio locally
 * (proposal F1-F3), which CarSpeaker's own-player speech maintains.
 * onMediaButtonEvent is overridden so no framework default (for example a
 * HEADSETHOOK double-tap turning into skip) reinterprets a press.
 */
internal class CarMediaSession(ctx: Context, private val listener: Listener) {
    interface Listener {
        fun onMediaKey(event: KeyEvent)
        fun onTransport(name: String, detail: Map<String, Any?>)
    }

    private val session = MediaSession(ctx.applicationContext, "DevOTA car")

    init {
        session.setCallback(object : MediaSession.Callback() {
            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                val event: KeyEvent? = if (Build.VERSION.SDK_INT >= 33) {
                    mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                }
                if (event == null) return super.onMediaButtonEvent(mediaButtonIntent)
                listener.onMediaKey(event)
                return true
            }
            override fun onPlay() = listener.onTransport("onPlay", emptyMap())
            override fun onPause() = listener.onTransport("onPause", emptyMap())
            override fun onSkipToNext() = listener.onTransport("onSkipToNext", emptyMap())
            override fun onSkipToPrevious() = listener.onTransport("onSkipToPrevious", emptyMap())
            override fun onStop() = listener.onTransport("onStop", emptyMap())
            override fun onFastForward() = listener.onTransport("onFastForward", emptyMap())
            override fun onRewind() = listener.onTransport("onRewind", emptyMap())
            override fun onSeekTo(pos: Long) = listener.onTransport("onSeekTo", mapOf("pos" to pos))
            override fun onCustomAction(action: String, extras: Bundle?) =
                listener.onTransport("onCustomAction", mapOf("action" to action.take(80)))
        }, Handler(Looper.getMainLooper()))
        @Suppress("DEPRECATION")
        session.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
        setTitle("DevOTA car mode")
        setPlaying(false)
        session.isActive = true
    }

    fun setTitle(title: String) {
        session.setMetadata(MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title.take(80))
            .putString(MediaMetadata.METADATA_KEY_ARTIST, "DevOTA")
            .build())
    }

    fun setPlaying(playing: Boolean) {
        session.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SKIP_TO_NEXT or
                PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_STOP)
            .setState(if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                PlaybackState.PLAYBACK_POSITION_UNKNOWN, if (playing) 1f else 0f)
            .build())
    }

    fun release() {
        try {
            session.isActive = false
            session.release()
        } catch (_: Exception) {}
    }
}
