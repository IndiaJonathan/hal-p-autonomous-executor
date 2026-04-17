# Mobile App Delivery Annex
**Annex to:** SKILL.md — Autonomous Executor  
**Applies to:** React Native / Expo Android apps  
**Created:** 2026-04-16 — lessons from Poem of the Day v1 delivery

---

## 1. API URL — The #1 Mobile Bug

**React Native / Expo apps:** `BASE_URL` in `api.ts` falls back to `http://localhost:PORT` when no env var is set. This works in Expo Go but **silently fails on a real phone** because `localhost` means the phone itself.

### The Fix (two places, always set both)

**Frontend build — set before building the APK:**
```bash
export EXPO_PUBLIC_API_URL=https://your-domain.com
# Then build
```

**Backend — set APP_URL for magic link / email verification URLs:**
```bash
# In .env and docker-compose.yml
APP_URL=https://your-domain.com
```

### Verify the bundle is correct (after APK build)
```python
python3 << 'PYEOF'
import zipfile, re

apk = 'path/to/app-release.apk'
with zipfile.ZipFile(apk) as z:
    bundle = [n for n in z.namelist() if 'index.android.bundle' in n][0]
    data = z.open(bundle).read()

localhost_refs = re.findall(b'http://localhost:[0-9]+', data)
poem_refs = re.findall(b'https://your-domain.com[^\s"\'\\\\]*', data)
print(f"localhost URLs: {len(localhost_refs)}  (should be 0)")
print(f"domain URLs: {poem_refs[:3]}")
PYEOF
```

If `localhost URLs > 0`, the env var wasn't set during build. Rebuild after setting it.

---

## 2. Magic Link / Email Verification URLs

If the app sends magic link emails, the backend generates the clickable URL using `APP_URL`. Set it to the **public HTTPS domain**, not `localhost`.

```typescript
// email.service.ts
const appUrl = process.env.APP_URL ?? 'https://your-domain.com';
const verifyUrl = `${appUrl}/auth/magic-link/verify?token=${token}`;
```

Always verify the URL in the backend log:
```bash
grep "Magic link for" /tmp/backend-direct.log
# Should show: https://your-domain.com/auth/magic-link/verify?token=...
```

---

## 3. Cloudflared Tunnel — Update When Backend Port Changes

The tunnel config at `~/.cloudflared/config.yml` has the backend port hardcoded:

```yaml
ingress:
  - hostname: your-domain.com
    service: http://127.0.0.1:PORT   # ← must match backend port
```

If the backend restarts on a different port, the tunnel breaks (502 Bad Gateway).

After starting a backend, check both:
```bash
# Local backend
curl http://localhost:PORT/health

# Public domain
curl https://your-domain.com/health
```

If the public domain 502s but localhost works → tunnel config is stale.

---

## 4. APK Download via Backend (Better Than GitHub Releases)

GitHub release download URLs are unreliable (404s, rate limits). Better: add a download endpoint to the backend and serve from the same domain.

### Backend main.ts addition
```typescript
const apkPath = process.env.APK_PATH ?? '/path/to/app-release.apk';
app.use('/download', (req, res) => {
  res.sendFile(apkPath, {
    headers: { 'Content-Type': 'application/vnd.android.package-archive' }
  });
});
```

### Docker-compose volume mount
```yaml
services:
  api:
    volumes:
      - ./apps/frontend/app-release.apk:/app/apps/backend/app-release.apk:ro
    environment:
      APK_PATH: /app/apps/backend/app-release.apk
```

### Local .env
```
APK_PATH=/path/to/app-release.apk
```

### Download URL
```
https://your-domain.com/download/app-release.apk
```

Test with `curl -sI https://your-domain.com/download/app-release.apk | head -3` — expect `HTTP/2 200`.

---

## 5. Onboarding-First, Not Auth-First

Users should be able to browse the app before signing up. Onboarding should end at the main app (Home/Browse), not at an Auth gate.

### Navigator pattern (React Navigation)
```typescript
// AppNavigator.tsx — WRONG (auth-first)
{!token ? (
  <Stack.Screen name="Auth" component={AuthNavigator} />
) : (
  <Stack.Screen name="Main" component={TabNavigator} />
)}

// CORRECT (onboarding-first, always show Main)
{!onboardingComplete ? (
  <Stack.Screen name="Onboarding" component={OnboardingScreen} />
) : (
  <>
    <Stack.Screen name="Main" component={TabNavigator} />
    <Stack.Screen name="Auth" component={AuthNavigator} />
  </>
)}
```

### OnboardingScreen.tsx
```typescript
// WRONG
navigation.replace('Auth');

// CORRECT
navigation.replace('Main');
```

Then gate specific screens (Favorites, Profile) behind auth prompts, not the whole app.

---

## 6. Android Build Environment

### Required tools
- **JDK 21** — `brew install openjdk@21`
- **Android SDK** — `~/Library/Android/sdk/`
- **Gradle** — bundled in Android project, but needs `JAVA_HOME` and `ANDROID_HOME`

### Env vars for build
```bash
export JAVA_HOME=$(/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home)
export ANDROID_HOME=~/Library/Android/sdk
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
export EXPO_PUBLIC_API_URL=https://your-domain.com
```

### Build command (from `android/` directory)
```bash
./gradlew assembleRelease
```

Output: `android/app/build/outputs/apk/release/app-release.apk`

### Emulator test (when hardware available)
```bash
# Start emulator
~/Library/Android/sdk/emulator/emulator -avd AVD_NAME -no-snapshot-load -no-audio -no-boot-anim

# Install APK
~/Library/Android/sdk/platform-tools/adb install -r app-release.apk

# Clear app data
adb shell pm clear com.your.package

# Launch
adb shell am start -n com.your.package/.MainActivity

# Screenshot
adb exec-out screencap -p > screen.png

# Get UI dump
adb exec-out uiautomator dump /sdcard/ui.xml
adb exec-out cat /sdcard/ui.xml > ui.xml
```

---

## 7. Quick Checklist Before Calling an App "Delivered"

- [ ] `EXPO_PUBLIC_API_URL` set before APK build
- [ ] Bundle verified: zero `localhost` references in APK
- [ ] `APP_URL` set on backend (magic link emails work)
- [ ] Cloudflared tunnel verified: public domain returns HTTP 200
- [ ] APK served via backend `/download` endpoint
- [ ] APK installed on real device or emulator
- [ ] Onboarding → Main (not → Auth)
- [ ] Browse / Home accessible without login
- [ ] Favorites prompts auth gracefully (not hard-redirect)
- [ ] Magic link email received and link opens app

---

## 8. Common Failure Modes

| Symptom | Cause | Fix |
|---|---|---|
| "Bad Gateway" on public domain | Cloudflared tunnel points to wrong port | Update `config.yml` ingress rule |
| Magic link email shows `localhost:3003` | `APP_URL=localhost:3003` in env | Set `APP_URL=https://public-domain.com` |
| API calls silently fail on phone | `EXPO_PUBLIC_API_URL` not set at build time | Rebuild with env var set |
| App forces sign-up before browsing | Auth gate in navigator after onboarding | Fix navigator to go Main after onboarding |
| APK download 500 | APK not mounted in Docker container | Add volume mount to docker-compose |
| Emulator tap not working | ARM emulator + multi-touch virtio conflict | Use `sendevent` or accept emulator limitations |
