// One-time project setup. Run from the project folder (where pubspec.yaml is):
//   dart tool/setup.dart
// Needs Flutter installed and on your PATH (flutter doctor should pass).

import 'dart:io';

Future<int> run(String cmd, List<String> args) async {
  stdout.writeln('\n> $cmd ${args.join(' ')}');
  final p = await Process.start(cmd, args, runInShell: true, mode: ProcessStartMode.inheritStdio);
  return p.exitCode;
}

Never fail(String msg) {
  stderr.writeln('\nSETUP STOPPED: $msg');
  exit(1);
}

Future<void> main() async {
  if (!File('pubspec.yaml').existsSync() || !File('lib/main.dart').existsSync()) {
    fail('Run this from the project folder (the one containing pubspec.yaml and lib/main.dart).');
  }

  // 1. Remember our own files so `flutter create` can never overwrite them.
  final mainDart = File('lib/main.dart').readAsStringSync();
  final pubspec = File('pubspec.yaml').readAsStringSync();

  // 2. Generate the Android platform project.
  var code = await run('flutter', [
    'create',
    '--platforms=android',
    '--project-name=takatecha_ecopoints',
    '--org=com.takatecha',
    '.',
  ]);
  if (code != 0) fail('flutter create failed. Check that Flutter is installed (run: flutter doctor).');

  // 3. Restore our files and drop the default test (it expects the template app).
  File('lib/main.dart').writeAsStringSync(mainDart);
  File('pubspec.yaml').writeAsStringSync(pubspec);
  final defaultTest = File('test/widget_test.dart');
  if (defaultTest.existsSync()) defaultTest.deleteSync();

  // 4. Android manifest: camera + internet permissions and the app name.
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  if (!manifest.existsSync()) fail('android/app/src/main/AndroidManifest.xml was not created.');
  var m = manifest.readAsStringSync();
  if (!m.contains('android.permission.CAMERA')) {
    const perms = '    <uses-permission android:name="android.permission.INTERNET"/>\n'
        '    <uses-permission android:name="android.permission.CAMERA"/>\n'
        '    <uses-feature android:name="android.hardware.camera" android:required="false"/>\n';
    m = m.replaceFirst('<application', '$perms    <application');
  }
  m = m.replaceFirst(RegExp(r'android:label="[^"]*"'), 'android:label="Taka Techa"');
  manifest.writeAsStringSync(m);

  // 5. The barcode scanner needs Android 6.0 (API 23) or newer.
  for (final path in ['android/app/build.gradle.kts', 'android/app/build.gradle']) {
    final f = File(path);
    if (f.existsSync()) {
      f.writeAsStringSync(f.readAsStringSync().replaceAll('flutter.minSdkVersion', '23'));
    }
  }

  // 6. Dependencies, then the logo as native splash screen and app icon.
  code = await run('flutter', ['pub', 'get']);
  if (code != 0) fail('flutter pub get failed. Check your internet connection.');
  await run('dart', ['run', 'flutter_native_splash:create']);
  await run('dart', ['run', 'flutter_launcher_icons']);

  stdout.writeln('\nDone. Connect an Android phone (USB debugging on) and run:  flutter run');
}
