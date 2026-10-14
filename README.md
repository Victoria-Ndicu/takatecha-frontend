# Taka Techa EcoPoints (Flutter, Android)

Recycler app: Splash (logo) -> Login -> Scan -> Result -> Wallet.
Backend: Oracle ORDS REST APIs on OCI Autonomous Database.

## Set up (one time)
1. Install Flutter and Android Studio (for the Android SDK). Run `flutter doctor` until Android is ticked.
2. Unzip this folder and open a terminal inside it (the folder with `pubspec.yaml`).
3. Run:
   ```
   dart tool/setup.dart
   ```
   It generates the Android project, adds the camera and internet permissions, sets the minimum Android version to 6.0, installs the packages, and applies your logo as the splash screen and app icon.
4. Plug in an Android phone (USB debugging on) and run:
   ```
   flutter run
   ```
   Test the camera on a real phone, not an emulator.

## What is in this folder
| Path | Purpose |
|---|---|
| `lib/main.dart` | The whole app |
| `pubspec.yaml` | Packages, logo assets, splash and icon settings |
| `assets/logo.png` | Your logo |
| `tool/setup.dart` | The one-time setup script above |

## Demo mode vs Oracle backend
- `ApiService.baseUrl` in `lib/main.dart` is empty, so the app runs with no backend: any login works, and barcodes ending in an even digit earn 2 points (promo), others 1. A "Demo scan" button appears for emulators.
- To connect Oracle, set `baseUrl` to your ORDS base URL. The Demo scan button then disappears.

## ORDS endpoints the app calls
| Method | Path | Request | Response |
|---|---|---|---|
| POST | /login | `{"username","password"}` | `{"token":"..."}` |
| POST | /scan | `{"barcode","location_id"}` + `Authorization: Bearer <token>` | `{"points","brand","product","message","balance","promo"}` |

`message` is `"OK"` for a recognised product; anything else is shown as "Not recognised yet". `promo` is optional (for example "2x partner promo").

## Build an installable APK
```
flutter build apk --release
```
The file is created at `build/app/outputs/flutter-apk/app-release.apk`.
