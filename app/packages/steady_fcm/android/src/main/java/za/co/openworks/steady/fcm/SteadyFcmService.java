// SPDX-License-Identifier: AGPL-3.0-or-later
package za.co.openworks.steady.fcm;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

/**
 * Steady's notifications while the app is open. (In the background Firebase shows them itself, in
 * the channel the manifest names.) Whatever arrives, the phone shows the same words.
 */
public class SteadyFcmService extends FirebaseMessagingService {
    static final String CHANNEL_ID = "steady_updates";
    static final String TITLE = "Steady";
    static final String BODY = "New notification";

    @Override
    public void onMessageReceived(RemoteMessage message) {
        show(this);
    }

    // A new token while the app is closed needs nothing here: the app sends its current token to
    // the server each time it opens, and the server forgets the tokens Google says are gone.
    @Override
    public void onNewToken(String token) {
    }

    /** Steady's one channel. Made again each time so its name and description stay current. */
    static void ensureChannel(Context context) {
        NotificationManager nm = context.getSystemService(NotificationManager.class);
        if (nm == null) return;
        NotificationChannel ch = new NotificationChannel(CHANNEL_ID, "Updates", NotificationManager.IMPORTANCE_HIGH);
        ch.setDescription("Something new in Steady");
        ch.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
        nm.createNotificationChannel(ch);
    }

    static void show(Context context) {
        ensureChannel(context);
        NotificationManager nm = context.getSystemService(NotificationManager.class);
        if (nm == null) return;
        Notification.Builder b = new Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(icon(context))
                .setContentTitle(TITLE)
                .setContentText(BODY)
                .setAutoCancel(true)
                .setVisibility(Notification.VISIBILITY_PRIVATE);
        Intent open = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (open != null) {
            // as Firebase does: back to the running app, which hears of the tap (onNewIntent)
            open.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP);
            open.putExtra(SteadyFcmPlugin.TAP_EXTRA, true);
            b.setContentIntent(PendingIntent.getActivity(context, 0, open,
                    PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
        }
        nm.notify((int) (System.currentTimeMillis() % 100000), b.build());
    }

    // Steady's mark on its own (the launcher icon's foreground layer): the status bar shows its
    // outline. scripts/patch_android.py gives Firebase the same one for background notifications.
    static int icon(Context context) {
        int id = context.getResources().getIdentifier("ic_launcher_foreground", "mipmap", context.getPackageName());
        return id != 0 ? id : context.getApplicationInfo().icon;
    }
}
