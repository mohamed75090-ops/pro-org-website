import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const mobileDir = path.resolve(here, '..');
const source = path.resolve(mobileDir, '..', 'index.html');
const outputDir = path.join(mobileDir, 'www');
const output = path.join(outputDir, 'index.html');

if (!fs.existsSync(source)) {
  throw new Error('The website source index.html was not found. Run this script from the mobile project in the mobile-app branch.');
}

fs.mkdirSync(outputDir, { recursive: true });
let html = fs.readFileSync(source, 'utf8');

// All enhancements below apply only to the packaged app copy.
// The website source in the repository root is never modified.
html = html.replace(
  /<meta name="viewport" content="([^"]*)">/i,
  (_match, value) => `<meta name="viewport" content="${value.includes('viewport-fit=cover') ? value : value + ',viewport-fit=cover'}">`
);

if (!/<meta name="theme-color"/i.test(html)) {
  html = html.replace('</head>', '<meta name="theme-color" content="#08090c">\n</head>');
}

const nativeStyle = `
<style id="pro-native-shell">
  html, body { min-height: 100%; }
  html { scroll-padding-top: 88px; }
  body {
    padding-top: env(safe-area-inset-top, 0px);
    padding-bottom: env(safe-area-inset-bottom, 0px);
    overscroll-behavior-y: contain;
    -webkit-tap-highlight-color: transparent;
    -webkit-text-size-adjust: 100%;
  }
  button, input, select, textarea { font-size: max(16px, 1em); }
  button { min-height: 42px; touch-action: manipulation; }
  input, select, textarea { min-height: 44px; }
  :focus-visible { outline: 2px solid #f0d58d; outline-offset: 2px; }
  @media (max-width: 700px) {
    body.pro-native-app main { width: 100%; padding-inline: 12px; }
    body.pro-native-app .site-header {
      padding-top: calc(10px + env(safe-area-inset-top, 0px));
      padding-left: 4%;
      padding-right: 4%;
    }
    body.pro-native-app .header-dropdown {
      max-height: calc(100dvh - 90px);
      overflow-y: auto;
      overscroll-behavior: contain;
    }
    body.pro-native-app .admin-main-tabs {
      top: calc(58px + env(safe-area-inset-top, 0px));
    }
    body.pro-native-app table {
      display: block;
      max-width: 100%;
      overflow-x: auto;
      -webkit-overflow-scrolling: touch;
    }
    body.pro-native-app .card { min-width: 0; }
    body.pro-native-app button,
    body.pro-native-app .admin-tab,
    body.pro-native-app .team-status-tab { touch-action: manipulation; }
  }
</style>
<script id="pro-native-app-class">
  document.documentElement.classList.add('pro-native-app');
  document.addEventListener('DOMContentLoaded', () => {
    document.body.classList.add('pro-native-app');
  }, { once: true });
</script>
`;

if (!html.includes('id="pro-native-shell"')) {
  html = html.replace('</head>', nativeStyle + '\n</head>');
}

fs.writeFileSync(output, html, 'utf8');
console.log(`Prepared isolated mobile app bundle: ${output}`);
