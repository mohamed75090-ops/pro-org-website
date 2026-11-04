import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.professionalesports.proorg',
  appName: 'PROFESSIONAL ESPORTS',
  webDir: 'www',
  android: {
    backgroundColor: '#08090c',
    allowMixedContent: false
  },
  ios: {
    contentInset: 'automatic',
    backgroundColor: '#08090c'
  },
  plugins: {
    SplashScreen: {
      launchShowDuration: 1200,
      launchAutoHide: true,
      backgroundColor: '#08090c',
      showSpinner: false
    },
    StatusBar: {
      style: 'DARK',
      backgroundColor: '#08090c'
    }
  }
};

export default config;
