// Builds a single, self-contained interactive HTML page from the current viewer state.
// The page embeds the height grid, colours, class scheme, legend, title and camera, plus
// the very same viewer.js that runs in the app, so it needs no R / Shiny server.
(function () {
    const THREE_URL = 'https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.module.js';
    const ORBIT_URL = 'https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/controls/OrbitControls.js';

    const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
    // keep JSON / source safe inside <script> elements
    const LS = new RegExp('[' + String.fromCharCode(0x2028) + String.fromCharCode(0x2029) + ']', 'g');
    const safeJson = o => JSON.stringify(o).replace(/</g, '\\u003c').replace(LS, '');
    const safeSrc = t => t.replace(/<\/script/gi, '<\\/script');

    const CONTROLS_HTML = `
<div id="ctl" class="ctl"><button id="ctl-toggle" title="Controls">&#9881;</button>
  <div id="ctl-body">
    <div class="row"><button data-v="oblique">Oblique</button><button data-v="top">Top</button><button data-v="side">Side</button></div>
    <label>Height exaggeration <input type="range" min="0.1" max="5" step="0.1" data-p="v_exag"></label>
    <label>Sun azimuth <input type="range" min="0" max="360" step="1" data-p="v_sunaz"></label>
    <label>Sun altitude <input type="range" min="3" max="90" step="1" data-p="v_sunalt"></label>
    <label class="chk"><input type="checkbox" data-p="v_shadows"> Shadows</label>
    <label class="chk"><input type="checkbox" data-p="v_rotate"> Auto-rotate</label>
    <div class="row"><button id="ctl-png">Save PNG</button></div>
  </div></div>`;

    const CONTROLS_JS = `
const ctl = document.getElementById('ctl');
if (ctl) {
  const st = window.CanopyViewer.getState().P;
  document.getElementById('ctl-toggle').onclick = () => ctl.classList.toggle('open');
  ctl.querySelectorAll('[data-p]').forEach(el => {
    const k = el.dataset.p;
    if (el.type === 'checkbox') { el.checked = !!st[k]; el.onchange = () => window.CanopyViewer.set(k, el.checked); }
    else { el.value = st[k]; el.oninput = () => window.CanopyViewer.set(k, Number(el.value)); }
  });
  ctl.querySelectorAll('[data-v]').forEach(b => b.onclick = () => window.CanopyViewer.setView(b.dataset.v));
  document.getElementById('ctl-png').onclick = () => window.CanopyViewer.snapshot(2);
}`;

    // opts: { controls: bool, importMap: {imports:{...}}, viewerSrc: string }
    function makeEmbedHtml(state, opts) {
        const pageTitle = (state.P.v_title || (state.msg && state.msg.title) || '3D forest height').trim();
        const bg = state.P.v_bg || '#ffffff';
        return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(pageTitle)} – 3D canopy height</title>
<style>
html,body{margin:0;height:100%;background:${bg};font-family:system-ui,-apple-system,Segoe UI,sans-serif;overflow:hidden}
#viewer{position:fixed;inset:0}#viewer canvas{display:block;width:100%;height:100%}
#maptitle{position:fixed;top:12px;pointer-events:none;max-width:80vw}
.mt-t{font-weight:700;line-height:1.25}.mt-s{font-size:.6em;opacity:.75;margin-top:2px}
#legend{position:fixed;background:rgba(255,255,255,.85);padding:8px 10px;border-radius:6px;color:#222;pointer-events:none;display:none}
.lg-title{font-weight:600;margin-bottom:4px}.lg-row{display:flex;align-items:center;gap:6px;line-height:1.5}
.lg-sw{width:1.3em;height:1.3em;display:inline-block}.lg-grad{display:flex;gap:6px}
.lg-bar{width:1.3em;height:10em;display:inline-block}.lg-lab{display:flex;flex-direction:column;justify-content:space-between;font-weight:400}
#hint{position:fixed;left:50%;transform:translateX(-50%);bottom:6px;font-size:12px;color:#777;pointer-events:none}
#locator{position:fixed;right:12px;top:12px;display:none}
#mapinfo{position:fixed;left:12px;bottom:26px;background:rgba(255,255,255,.82);padding:6px 9px;border-radius:5px;font-size:11px;line-height:1.45;color:#333;max-width:70vw;pointer-events:none;display:none}
.ctl{position:fixed;right:12px;top:172px;z-index:5;font-size:13px}
.ctl>button{width:36px;height:36px;border-radius:8px;border:1px solid #cfd6d2;background:#fff;font-size:18px;cursor:pointer}
#ctl-body{display:none;margin-top:6px;background:rgba(255,255,255,.95);border:1px solid #d5ddd8;border-radius:8px;padding:10px;width:210px;color:#222}
.ctl.open #ctl-body{display:block}
.ctl label{display:block;margin:6px 0;font-size:12px}.ctl label input[type=range]{width:100%}
.ctl .chk{display:flex;gap:6px;align-items:center}.ctl .row{display:flex;gap:4px;margin:4px 0}
.ctl .row button{flex:1;padding:4px;border:1px solid #cfd6d2;border-radius:6px;background:#f6f8f7;cursor:pointer;font-size:12px}
</style>
<script type="importmap">${safeJson(opts.importMap)}</script>
</head><body>
<div id="viewer"></div><div id="maptitle"></div><div id="legend"></div><canvas id="locator"></canvas><div id="mapinfo"></div>
<div id="hint">drag: orbit · right-drag: pan · wheel: zoom</div>
${opts.controls ? CONTROLS_HTML : ''}
<script id="canopy-state" type="application/json">${safeJson(state)}</script>
<script type="module">
${safeSrc(opts.viewerSrc)}
</script>
<script type="module">
const state = JSON.parse(document.getElementById('canopy-state').textContent);
window.CanopyViewer.load(state.msg, state);
${opts.controls ? CONTROLS_JS : ''}
</script>
</body></html>
`;
    }

    // ---------- browser side (only inside the Shiny app) ----------
    const toDataUrl = async url => {
        const buf = await (await fetch(url)).arrayBuffer();
        let bin = ''; const u8 = new Uint8Array(buf);
        for (let i = 0; i < u8.length; i += 0x8000) bin += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
        return 'data:text/javascript;base64,' + btoa(bin);
    };

    async function exportEmbed() {
        const iv = (window.Shiny && window.Shiny.shinyapp.$inputValues) || {};
        const btn = document.getElementById('embed-go'), note = document.getElementById('embed-note');
        if (!window.CanopyViewer || !window.CanopyViewer.getState().msg) { note.textContent = 'Build a layer first.'; return; }
        btn.disabled = true; note.textContent = 'Building the page…';
        try {
            const state = window.CanopyViewer.getState();
            const viewerSrc = await (await fetch('viewer.js')).text();
            let importMap = { imports: {
                'three': THREE_URL, 'three/addons/controls/OrbitControls.js': ORBIT_URL } };
            let bundled = false;
            if (iv.embed_bundle) {
                try {
                    importMap = { imports: {
                        'three': await toDataUrl(THREE_URL),
                        'three/addons/controls/OrbitControls.js': await toDataUrl(ORBIT_URL) } };
                    bundled = true;
                } catch (e) { note.textContent = 'Could not bundle three.js; using the CDN instead. '; }
            }
            const html = makeEmbedHtml(state, { controls: !!iv.embed_controls, importMap, viewerSrc });
            const name = ((state.P.v_title || state.msg.title || 'forest-height').replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '') || 'forest-height') + '-3d.html';
            const url = URL.createObjectURL(new Blob([html], { type: 'text/html' }));
            const a = document.createElement('a'); a.href = url; a.download = name; a.click();
            setTimeout(() => URL.revokeObjectURL(url), 5000);
            document.getElementById('embed-snippet').value =
                `<iframe src="${name}" width="100%" height="600" style="border:0" loading="lazy" allowfullscreen></iframe>`;
            note.textContent = `Saved ${name} (${(html.length / 1e6).toFixed(1)} MB${bundled ? ', works offline' : ', needs internet for three.js'}).`;
        } catch (e) { note.textContent = 'Export failed: ' + e.message; }
        btn.disabled = false;
    }

    if (typeof window !== 'undefined' && window.document) {
        document.addEventListener('DOMContentLoaded', () => {
            const go = document.getElementById('embed-go'); if (go) go.onclick = exportEmbed;
            const cp = document.getElementById('embed-copy');
            if (cp) cp.onclick = () => {
                const t = document.getElementById('embed-snippet'); t.select();
                navigator.clipboard && navigator.clipboard.writeText(t.value);
            };
        });
    }
    // exposed for testing / reuse
    (typeof window !== 'undefined' ? window : globalThis).makeEmbedHtml = makeEmbedHtml;
    if (typeof module !== 'undefined') module.exports = { makeEmbedHtml };
})();
