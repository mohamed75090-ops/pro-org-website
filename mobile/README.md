# PROFESSIONAL ESPORTS – PRO ORG Mobile App

This is an isolated Capacitor mobile project on the `mobile-app` branch.
The existing website branch (`main`) is not modified by mobile app work.

## Architecture
- Capacitor 8 container for Android and iOS.
- The app packages a copy of the existing `index.html` at build time.
- Supabase remains the shared backend, so approved changes and tournament data stay synchronized.
- Mobile-only safe-area styling is injected into `mobile/www/index.html`; the website source is never edited.

## Build
```bash
cd mobile
npm install
npm run prepare:web
npx cap add android
npx cap sync android
```

For iOS, run `npx cap add ios` and `npx cap sync ios` on a macOS/Xcode build environment.

## Store release
- Android Play Store submission requires a signed AAB and the owner's Play Console account.
- iOS App Store submission requires macOS/Xcode signing, the owner's Apple Developer account, and App Store Connect setup.
- Never commit signing keys, passwords, service-role keys, or private credentials.
