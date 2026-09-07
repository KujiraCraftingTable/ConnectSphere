const router = require('express').Router();
const dns    = require('dns/promises');
const net    = require('net');
const { authMiddleware } = require('./authRoutes');
const logger = require('../utils/logger');

// ── SSRF guard ────────────────────────────────────────────────────────────────
// The server fetches a URL sent by the client → must block internal addresses
// (localhost, private ranges, link-local/metadata) before fetching.

function isPrivateIp(ip) {
  if (ip.includes(':')) {
    const v6 = ip.toLowerCase();
    if (v6.startsWith('::ffff:')) return isPrivateIp(v6.slice(7)); // IPv4-mapped
    return v6 === '::1' || v6 === '::'
      || v6.startsWith('fe80') || v6.startsWith('fc') || v6.startsWith('fd');
  }
  const parts = ip.split('.').map(Number);
  if (parts.length !== 4 || parts.some(Number.isNaN)) return true; // can't parse → block it
  const [a, b] = parts;
  return a === 0 || a === 10 || a === 127
    || (a === 169 && b === 254)
    || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && b === 168);
}

// Throws if the hostname is an internal address or resolves to an internal IP
async function assertPublicHost(hostname) {
  const host = hostname.toLowerCase();
  if (host === 'localhost' || host.endsWith('.local') || host.endsWith('.internal')) {
    throw new Error('Blocked host');
  }
  if (net.isIP(host)) {
    if (isPrivateIp(host)) throw new Error('Blocked host');
    return;
  }
  const { address } = await dns.lookup(host);
  if (isPrivateIp(address)) throw new Error('Blocked host');
}

// ── oEmbed providers (faster and more accurate than OG parsing) ─────────────────────

const OEMBED_PROVIDERS = [
  {
    pattern: /youtube\.com\/watch|youtu\.be\//,
    endpoint: (url) => `https://www.youtube.com/oembed?url=${encodeURIComponent(url)}&format=json`,
  },
  {
    pattern: /vimeo\.com\//,
    endpoint: (url) => `https://vimeo.com/api/oembed.json?url=${encodeURIComponent(url)}`,
  },
  {
    pattern: /twitter\.com\/|x\.com\//,
    endpoint: (url) => `https://publish.twitter.com/oembed?url=${encodeURIComponent(url)}`,
  },
  {
    pattern: /instagram\.com\//,
    endpoint: (url) => `https://api.instagram.com/oembed?url=${encodeURIComponent(url)}`,
  },
  {
    pattern: /open\.spotify\.com\//,
    endpoint: (url) => `https://open.spotify.com/oembed?url=${encodeURIComponent(url)}`,
  },
  {
    pattern: /soundcloud\.com\//,
    endpoint: (url) => `https://soundcloud.com/oembed?format=json&url=${encodeURIComponent(url)}`,
  },
];

async function fetchOEmbed(url) {
  const provider = OEMBED_PROVIDERS.find(p => p.pattern.test(url));
  if (!provider) return null;

  try {
    const res = await fetch(provider.endpoint(url), {
      headers: { 'User-Agent': 'ConnectSphere/1.0' },
      signal: AbortSignal.timeout(6_000),
    });
    if (!res.ok) return null;
    const data = await res.json();
    return {
      title:    data.title       || null,
      image:    data.thumbnail_url || null,
      siteName: data.provider_name || null,
    };
  } catch {
    return null;
  }
}

// ── OG tag parsing (fallback for ordinary pages) ──────────────────────

function parseMeta(html) {
  // Match both orderings: property="og:x" content="..." AND content="..." property="og:x"
  function getOG(property) {
    const p = property.replace(':', ':');
    // Order 1: property before content
    let m = html.match(new RegExp(`property=["']${p}["'][^>]*content=["']([^"']+)["']`, 'i'));
    if (m) return m[1];
    // Order 2: content before property
    m = html.match(new RegExp(`content=["']([^"']+)["'][^>]*property=["']${p}["']`, 'i'));
    return m ? m[1] : null;
  }

  function getMeta(name) {
    let m = html.match(new RegExp(`name=["']${name}["'][^>]*content=["']([^"']+)["']`, 'i'));
    if (m) return m[1];
    m = html.match(new RegExp(`content=["']([^"']+)["'][^>]*name=["']${name}["']`, 'i'));
    return m ? m[1] : null;
  }

  return {
    title:       getOG('og:title') || html.match(/<title[^>]*>([^<]+)<\/title>/i)?.[1]?.trim() || null,
    description: getOG('og:description') || getMeta('description') || null,
    image:       getOG('og:image') || null,
    siteName:    getOG('og:site_name') || null,
  };
}

async function fetchOGTags(url) {
  const res = await fetch(url, {
    headers: {
      'User-Agent': 'Mozilla/5.0 (compatible; ConnectSphere/1.0; +https://connectsphere.app)',
      'Accept': 'text/html,application/xhtml+xml',
      'Accept-Language': 'en-US,en;q=0.9',
    },
    signal: AbortSignal.timeout(8_000),
    redirect: 'follow',
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);

  // Read at most 150KB — enough for most pages
  const buffer = await res.arrayBuffer();
  const html   = Buffer.from(buffer).slice(0, 150_000).toString('utf-8');
  return parseMeta(html);
}

// ── Route ─────────────────────────────────────────────────────────────────────

router.post('/', authMiddleware, async (req, res) => {
  const { url } = req.body;
  if (!url || typeof url !== 'string') {
    return res.status(400).json({ error: 'url is required' });
  }

  let parsed;
  try { parsed = new URL(url); }
  catch { return res.status(400).json({ error: 'Invalid URL' }); }
  if (!['http:', 'https:'].includes(parsed.protocol)) {
    return res.status(400).json({ error: 'Only http/https URLs allowed' });
  }

  try { await assertPublicHost(parsed.hostname); }
  catch { return res.status(400).json({ error: 'URL not allowed' }); }

  try {
    // 1. Try oEmbed first (YouTube, Vimeo, Spotify...)
    const oembed = await fetchOEmbed(url);

    let meta;
    if (oembed) {
      meta = oembed;
    } else {
      // 2. Fallback: parse OG tags from the HTML
      meta = await fetchOGTags(url);
    }

    res.json({
      url,
      title:       meta.title       || parsed.hostname,
      description: meta.description || null,
      image:       meta.image       || null,
      siteName:    meta.siteName    || parsed.hostname,
    });
  } catch (err) {
    logger.warn({ err, url }, 'Link preview failed');
    // Return minimal metadata instead of an error
    res.json({
      url,
      title:       parsed.hostname,
      description: null,
      image:       null,
      siteName:    parsed.hostname,
    });
  }
});

module.exports = router;
