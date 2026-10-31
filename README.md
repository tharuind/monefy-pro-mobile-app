# My Money — Personal Expense Tracker (Flutter source)

> **IMPORTANT: This ZIP is SOURCE CODE, not an APK.** It has not been compiled
> or installed in the current environment. Flutter/Android SDK and outbound
> download access are not available in the environment that created this ZIP.
>
> The initial code is for personal testing, not a security-audited finance app.

## Included in this prototype

- Android Flutter material-3 interface with income/expense add, edit, delete.
- Category donut chart, month filter, account filter, running balance.
- On-device SQLite with a migration-safe, durable sync outbox.
- Google sign-in and per-user Firestore synchronization. Sign into the same
  Google account on another device to download its transactions and categories.
- PIN lock (in Android encrypted secure storage), optional biometric unlock.
- Encrypted backup using password-derived AES-256-GCM and `.mymoney` file.
- Android Share Sheet: choose Gmail to send encrypted backup manually.
- Restore validates the complete encrypted backup and merges records without clearing existing entries.
- Optional encrypted local copy refreshed when app data is loaded/edited.

## Not yet implemented

- **Automatic email dispatch is NOT implemented.** A Google OAuth + Gmail API
  integration, scheduled work, and real-device testing are required. Android
  background execution does not promise exact delivery time.
- Recurring bills, export CSV, budgets.
- Stronger security hardening and testing across Android devices.
- Pixel-perfect recreation of any proprietary existing finance application.
- No pre-built or independently verified APK is included.

## Offline storage, Firebase sync, and PWA setup

Local transactions are written to SQLite before any network request. A schema
migration adds stable UUIDs and timestamps without deleting or replacing the
existing `entries` table. A SQLite outbox records each pending upsert in the
same local database; edits replace the pending operation for that UUID, and
deletes are durable tombstones rather than physical deletes. Firestore retries
use the UUID as the document ID. Concurrent edits use last-write-wins by
`updatedAt`, then the stable device ID for equal timestamps. Tombstones take
part in the same comparison, so an older copy on another device cannot
undelete a newer deletion. Always verify the UI says **Synced**; having network
connectivity alone does not mean sync succeeded.

This repository includes a Flutter web shell and the SQLite WASM/shared-worker
assets, but Firebase still needs project-specific configuration. Never put a
private key or service-account credential in this app.

1. Install Flutter, Android Studio/Xcode as needed, Node.js, and the Firebase
   CLI. Generate platform shells in a separate directory so Flutter does not
   overwrite the existing app source or manifest:

   ```powershell
   flutter create --platforms=android,ios --org com.personal.finance --project-name mymoney platform_shell
   Copy-Item .\platform_shell\android .\android -Recurse
   Copy-Item .\platform_shell\ios .\ios -Recurse
   Copy-Item .\platform_shell\.metadata .\.metadata
   ```

   Do not copy the generated `lib/` or `pubspec.yaml` over this project's
   files. The existing `web/` folder is already configured for the PWA; do
   not replace it with the unmodified generated template. On Windows, iOS
   builds require macOS/Xcode.
2. Create a Firebase project. Add Android, iOS, and Web apps using the package
   ID / bundle ID generated for this project. In Firebase Console → **Authentication
   → Sign-in method**, enable **Google**. Add the deployed web hostname and
   `localhost` to **Authorized domains**.
3. Install FlutterFire CLI and configure the platforms. Register the Android
   package ID generated for this app in Firebase, enable Google in Firebase
   Authentication, and add the Android SHA-1 fingerprint to the Google OAuth
   client. Keep the Web OAuth client ID; Android Google sign-in uses it as the
   server client ID.

   ```powershell
   dart pub global activate flutterfire_cli
   flutterfire configure --project YOUR_FIREBASE_PROJECT_ID --platforms android,ios,web
   ```

   The checked-in `lib/firebase_options.dart` reads Firebase's public app
   identifiers from `--dart-define`; do not replace it with a generated file.
   For the GitHub Actions APK workflow, add these repository **Actions
   variables** under Settings → Secrets and variables → Actions → Variables:
   `FIREBASE_API_KEY`, `FIREBASE_ANDROID_APP_ID`, `FIREBASE_PROJECT_ID`,
   `FIREBASE_MESSAGING_SENDER_ID`, and `FIREBASE_WEB_CLIENT_ID`. The workflow
   stops with an error if any are missing. For a web build, also provide
   `FIREBASE_WEB_APP_ID` and `FIREBASE_AUTH_DOMAIN` as build defines. These are
   public client configuration values; never add service-account JSON, Admin
   SDK credentials, or private signing keys to the app or repository.
