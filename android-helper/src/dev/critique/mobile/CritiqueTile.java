package dev.critique.mobile;

import android.content.SharedPreferences;
import android.os.Build;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
import android.util.Log;

/**
 * Tap to start a critique, tap again to send it. The tile only asks: it logs
 * "toggle", Critique on the Mac (watching logcat over adb) starts or sends, and
 * then tells the tile what it's doing through {@link StateReceiver}.
 */
public class CritiqueTile extends TileService {
    static final String TAG = "CritiqueTile";
    static final String PREFS = "critique";

    /** The tile while it's on screen, so a new state shows right away. */
    private static java.lang.ref.WeakReference<CritiqueTile> showing = new java.lang.ref.WeakReference<>(null);

    static void refresh() {
        CritiqueTile tile = showing.get();
        if (tile != null) tile.render();
    }

    @Override
    public void onStartListening() {
        showing = new java.lang.ref.WeakReference<>(this);
        render();
    }

    @Override
    public void onStopListening() {
        if (showing.get() == this) showing.clear();
    }

    @Override
    public void onClick() {
        Log.i(TAG, "toggle");
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        prefs.edit().putString("state", "asking").putLong("at", System.currentTimeMillis()).apply();
        render();
    }

    private void render() {
        Tile tile = getQsTile();
        if (tile == null) return;
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        String state = prefs.getString("state", "idle");
        // "Asking" with no answer for a while means the Mac isn't listening.
        if ("asking".equals(state) && System.currentTimeMillis() - prefs.getLong("at", 0) > 8000) state = "offline";
        String subtitle;
        switch (state) {
            case "recording": subtitle = "Recording · tap to send"; break;
            case "sending": subtitle = "Sending…"; break;
            case "asking": subtitle = "Asking your Mac…"; break;
            case "offline": subtitle = "Mac not listening"; break;
            case "installing": subtitle = "Installing the fix…"; break;
            case "installed": subtitle = "Fix installed · tap to start"; break;
            default: subtitle = "Tap to start";
        }
        tile.setState("recording".equals(state) ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.setLabel("Critique");
        if (Build.VERSION.SDK_INT >= 29) tile.setSubtitle(subtitle);
        else tile.setContentDescription(subtitle);
        tile.updateTile();
    }
}
