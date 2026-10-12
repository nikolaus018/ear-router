// Build-time only — nothing in the running app reads this file.
//
// index.html carries its utility CSS inlined in a <style> block (see the
// comment above it). This config is what regenerates that block when classes
// are added or removed:
//
//     npx tailwindcss@3 -c tailwind.config.js -i input.css -o out.css
//
// then paste out.css into that <style> block, keeping its position after the
// hand-written one. There is no build step at run time and no CSS compiler
// shipped to the phone — this replaced `<script src="cdn.tailwindcss.com">`,
// which did both on every page load and re-scanned the DOM on every mutation.
//
// Adding a single one-off rule by hand to the inlined block is fine too;
// nothing regenerates it behind your back.
module.exports = {
  content: ['./index.html'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['-apple-system', 'BlinkMacSystemFont', '"SF Pro Text"', 'Inter', 'system-ui', 'sans-serif'],
      },
      colors: {
        // Sampled directly from the ASBÖ logo (see icon.png): the "S"/
        // circle red is exactly #ED1639. Used sparingly — as the app's tint
        // color (tab bar selection, primary buttons, FAB) and for
        // destructive actions — not as a dominant background.
        brand: { 50: '#FFF1F2', 100: '#FFE0E4', 300: '#F57A8E', 400: '#F14B66', 500: '#ED1639', 600: '#ED1639', 700: '#B4102B', 800: '#970C22' },
        // Apple's own semantic system colors (light values — this app is
        // light-mode only, see the module doc comment in src/main.rs).
        success: '#34C759',
        // `warn` is Apple's system orange and stays exactly that — but only
        // ever as a *fill* (the stale-route dot, the approximate-pin ring).
        // As text it is unreadable: #FF9500 on white is ~2.2:1, less than
        // half the 4.5:1 small text needs, and this app is read one-handed
        // in a van in daylight by drivers who are not all twenty-five.
        // `warnText` is the same hue darkened to ~7:1 for anything actually
        // spelled out in words.
        warn: '#FF9500',
        warnText: '#8A4B00',
      },
      boxShadow: {
        fab: '0 8px 20px -4px rgba(237, 22, 57, 0.45)',
        sheet: '0 -12px 40px -10px rgba(0, 0, 0, 0.35)',
      },
    },
  },
};
