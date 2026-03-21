import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    /// Shared instance for accessing orientation lock from any view controller.
    static var shared: AppDelegate {
        UIApplication.shared.delegate as! AppDelegate
    }

    var window: UIWindow?

    /// Controls the supported interface orientations app-wide.
    /// Defaults to portrait; set to .landscape to lock landscape, .portrait to unlock.
    var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ViewController()
        window?.makeKeyAndVisible()

        // Keep screen on while app is open
        application.isIdleTimerDisabled = true

        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return orientationLock
    }
}
