// SPDX-License-Identifier: AGPL-3.0-or-later
import Flutter
import UIKit
import UserNotifications

public class SteadyApnsPlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
  private var channel: FlutterMethodChannel?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "za.co.openworks.steady/push", binaryMessenger: registrar.messenger())
    let instance = SteadyApnsPlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    UNUserNotificationCenter.current().delegate = instance
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "register":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        DispatchQueue.main.async {
          if granted {
            UIApplication.shared.registerForRemoteNotifications()
          }
          result(granted)
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // APNs handed us a device token: pass it to Dart, which stores it on the server.
  public func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    #if DEBUG
    let sandbox = true   // Xcode debug builds talk to the APNs sandbox
    #else
    let sandbox = false  // TestFlight and App Store builds use production
    #endif
    channel?.invokeMethod("onToken", arguments: ["token": token, "sandbox": sandbox])
  }

  public func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    NSLog("Steady: APNs registration failed: \(error.localizedDescription)")
  }

  // Show notifications as banners even while the app is open.
  public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                     willPresent notification: UNNotification,
                                     withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .list, .sound])
  }

  public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                     didReceive response: UNNotificationResponse,
                                     withCompletionHandler completionHandler: @escaping () -> Void) {
    let kind = response.notification.request.content.userInfo["kind"] as? String ?? ""
    channel?.invokeMethod("onTap", arguments: kind)
    completionHandler()
  }
}