4. Create the default Firestore database, then deploy the included restrictive
   rules. They scope reads and writes to `users/{uid}` and transaction records
   under that user's path. Do not deploy permissive test-mode rules.

   ```powershell
   firebase use YOUR_FIREBASE_PROJECT_ID
   firebase deploy --only firestore:rules
   ```

5. Install packages and test the app. The SQLite setup command copies the
   package-matched WASM/shared-worker files into `web/`; keep those files in
   place so browser storage can open the local database:

   ```powershell
   flutter pub get
   dart run sqflite_common_ffi_web:setup
   flutter analyze
   flutter test
   flutter build web `
     --dart-define=FIREBASE_CONFIGURED=true `
     --dart-define=FIREBASE_API_KEY=YOUR_FIREBASE_API_KEY `
     --dart-define=FIREBASE_WEB_APP_ID=YOUR_FIREBASE_WEB_APP_ID `
     --dart-define=FIREBASE_PROJECT_ID=YOUR_FIREBASE_PROJECT_ID `
     --dart-define=FIREBASE_MESSAGING_SENDER_ID=YOUR_FIREBASE_MESSAGING_SENDER_ID `
     --dart-define=FIREBASE_AUTH_DOMAIN=YOUR_FIREBASE_AUTH_DOMAIN
   ```

   Deploy `build/web` with Firebase Hosting (`firebase.json` is included).
   Host the app over HTTPS (localhost is allowed for development). After the
   first successful online visit, the PWA service worker caches the app shell,
   Flutter runtime assets, and SQLite WASM resources for offline launches.
   Android Chrome/desktop Chrome offer **Install app** from the browser menu.
   On iPhone/iPad, open the HTTPS site in Safari and choose **Share → Add to
   Home Screen**. Browser storage is origin-specific and can still be cleared
   by the browser or device, so keep encrypted backups.
6. Open **Settings & Backup** and sign in with Google. Use that same Google
   account on every device: existing local transactions are reconciled rather
   than wiped, and a clean device downloads that account's cloud records.
   Use **Sync now** and wait for **Synced**. Sync retries on connectivity
   restoration and app resume. This is automatic cloud sync, not an email
   attachment; the separate encrypted email backup remains available in
   **Email encrypted backup**. Background execution is not promised on mobile
   browsers.

The PWA service worker uses a network-first strategy for app navigation and
caches same-origin app assets for offline loading; Firebase/API hosts are not
cached by that worker. SQLite persists locally in browser storage through
IndexedDB and its WASM worker. Firestore web persistence is separate and only
available after Firebase setup. Browser eviction, private browsing, and iOS
storage pressure can remove local data; manual encrypted export/restore remains
important. For subsequent app releases, change `CACHE_VERSION` in
`web/service-worker.js` so installed clients discard cached assets from the
previous release.

### Deploy the PWA to Cloudflare Pages

The GitHub Actions workflow at
`.github/workflows/deploy-cloudflare-pages.yml` builds the Flutter web app,
runs analysis and tests, then deploys `build/web` to the Cloudflare Pages
project `mymoney-pwa` whenever `main` is updated (or when started manually).
The Pages deployment uses Firebase Authentication and Firestore for same-Google
account sync; email backup remains a separate manual feature.

Before deploying:

1. In GitHub repository **Settings → Secrets and variables → Actions**, add
   these repository variables (or secrets): `FIREBASE_API_KEY`, `FIREBASE_WEB_APP_ID`,
   `FIREBASE_PROJECT_ID`, `FIREBASE_MESSAGING_SENDER_ID`, and
   `FIREBASE_AUTH_DOMAIN`.
2. Add repository secrets `CLOUDFLARE_API_TOKEN` and
   `CLOUDFLARE_ACCOUNT_ID`. Create a Cloudflare API token with **Account →
   Cloudflare Pages → Edit** permission. Never put the token in a workflow
   file or repository variable.
3. In Firebase Authentication, add `mymoney-pwa.pages.dev` to the authorized
   domains and enable Google as a sign-in provider. Deploy the restrictive
   `firestore.rules` from this repository to the Firebase project.
4. The screenshot shows the Pages project connected to a different GitHub
   repository. The workflow deploys this workspace repository to the existing
   Pages project using Wrangler. In Cloudflare Pages → **Settings → Builds →
   Branch control**, disable automatic production and preview deployments for
   the old Git connection; otherwise it may overwrite a Wrangler deployment.
5. Push the workflow to `main`, then check GitHub **Actions** for
   **Deploy My Money to Cloudflare Pages**. It also supports **Run workflow**
   for a manual deploy. Wait for the deployment to finish before checking the
   `mymoney-pwa.pages.dev` site.

