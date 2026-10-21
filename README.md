# SAADH DSP – Flutter app (Android)

You do NOT need Flutter installed. GitHub builds the APK for you.

1. Create a free account at github.com and make a **new repository** (any name, Public or Private).
2. Click **Add file → Upload files**. Drag in `pubspec.yaml` and the `lib` folder (with main.dart). Commit.
3. Click **Add file → Create new file**. In the name box type exactly:  `.github/workflows/build.yml`
   Paste the full contents of `build.yml` from this zip. Commit.
4. Open the **Actions** tab → "Build APK" → wait ~5–8 min for a green tick.
   (If it didn't start: click **Run workflow**.)
5. Open the finished run → **Artifacts → saadh-dsp-apk** → download, unzip, you get `app-release.apk`.
6. Copy the APK to your phone, tap it, allow "Install unknown apps" for your file manager/browser.
7. Open the app → enter your PIN (default 1234) → Scan → tap "SAADH DSP".

If the build goes red, open the failed step and send me the last ~30 lines of the log.
