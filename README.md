# MyMoney — Personal Expense Tracker (Flutter source)

> **IMPORTANT: This ZIP is SOURCE CODE, not an APK.** It has not been compiled
> or installed in the current environment. Flutter/Android SDK and outbound
> download access are not available in the environment that created this ZIP.
>
> The initial code is for personal testing, not a security-audited finance app.

## Included in this prototype

- Android Flutter material-3 interface with income/expense add, edit, delete.
- Category donut chart, month filter, account filter, running balance.
- On-device SQLite (no backend, no account registration).
- PIN lock (in Android encrypted secure storage), optional biometric unlock.
- Encrypted backup using password-derived AES-256-GCM and `.mymoney` file.
- Android Share Sheet: choose Gmail to send encrypted backup manually.
- Restore replaces all entries only after successful decryption/validation.
- Optional encrypted local copy refreshed when app data is loaded/edited.

## Not yet implemented

- **Automatic email dispatch is NOT implemented.** A Google OAuth + Gmail API
  integration, scheduled work, and real-device testing are required. Android
  background execution does not promise exact delivery time.
- Custom accounts/categories, recurring bills, export CSV, cloud sync, budgets.
- Stronger security hardening and testing across Android devices.
- Pixel-perfect recreation of any proprietary existing finance application.
- No pre-built or independently verified APK is included.

## Build APK with GitHub Actions (Android phone only needed for installation)

1. Unzip the downloaded source on a computer.
2. Create a **private** GitHub repository called `mymoney`.
3. Upload **all files including `.github/workflows/build-apk.yml`** to that repository.
   If uploading through browser, hidden `.github` might need to be selected
   explicitly. No passwords should be committed to the repository.
4. Open your repository on GitHub → **Actions** → **Build MyMoney Android APK**
   → **Run workflow**.
5. After a **successful** workflow run, open the run → **Artifacts** →
   `MyMoney-Android-APK` and download it.
6. Unzip the artifact. Copy `app-debug.apk` to your Android phone and install it.
   Android may request permission to install apps from the Files application.
7. Open MyMoney, add some entries, and email a backup from Settings.
8. Verify backup recovery **with test data** before storing important records.

If the workflow fails, read the error under Actions. This ZIP has not been run
through `flutter analyze`, `flutter test`, or an Android build in this environment;
some platform/dependency adjustments might be necessary.

## Local Windows setup (Flutter + Android Studio installed)

```powershell
flutter doctor
flutter create --platforms=android --org com.personal.finance --project-name mymoney .
python scripts/configure_android.py
flutter pub get
flutter analyze
flutter build apk --debug
```

APK location: `build/app/outputs/flutter-apk/app-debug.apk`.

### Important backup notes

- Settings → **Email encrypted backup** prompts for a backup passphrase of at
  least 10 characters; it opens the Android share dialog. You must choose Gmail,
  enter your own email address, and tap Send.
- Settings → **Restore encrypted backup** reads a `.mymoney` file and asks for
  its original passphrase; it **replaces** the local transaction records.
- If the backup password is forgotten, its contents cannot be decrypted.
- Automatic local copy is kept in the app private storage only; it is NOT sent
  as an email. **Uninstalling the app may erase both DB and this local copy.**
- SQLite database records are in an app-private database, but the database file
  itself is not encrypted at rest. PIN locking is a UI access control, not
  whole-database encryption.
- Disable Android auto-backup to avoid keystore restoration issues.
- App debug builds are convenient for personal install/testing. Debug signature
  and release signing have different installation/upgrading characteristics.
