"""Run AFTER `flutter create --platforms=android --org com.personal.finance .`.
Configures Android-generated project for biometric and encrypted-storage plugins.
"""
from pathlib import Path

root = Path('android/app')
assert root.exists(), 'Run flutter create first.'
activity_files = list((root / 'src/main').rglob('MainActivity.kt'))
assert activity_files, 'Flutter MainActivity.kt not found.'
for activity in activity_files:
    old = activity.read_text()
    new = old.replace('import io.flutter.embedding.android.FlutterActivity',
                      'import io.flutter.embedding.android.FlutterFragmentActivity')
    new = new.replace('FlutterActivity()', 'FlutterFragmentActivity()')
    activity.write_text(new)
    print('Configured', activity)

manifest = root / 'src/main/AndroidManifest.xml'
s = manifest.read_text()
if 'android.permission.USE_BIOMETRIC' not in s:
    idx = s.find('<application')
    assert idx != -1
    s = s[:idx] + '<uses-permission android:name="android.permission.USE_BIOMETRIC"/>\n    ' + s[idx:]
if 'android:allowBackup' not in s:
    s = s.replace('<application', '<application android:allowBackup="false"', 1)
manifest.write_text(s)

# Configures Android minimum API level: biometric plugin requires Android 7.0 (API 24).
for name in ('build.gradle.kts', 'build.gradle'):
    gradle = root / name
    if not gradle.exists():
        continue
    content = gradle.read_text()
    content = content.replace('minSdk = flutter.minSdkVersion', 'minSdk = 24')
    content = content.replace('minSdkVersion flutter.minSdkVersion', 'minSdkVersion 24')
    gradle.write_text(content)
    print('Configured', gradle)

# Add AppCompat dependency for old Android launch theme for biometric dialogs.
# In default modern Flutter template using androidx appcompat isn't necessarily available;
# include it explicitly for the Android theme reference.
for name in ('build.gradle.kts', 'build.gradle'):
    gradle = root / name
    if not gradle.exists():
        continue
    content = gradle.read_text()
    if 'androidx.appcompat:appcompat' not in content:
        if 'dependencies {' in content:
            content = content.replace('dependencies {',
                'dependencies {\n    implementation("androidx.appcompat:appcompat:1.7.1")', 1)
        else:
            content += '\n\ndependencies {\n    implementation("androidx.appcompat:appcompat:1.7.1")\n}\n'
        gradle.write_text(content)

for styles in (root / 'src/main/res/values/styles.xml',
               root / 'src/main/res/values-night/styles.xml'):
    if styles.exists():
        s = styles.read_text()
        import re
        s = re.sub(r'(<style name="LaunchTheme" parent=")[^"]+(".*?>)',
                   r'\1Theme.AppCompat.DayNight.NoActionBar\2', s)
        styles.write_text(s)

print('Android app configured.')
