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

// Apply app-only safe-area metadata and styling to the packaged copy.
// The website's root index.html is never modified by this script.
html = html.replace(
  /<meta name="viewport" content="([^"]*)">/i,
  (_match, content) => `<meta name="viewport" content="${content.includes('viewport-fit=cover') ? content : content + ',viewport-fit=cover'}">`
);

const nativeStyle = `
<style id="pro-native-shell">
  html, body { min-height: 100%; }
  body {
    padding-top: env(safe-area-inset-top, 0px);
    padding-bottom: env(safe-area-inset-bottom, 0px);
    overscroll-behavior-y: contain;
    -webkit-tap-highlight-color: transparent;
  }
  input, textarea, select, button { font-size: max(16px, 1em); }
</style>
`;

if (!html.includes('id="pro-native-shell"')) {
  html = html.replace('</head>', nativeStyle + '\n</head>');
}

fs.writeFileSync(output, html, 'utf8');
console.log(`Prepared isolated mobile web bundle: ${output}`);
