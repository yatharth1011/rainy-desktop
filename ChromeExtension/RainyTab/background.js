// Keeps the generated "Rainy Theme" (written by the Rainy app into
// ~/Library/Application Support/RainyDesktop/ChromeTheme on every wallpaper
// change) showing the current wallpaper: Chrome builds a theme's images from
// disk whenever the theme is (re)enabled, so a disable/enable cycle picks up
// the regenerated tab-strip and toolbar images.
const BRIDGE = 'http://127.0.0.1:47823';

async function syncTheme() {
  let state;
  try {
    state = await (await fetch(`${BRIDGE}/state.json`, { cache: 'no-store' })).json();
  } catch {
    return; // Rainy isn't running
  }
  const { themeVersion } = await chrome.storage.local.get('themeVersion');
  if (themeVersion === state.version) return;
  const theme = (await chrome.management.getAll()).find((e) => e.type === 'theme' && e.name === 'Rainy Theme');
  if (!theme) return; // not installed yet -- retry on the next tick
  if (theme.enabled) {
    // Only refresh a theme the user is actually using; never re-enable one they switched away from.
    await chrome.management.setEnabled(theme.id, false);
    await chrome.management.setEnabled(theme.id, true);
  }
  await chrome.storage.local.set({ themeVersion: state.version });
}

chrome.runtime.onInstalled.addListener(() => chrome.alarms.create('sync', { periodInMinutes: 0.5 }));
chrome.runtime.onStartup.addListener(syncTheme);
chrome.alarms.onAlarm.addListener(syncTheme);
chrome.runtime.onMessage.addListener((msg) => { if (msg?.type === 'wallpaperChanged') syncTheme(); });

// ---------------------------------------------- per-site glass toggle ----
// Toolbar button / ⌥⇧G toggles Rainy glass (glass-site.js) on the current
// site. Opt-in only: a site is styled only after you turn it on, and stays
// on across reloads only if you also granted access to that site when asked.

const SITES_KEY = 'glassSites';
const SCRIPT_ID = 'rainy-glass';

async function glassSites() {
  return (await chrome.storage.local.get(SITES_KEY))[SITES_KEY] || [];
}

// Auto-apply on reload/navigation only for enabled sites we have access to.
async function syncGlassRegistration() {
  const sites = await glassSites();
  const matches = [];
  for (const origin of sites) {
    if (await chrome.permissions.contains({ origins: [`${origin}/*`] })) matches.push(`${origin}/*`);
  }
  const existing = await chrome.scripting.getRegisteredContentScripts({ ids: [SCRIPT_ID] });
  if (existing.length) await chrome.scripting.unregisterContentScripts({ ids: [SCRIPT_ID] });
  if (matches.length) {
    await chrome.scripting.registerContentScripts([
      { id: SCRIPT_ID, matches, js: ['glass-site.js'], runAt: 'document_idle', persistAcrossSessions: true },
    ]);
  }
}

async function toggleGlass(tab) {
  if (!tab?.id || !/^https?:/.test(tab.url || '')) return;
  const origin = new URL(tab.url).origin;
  // Must be requested before any await, while the click still counts as a
  // user gesture. Already-granted sites resolve silently.
  const granted = chrome.permissions.request({ origins: [`${origin}/*`] }).catch(() => false);
  const sites = await glassSites();
  const enable = !sites.includes(origin);
  const next = enable ? [...sites, origin] : sites.filter((s) => s !== origin);
  await chrome.storage.local.set({ [SITES_KEY]: next });
  await granted;
  await syncGlassRegistration();

  if (enable) {
    // The click itself (activeTab) lets us style this page right away.
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['glass-site.js'] });
    await chrome.tabs.sendMessage(tab.id, { type: 'rainy-glass', on: true }).catch(() => {});
  } else {
    await chrome.tabs.sendMessage(tab.id, { type: 'rainy-glass', on: false }).catch(() => {});
  }
  await chrome.action.setBadgeText({ tabId: tab.id, text: enable ? 'ON' : '' });
}

chrome.action.onClicked.addListener(toggleGlass);
chrome.commands.onCommand.addListener((command, tab) => { if (command === 'toggle-glass') toggleGlass(tab); });
chrome.runtime.onMessage.addListener((msg, sender) => {
  if (msg?.type === 'rainy-glass-active' && sender.tab?.id) {
    chrome.action.setBadgeText({ tabId: sender.tab.id, text: 'ON' });
  }
});
chrome.runtime.onInstalled.addListener(() => {
  chrome.action.setBadgeBackgroundColor({ color: '#1c1c22' });
  syncGlassRegistration();
});