The Cloudflare account must already contain the Pages project named
`mymoney-pwa`. The workflow fails with an explicit error if Firebase build
variables are missing.

### Sync behavior and limitations

- Firestore paths are `users/{uid}/transactions/{transactionUuid}`; Firebase
  Authentication UID scoping and `firestore.rules` prevent cross-user access.
- A single outbox row per entity coalesces repeated edits safely. A successful
  server transaction must finish before its outbox row is removed.
- Conflict policy is deterministic last-write-wins based on client UTC update
  time and device ID. Device clocks can differ; review and back up important
  data before first multi-device use.
- A local database is bound to the first Google UID that signs in. Switching
  accounts on the same app profile is blocked to avoid uploading one person's
  offline records into another person's cloud space; use a separate app/browser
  profile for another user.
- Transactions plus user-created accounts and income/expense categories
  synchronize. Renaming a custom catalog item also updates matching local
  transaction labels and queues those transactions; removing a custom item is
  a tombstone, so past records are retained.
- Firestore rules reject physical deletion; app deletions are tombstone writes.
  Authentication and database setup are required before cloud sync can report
  a successful state.
- Firestore encrypts transport and server storage; the local SQLite database
  itself is not encrypted at rest.
- No background sync guarantee is made. The app retries at launch/resume,
  on reconnect, after local edits, and via the manual button.

### Offline and conflict test checklist

Use disposable test accounts/data first:

1. Start offline, create an income and expense, edit one, then delete one.
   Verify entries remain visible locally as appropriate after closing/reopening
   the app; deleted entries should stay absent.
2. Reconnect and wait for **Synced**. Confirm the server records have the same
   IDs and amounts, with the deletion represented by a tombstone.
3. Repeat edits and delete on two devices while offline, then reconnect both.
   Confirm both converge to the most recent `updatedAt` (device ID breaks an
   exact tie) and the deleted record stays deleted when its tombstone wins.
4. Sign into a clean device and confirm it downloads the records. Try a
   different Google account and confirm it cannot read the first user's
   Firestore paths.
5. On web, confirm the browser recognizes the manifest and service worker,
   finish one successful online app load, then reload in offline mode. Verify
   the app shell and SQLite data load for the same origin. Repeat in iPhone
   Safari installed to the Home Screen and check storage after browser/device
   restart.
6. Export an encrypted backup, restore it into a test profile with existing
   transactions, and confirm restore merges rather than clearing pre-existing
   records.

Run this matrix on actual target browsers/devices before relying on financial
data. The current environment has no Flutter or Dart executable, so the code
here has not been built or device-tested.

## Build APK with GitHub Actions (Android phone only needed for installation)

1. Unzip the downloaded source on a computer.
2. Create a **private** GitHub repository called `mymoney`.
3. Upload **all files including `.github/workflows/build-apk.yml`** to that repository.
   If uploading through browser, hidden `.github` might need to be selected
   explicitly. No passwords should be committed to the repository.
4. Configure the Firebase Actions variables described above. Then open your
   repository on GitHub → **Actions** → **Build MyMoney Android APK** →
   **Run workflow**.
5. After a **successful** workflow run, open the run → **Artifacts** →
   `MyMoney-Android-APK` and download it.
6. Unzip the artifact. Copy `app-debug.apk` to your Android phone and install it.
   Android may request permission to install apps from the Files application.
7. Open My Money, add some entries, and email a backup from Settings.
8. Verify backup recovery **with test data** before storing important records.

If the workflow fails, read the error under Actions. This ZIP has not been run
through `flutter analyze`, `flutter test`, or an Android build in this environment;
some platform/dependency adjustments might be necessary.

## Local Windows setup (Flutter + Android Studio installed)

```powershell
flutter doctor
flutter create --platforms=android --org com.personal.finance --project-name mymoney platform_shell
Copy-Item .\platform_shell\android .\android -Recurse
Copy-Item .\platform_shell\.metadata .\.metadata
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
  its original passphrase; valid records merge without clearing existing data.
- If the backup password is forgotten, its contents cannot be decrypted.
- Automatic local copy is kept in the app private storage only; it is NOT sent
  as an email. **Uninstalling the app may erase both DB and this local copy.**
- SQLite database records are in an app-private database, but the database file
  itself is not encrypted at rest. PIN locking is a UI access control, not
  whole-database encryption.
- Disable Android auto-backup to avoid keystore restoration issues.
- App debug builds are convenient for personal install/testing. Debug signature
  and release signing have different installation/upgrading characteristics.
