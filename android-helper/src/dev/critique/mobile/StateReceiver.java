package dev.critique.mobile;

import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.service.quicksettings.TileService;

/** The Mac sets the tile's state: idle, recording, or sending. */
public class StateReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String state = intent.getStringExtra("state");
        if (state == null) return;
        context.getSharedPreferences(CritiqueTile.PREFS, Context.MODE_PRIVATE).edit()
                .putString("state", state).putLong("at", System.currentTimeMillis()).apply();
        CritiqueTile.refresh();
        TileService.requestListeningState(context, new ComponentName(context, CritiqueTile.class));
    }
}
