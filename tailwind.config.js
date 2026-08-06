/** Compiled once, offline, into static/style.css — replaces the
 * cdn.tailwindcss.com runtime JIT script so the app has no CDN dependency. */
module.exports = {
  content: ['./index.html'],
  theme: {
    extend: {
      fontFamily: { sans: ['Inter', 'system-ui', 'sans-serif'] },
      colors: {
        base: { 950: '#0b1120', 900: '#0f172a', 800: '#151f33', 700: '#1e293b' },
        brand: { 300: '#F57A8E', 400: '#F14B66', 600: '#ED1639', 700: '#970C22', 950: '#2F040B' },
      },
      boxShadow: { fab: '0 10px 30px -8px rgba(237, 22, 57, 0.6)' },
    },
  },
  plugins: [],
};
