// SPDX-License-Identifier: AGPL-3.0-or-later
package za.co.openworks.steady.fcm;

import android.Manifest;
import android.app.Activity;
import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;

import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;
import com.google.firebase.messaging.FirebaseMessaging;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

import java.util.ArrayList;
import java.util.List;

/**
 * Firebase Cloud Messaging for Steady on Android, without google-services.json: the app passes in
 * the Firebase settings it was built with. This asks to show notifications, returns the phone's
 * token and reports taps. The notifications themselves are shown by Firebase while the app is in
 * the background and by {@link SteadyFcmService} while it's open; both say only "New notification".
 *
 * <pre>
 *   Dart -> Android  register({apiKey, appId, senderId, projectId})  the token, or null if the
 *                                                                    phone doesn't allow notifications
 *   Dart -> Android  unregister({the same})                          deletes the token
 *   Android -> Dart  onTap()                                         a notification was tapped
 * </pre>
 */
public class SteadyFcmPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
        PluginRegistry.NewIntentListener, PluginRegistry.RequestPermissionsResultListener {
    static final String CHANNEL = "za.co.openworks.steady/fcm";
    /** On the intent of a notification Steady showed itself (the app was open). */
    static final String TAP_EXTRA = "za.co.openworks.steady.push";
    private static final int PERMISSION_REQUEST = 7301;

    private interface Answer {
        void allowed(boolean yes);
    }

    private MethodChannel channel;
    private Context context;
    private ActivityPluginBinding activity;
    private final List<Answer> waiting = new ArrayList<>();

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
    }

    @Override
    public void onAttachedToActivity(ActivityPluginBinding binding) {
        activity = binding;
        binding.addOnNewIntentListener(this);
        binding.addRequestPermissionsResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        // a permission question still open is answered to the recreated activity
        detach();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        detach();
        answer(false);
    }

    private void detach() {
        if (activity == null) return;
        activity.removeOnNewIntentListener(this);
        activity.removeRequestPermissionsResultListener(this);
        activity = null;
    }

    // A tap on a notification while the app is running opens it again with that notification's
    // intent. (Opened from scratch, the app loads everything anyway.)
    @Override
    public boolean onNewIntent(Intent intent) {
        if (fromNotification(intent) && channel != null) channel.invokeMethod("onTap", null);
        return false;
    }

    static boolean fromNotification(Intent intent) {
        Bundle extras = intent == null ? null : intent.getExtras();
        return extras != null
                && (extras.containsKey(TAP_EXTRA) || extras.containsKey("google.message_id") || extras.containsKey("message_id"));
    }

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
            case "register":
                register(call, result);
                break;
            case "unregister":
                unregister(call, result);
                break;
            default:
                result.notImplemented();
        }
    }

    private void register(MethodCall call, MethodChannel.Result result) {
        try {
            firebase(call);
        } catch (RuntimeException e) {
            result.error("firebase", e.getMessage(), null);
            return;
        }
        SteadyFcmService.ensureChannel(context);
        askToNotify(allowed -> {
            if (!allowed) {
                result.success(null);
                return;
            }
            FirebaseMessaging.getInstance().getToken().addOnCompleteListener(task -> {
                if (task.isSuccessful() && task.getResult() != null) {
                    result.success(task.getResult());
                } else {
                    Exception e = task.getException();
                    result.error("token", e == null ? "no token" : e.getMessage(), null);
                }
            });
        });
    }

    private void unregister(MethodCall call, MethodChannel.Result result) {
        try {
            firebase(call);
        } catch (RuntimeException e) {
            result.success(null);
            return;
        }
        FirebaseMessaging.getInstance().deleteToken().addOnCompleteListener(task -> result.success(null));
    }

    /** The default Firebase app, set up once per process from the settings the app was built with. */
    private FirebaseApp firebase(MethodCall call) {
        for (FirebaseApp app : FirebaseApp.getApps(context)) {
            if (FirebaseApp.DEFAULT_APP_NAME.equals(app.getName())) return app;
        }
        FirebaseOptions options = new FirebaseOptions.Builder()
                .setApiKey(arg(call, "apiKey"))
                .setApplicationId(arg(call, "appId"))
                .setGcmSenderId(arg(call, "senderId"))
                .setProjectId(arg(call, "projectId"))
                .build();
        return FirebaseApp.initializeApp(context, options);
    }

    private static String arg(MethodCall call, String key) {
        Object v = call.argument(key);
        return v == null ? "" : v.toString();
    }

    // Android 13 and later ask the person first; on any version they may have switched Steady's
    // notifications off in the phone's settings.
    private void askToNotify(Answer then) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            Activity a = activity == null ? null : activity.getActivity();
            if (a == null) {
                then.allowed(false);
                return;
            }
            waiting.add(then);
            if (waiting.size() == 1) {
                a.requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, PERMISSION_REQUEST);
            }
            return;
        }
        then.allowed(notificationsOn());
    }

    private boolean notificationsOn() {
        NotificationManager nm = context.getSystemService(NotificationManager.class);
        return nm == null || nm.areNotificationsEnabled();
    }

    @Override
    public boolean onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        if (requestCode != PERMISSION_REQUEST) return false;
        boolean granted = grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED;
        answer(granted && notificationsOn());
        return true;
    }

    private void answer(boolean allowed) {
        List<Answer> all = new ArrayList<>(waiting);
        waiting.clear();
        for (Answer w : all) w.allowed(allowed);
    }
}
