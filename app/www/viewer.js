// Real-time 3D canopy viewer (three.js). R sends the height grid once;
// every view control below runs client-side with no server round-trip.
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const P = {
    v_exag: 1, v_sunaz: 315, v_sunalt: 35, v_shadows: true, v_shstrength: 0.6,
    v_palette: 'Forest (original)', v_bg: '#ffffff', v_classes: 5, v_stepped: false,
    v_rotate: false, v_ground: true, v_fov: 40, v_hmax: 100,
    v_title: '', v_subtitle: '', v_titleshow: true, v_titlesize: 1, v_titlealign: 'left',
    v_grid: true, v_gridlabels: true, v_gridop: 0.3, v_scalebar: true, v_locator: true, v_info: true, v_credits: true,
    v_legshow: true, v_legtitle: 'height (m)', v_legpos: 'br', v_legsize: 1, v_legdec: 0
};
let palettes = {}, grid = null, zmax = 1, autoTitle = '', lastMsg = null;
// user-editable class scheme (only used when "discrete classes" is on)
const cls = { colors: [], bounds: [], labels: [] };

const host = document.getElementById('viewer');
const legendEl = document.getElementById('legend');
const emptyEl = document.getElementById('viewer-empty');
const editorEl = document.getElementById('class-editor');
const titleEl = document.getElementById('maptitle');
const IN_SHINY = !!(window.Shiny && window.jQuery);

const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.shadowMap.autoUpdate = false; // only re-render shadows when the sun moves
host.appendChild(renderer.domElement);

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(P.v_fov, 1, 0.1, 100000);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.maxPolarAngle = Math.PI / 2 - 0.02;
controls.autoRotateSpeed = 1.2;

const hemi = new THREE.HemisphereLight(0xffffff, 0x8a8a8a, 1);
const sun = new THREE.DirectionalLight(0xffffff, 2.6);
sun.shadow.mapSize.set(4096, 4096);
sun.shadow.bias = -0.0004;
sun.shadow.normalBias = 0.4;
scene.add(hemi, sun, sun.target);

let mesh = null, ground = null, dim = 100, baseH = 10;

// The canvas is sized only when its box really changes, and never via inline CSS,
// so the map panel stays put whatever the side panel does.
let lastW = 0, lastH = 0, needFit = false;
function resize() {
    const w = host.clientWidth, h = host.clientHeight;
    if (!w || !h || (w === lastW && h === lastH)) return;
    lastW = w; lastH = h;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    if (needFit && mesh) { needFit = false; setView('oblique'); }
}
new ResizeObserver(resize).observe(host);
resize();

// ---------- colour ----------
function ramp(stops, u) {
    const n = stops.length - 1, x = Math.min(Math.max(u, 0), 1) * n;
    const i = Math.min(Math.floor(x), n - 1);
    return new THREE.Color(stops[i]).lerp(new THREE.Color(stops[i + 1]), x - i);
}
const topH = () => Math.max(Math.min(zmax, P.v_hmax), 1);
const stopsNow = () => palettes[P.v_palette] || ['#fff', '#205544'];

function genBounds() {
    const k = P.v_classes, top = topH(), dec = top >= 20 ? 0 : 1, f = 10 ** dec;
    cls.bounds = Array.from({ length: k + 1 }, (_, i) => Math.round(top * i / k * f) / f);
    cls.bounds[k] = Math.round(top * f) / f;
    cls.labels = Array(k).fill('');
}
function genColors() {
    const k = P.v_classes;
    cls.colors = Array.from({ length: k }, (_, i) => '#' + ramp(stopsNow(), Math.sqrt((i + 0.5) / k)).getHexString());
}
function colourFor(h) {
    if (P.v_stepped) {
        let i = 0;
        while (i < cls.colors.length - 1 && h >= cls.bounds[i + 1]) i++;
        return new THREE.Color(cls.colors[i]);
    }
    return ramp(stopsNow(), Math.sqrt(Math.min(h / topH(), 1))); // sqrt ~ bias = 2 in the R version
}
function recolor() {
    if (!mesh) return;
    const { nr, nc, h } = grid, col = mesh.geometry.attributes.color.array;
    const bg = new THREE.Color(P.v_bg);
    for (let i = 0; i < nr * nc; i++) {
        const c = h[i] < 0 ? bg : colourFor(h[i]);
        col[i * 3] = c.r; col[i * 3 + 1] = c.g; col[i * 3 + 2] = c.b;
    }
    mesh.geometry.attributes.color.needsUpdate = true;
    drawLegend();
}

// ---------- class editor ----------
const num = v => (Math.round(v * 100) / 100).toString();
function autoLabel(i) {
    const d = Number(P.v_legdec);
    return `${cls.bounds[i].toFixed(d)}–${cls.bounds[i + 1].toFixed(d)}`;
}
function renderEditor() {
    if (!editorEl) return;
    editorEl.style.display = P.v_stepped ? 'block' : 'none';
    if (!P.v_stepped) return;
    const k = P.v_classes;
    let html = '<div class="ce-head"><span>colour</span><span>from</span><span>to (m)</span><span>legend label</span></div>';
    for (let i = 0; i < k; i++) {
        html += `<div class="ce-row">
            <input type="color" data-i="${i}" data-f="color" value="${cls.colors[i]}">
            <span class="ce-lo">${num(cls.bounds[i])}</span>
            <input type="number" step="any" data-i="${i}" data-f="hi" value="${num(cls.bounds[i + 1])}" ${i === k - 1 ? 'disabled' : ''}>
            <input type="text" data-i="${i}" data-f="label" placeholder="${autoLabel(i)}" value="${cls.labels[i] || ''}">
        </div>`;
    }
    html += '<button type="button" class="btn btn-outline-secondary btn-sm mt-2" id="ce-reset">Reset classes to palette</button>';
    editorEl.innerHTML = html;
}
let raf = 0;
if (editorEl) {
    editorEl.addEventListener('input', e => {
        const t = e.target, i = Number(t.dataset.i);
        if (t.dataset.f === 'color') {
            cls.colors[i] = t.value;
            if (!raf) raf = requestAnimationFrame(() => { raf = 0; recolor(); });
        } else if (t.dataset.f === 'label') {
            cls.labels[i] = t.value; drawLegend();
        }
    });
    editorEl.addEventListener('change', e => {
        const t = e.target;
        if (t.dataset.f === 'hi') {
            const i = Number(t.dataset.i), k = P.v_classes;
            const lo = cls.bounds[i], hi = i + 2 <= k ? cls.bounds[i + 2] : topH();
            cls.bounds[i + 1] = Math.min(Math.max(Number(t.value) || lo, lo), hi);
            renderEditor(); recolor();
        }
    });
    editorEl.addEventListener('click', e => {
        if (e.target.id === 'ce-reset') { genBounds(); genColors(); renderEditor(); recolor(); }
    });
}
function resetClasses() { genBounds(); genColors(); renderEditor(); }

// ---------- legend (HTML overlay + canvas copy for PNG export) ----------
function legendModel() {
    const top = topH();
    if (P.v_stepped) {
        const items = [];
        for (let i = P.v_classes - 1; i >= 0; i--)
            items.push({ color: cls.colors[i], label: cls.labels[i] || autoLabel(i) });
        return { title: P.v_legtitle, items };
    }
    return { title: P.v_legtitle, stops: stopsNow().slice().reverse(), top: top.toFixed(Number(P.v_legdec)),
        bottom: (0).toFixed(Number(P.v_legdec)) };
}
function drawLegend() {
    if (!legendEl) return;
    legendEl.style.display = (grid && P.v_legshow) ? 'block' : 'none';
    if (!grid) return;
    const pos = P.v_legpos;
    legendEl.style.left = pos[1] === 'l' ? '14px' : 'auto';
    legendEl.style.right = pos[1] === 'r' ? '14px' : 'auto';
    legendEl.style.top = pos[0] === 't' ? '14px' : 'auto';
    legendEl.style.bottom = pos[0] === 'b' ? '14px' : 'auto';
    legendEl.style.fontSize = (12 * P.v_legsize) + 'px';
    const L = legendModel();
    let html = `<div class="lg-title">${escapeHtml(L.title)}</div>`;
    if (L.items) {
        L.items.forEach(it => {
            html += `<div class="lg-row"><span class="lg-sw" style="background:${it.color}"></span>${escapeHtml(it.label)}</div>`;
        });
    } else {
        html += `<div class="lg-grad"><span class="lg-bar" style="background:linear-gradient(${L.stops.join(',')})"></span>` +
            `<span class="lg-lab"><b>${L.top}</b><b>${L.bottom}</b></span></div>`;
    }
    legendEl.innerHTML = html;
}
const escapeHtml = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function paintLegend(ctx, W) {
    if (!grid || !P.v_legshow) return;
    const f = (W / host.clientWidth) * P.v_legsize, fs = 12 * f, sw = 16 * f, rh = 18 * f, m = 14 * f, pad = 10 * f;
    const L = legendModel(), H = ctx.canvas.height;
    const rows = L.items ? L.items.length : 0, barH = 120 * f;
    ctx.font = `${fs}px system-ui, sans-serif`;
    const labW = L.items ? Math.max(...L.items.map(i => ctx.measureText(i.label).width)) : Math.max(ctx.measureText(L.top).width, ctx.measureText(L.bottom).width);
    ctx.font = `600 ${fs}px system-ui, sans-serif`;
    const bw = Math.max(ctx.measureText(L.title).width, sw + 6 * f + labW) + pad * 2;
    const bh = pad * 2 + fs * 1.4 + (L.items ? rows * rh : barH);
    const x = P.v_legpos[1] === 'l' ? m : W - m - bw, y = P.v_legpos[0] === 't' ? m : H - m - bh;
    ctx.fillStyle = 'rgba(255,255,255,0.85)';
    ctx.beginPath(); ctx.roundRect(x, y, bw, bh, 6 * f); ctx.fill();
    ctx.fillStyle = '#222'; ctx.textBaseline = 'middle';
    ctx.fillText(L.title, x + pad, y + pad + fs * 0.6);
    const y0 = y + pad + fs * 1.4;
    ctx.font = `${fs}px system-ui, sans-serif`;
    if (L.items) {
        L.items.forEach((it, i) => {
            ctx.fillStyle = it.color; ctx.fillRect(x + pad, y0 + i * rh + (rh - sw) / 2, sw, sw);
            ctx.fillStyle = '#222'; ctx.fillText(it.label, x + pad + sw + 6 * f, y0 + i * rh + rh / 2);
        });
    } else {
        const g = ctx.createLinearGradient(0, y0, 0, y0 + barH);
        L.stops.forEach((c, i) => g.addColorStop(i / (L.stops.length - 1), c));
        ctx.fillStyle = g; ctx.fillRect(x + pad, y0, sw, barH);
        ctx.fillStyle = '#222';
        ctx.fillText(L.top, x + pad + sw + 6 * f, y0 + fs * 0.5);
        ctx.fillText(L.bottom, x + pad + sw + 6 * f, y0 + barH - fs * 0.5);
    }
}

// ---------- title ----------
const isDark = c => { const k = new THREE.Color(c); return (0.2126 * k.r + 0.7152 * k.g + 0.0722 * k.b) < 0.18; };
const titleText = () => (P.v_title || autoTitle || '').trim();
function drawTitle() {
    if (!titleEl) return;
    const t = titleText(), sub = (P.v_subtitle || '').trim();
    titleEl.style.display = (grid && P.v_titleshow && (t || sub)) ? 'block' : 'none';
    const centre = P.v_titlealign === 'center';
    titleEl.style.left = centre ? '50%' : '16px';
    titleEl.style.transform = centre ? 'translateX(-50%)' : 'none';
    titleEl.style.textAlign = centre ? 'center' : 'left';
    titleEl.style.color = isDark(P.v_bg) ? '#f2f2f2' : '#1c2b24';
    titleEl.style.fontSize = (22 * P.v_titlesize) + 'px';
    titleEl.innerHTML = (t ? `<div class="mt-t">${escapeHtml(t)}</div>` : '') +
        (sub ? `<div class="mt-s">${escapeHtml(sub)}</div>` : '');
}
function paintTitle(ctx, W) {
    const t = titleText(), sub = (P.v_subtitle || '').trim();
    if (!grid || !P.v_titleshow || (!t && !sub)) return;
    const f = (W / host.clientWidth) * P.v_titlesize, centre = P.v_titlealign === 'center';
    ctx.fillStyle = isDark(P.v_bg) ? '#f2f2f2' : '#1c2b24';
    ctx.textAlign = centre ? 'center' : 'left'; ctx.textBaseline = 'top';
    const x = centre ? W / 2 : 16 * f; let y = 14 * f;
    if (t) { ctx.font = `700 ${22 * f}px system-ui, sans-serif`; ctx.fillText(t, x, y); y += 22 * f * 1.25; }
    if (sub) { ctx.font = `400 ${22 * f * 0.6}px system-ui, sans-serif`; ctx.globalAlpha = 0.75; ctx.fillText(sub, x, y); ctx.globalAlpha = 1; }
    ctx.textAlign = 'left';
}

// ---------- map context: graticule, scale bar, locator, CRS / credits ----------
const CREDIT_TEXT = 'Data: ETH Global Canopy Height 2020 (Lang et al., 2023) · Boundaries: GADM 4.1 · Concept: M. Popovic (milos-agathon/3d-forest-height-maps)';
const geoGroup = new THREE.Group();
scene.add(geoGroup);
const locatorEl = document.getElementById('locator');
const infoEl = document.getElementById('mapinfo');
const geoOf = () => (lastMsg && lastMsg.geo) || null;
const ink = () => (isDark(P.v_bg) ? '#f2f2f2' : '#222222');

function labelSprite(text, color, h) {
    const c = document.createElement('canvas'); c.width = 256; c.height = 64;
    const g = c.getContext('2d'); g.font = '600 34px system-ui, sans-serif';
    g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillStyle = color; g.fillText(text, 128, 34);
    const tex = new THREE.CanvasTexture(c); tex.colorSpace = THREE.SRGBColorSpace;
    const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, transparent: true, depthTest: false, depthWrite: false }));
    sp.scale.set(h * 4, h, 1); sp.renderOrder = 20;
    return sp;
}
function disposeGroup(g) {
    g.children.slice().forEach(o => {
        g.remove(o);
        if (o.geometry) o.geometry.dispose();
        if (o.material) { if (o.material.map) o.material.map.dispose(); o.material.dispose(); }
    });
}
function niceLength(maxKm) {
    const c = [0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000];
    let best = c[0]; for (const v of c) if (v <= maxKm) best = v; return best;
}
function buildGeo() {
    disposeGroup(geoGroup);
    const geo = geoOf(); if (!grid || !geo) return;
    const { nr, nc } = grid, y = -0.003 * dim, col = ink();

    if (P.v_grid && geo.grid && geo.grid.lines.length) {
        const pts = [];
        geo.grid.lines.forEach(l => {
            for (let i = 0; i + 3 < l.length; i += 2) pts.push(l[i], y, l[i + 1], l[i + 2], y, l[i + 3]);
        });
        const g = new THREE.BufferGeometry();
        g.setAttribute('position', new THREE.Float32BufferAttribute(pts, 3));
        const m = new THREE.LineBasicMaterial({ color: col, transparent: true, opacity: P.v_gridop, depthWrite: false });
        const ls = new THREE.LineSegments(g, m); ls.renderOrder = 5; geoGroup.add(ls);
        if (P.v_gridlabels) geo.grid.labels.forEach(lb => {
            const sp = labelSprite(lb.t, col, dim * 0.045);
            sp.material.opacity = Math.min(1, P.v_gridop + 0.35);
            // meridian labels sit just south of the grid end, parallel labels just west of it
            sp.position.set(lb.x + (lb.k === 'lat' ? -dim * 0.06 : 0), y, lb.z + (lb.k === 'lon' ? dim * 0.022 : 0));
            geoGroup.add(sp);
        });
    }

    if (P.v_scalebar && geo.cell_m > 0) {
        const widthKm = nc * geo.cell_m / 1000, L = niceLength(widthKm * 0.3);
        const len = L * 1000 / geo.cell_m, x0 = -nc / 2, z0 = nr / 2 + 0.05 * dim, d = 0.009 * dim, yb = -0.002 * dim;
        [[0, '#222222'], [len / 2, '#ffffff']].forEach(([off, c]) => {
            const m = new THREE.Mesh(new THREE.PlaneGeometry(len / 2, d),
                new THREE.MeshBasicMaterial({ color: c, side: THREE.DoubleSide, depthWrite: false }));
            m.rotation.x = -Math.PI / 2; m.position.set(x0 + off + len / 4, yb, z0); m.renderOrder = 6; geoGroup.add(m);
        });
        const o = new THREE.LineLoop(new THREE.BufferGeometry().setFromPoints([
            new THREE.Vector3(x0, yb, z0 - d / 2), new THREE.Vector3(x0 + len, yb, z0 - d / 2),
            new THREE.Vector3(x0 + len, yb, z0 + d / 2), new THREE.Vector3(x0, yb, z0 + d / 2)]),
            new THREE.LineBasicMaterial({ color: '#222222', depthWrite: false }));
        o.renderOrder = 7; geoGroup.add(o);
        const lab = labelSprite((geo.approx_scale ? '~' : '') + L + ' km', col, dim * 0.05);
        lab.position.set(x0 + len / 2, yb, z0 + dim * 0.03); geoGroup.add(lab);
    }
}

// ----- globe locator (orthographic, centred on the region) -----
const RAD = Math.PI / 180;
function drawGlobe(ctx, cx, cy, R, geo, dark) {
    const lon0 = geo.center[0] * RAD, lat0 = geo.center[1] * RAD, s0 = Math.sin(lat0), c0 = Math.cos(lat0);
    const proj = (lonD, latD) => {
        const l = lonD * RAD, p = latD * RAD, dl = l - lon0;
        const x = Math.cos(p) * Math.sin(dl), yv = c0 * Math.sin(p) - s0 * Math.cos(p) * Math.cos(dl);
        const vis = s0 * Math.sin(p) + c0 * Math.cos(p) * Math.cos(dl) > 0;
        return { x, y: yv, vis };
    };
    const place = q => {
        if (q.vis) return [cx + q.x * R, cy - q.y * R];
        const n = Math.hypot(q.x, q.y) || 1; return [cx + q.x / n * R, cy - q.y / n * R];
    };
    ctx.save();
    ctx.beginPath(); ctx.arc(cx, cy, R, 0, 2 * Math.PI);
    ctx.fillStyle = dark ? '#1e2b33' : '#d8e6ef'; ctx.fill(); ctx.clip();
    ctx.lineWidth = Math.max(0.5, R / 120); ctx.strokeStyle = dark ? 'rgba(255,255,255,.18)' : 'rgba(0,0,0,.13)';
    for (let lo = -180; lo < 180; lo += 30) {           // graticule
        ctx.beginPath(); let pen = false;
        for (let la = -90; la <= 90; la += 5) { const q = proj(lo, la); if (!q.vis) { pen = false; continue; }
            const [px, py] = place(q); pen ? ctx.lineTo(px, py) : ctx.moveTo(px, py); pen = true; }
        ctx.stroke();
    }
    for (let la = -60; la <= 60; la += 30) {
        ctx.beginPath(); let pen = false;
        for (let lo = -180; lo <= 180; lo += 5) { const q = proj(lo, la); if (!q.vis) { pen = false; continue; }
            const [px, py] = place(q); pen ? ctx.lineTo(px, py) : ctx.moveTo(px, py); pen = true; }
        ctx.stroke();
    }
    ctx.fillStyle = dark ? '#58665f' : '#f5f3ea'; ctx.strokeStyle = dark ? '#8fa096' : '#9aa59e'; ctx.lineWidth = Math.max(0.5, R / 150);
    (geo.world || []).forEach(r => {
        ctx.beginPath();
        for (let i = 0; i + 1 < r.length; i += 2) { const [px, py] = place(proj(r[i], r[i + 1])); i ? ctx.lineTo(px, py) : ctx.moveTo(px, py); }
        ctx.closePath(); ctx.fill(); ctx.stroke();
    });
    // extent of the mapped region
    const [x0, y0, x1, y1] = geo.extent, n = 12, ring = [];
    for (let i = 0; i <= n; i++) ring.push([x0 + (x1 - x0) * i / n, y0]);
    for (let i = 0; i <= n; i++) ring.push([x1, y0 + (y1 - y0) * i / n]);
    for (let i = 0; i <= n; i++) ring.push([x1 - (x1 - x0) * i / n, y1]);
    for (let i = 0; i <= n; i++) ring.push([x0, y1 - (y1 - y0) * i / n]);
    const P2 = ring.map(([lo, la]) => place(proj(lo, la)));
    const xs = P2.map(p => p[0]), ys = P2.map(p => p[1]);
    const w = Math.max(...xs) - Math.min(...xs), h = Math.max(...ys) - Math.min(...ys);
    ctx.lineWidth = Math.max(1, R / 55); ctx.strokeStyle = '#e03a2f'; ctx.fillStyle = 'rgba(224,58,47,.35)';
    ctx.beginPath(); P2.forEach((p, i) => i ? ctx.lineTo(p[0], p[1]) : ctx.moveTo(p[0], p[1])); ctx.closePath(); ctx.fill(); ctx.stroke();
    if (Math.max(w, h) < R * 0.16) {                     // tiny region: add a marker ring so it stays visible
        ctx.beginPath(); ctx.arc(cx, cy, R * 0.09, 0, 2 * Math.PI); ctx.stroke();
    }
    ctx.restore();
    ctx.beginPath(); ctx.arc(cx, cy, R, 0, 2 * Math.PI);
    ctx.lineWidth = Math.max(1, R / 60); ctx.strokeStyle = dark ? '#cfd6d2' : '#5b6b63'; ctx.stroke();
}
function drawLocator() {
    if (!locatorEl) return;
    const geo = geoOf(), show = !!(grid && geo && geo.center && P.v_locator);
    locatorEl.style.display = show ? 'block' : 'none';
    if (!show) return;
    const css = 150, dpr = Math.min(window.devicePixelRatio || 1, 2);
    locatorEl.width = css * dpr; locatorEl.height = css * dpr; locatorEl.style.width = css + 'px'; locatorEl.style.height = css + 'px';
    const g = locatorEl.getContext('2d'); g.scale(dpr, dpr); g.clearRect(0, 0, css, css);
    drawGlobe(g, css / 2, css / 2, css / 2 - 3, geo, isDark(P.v_bg));
}

// ----- CRS / scale / credits box -----
function infoLines() {
    const geo = geoOf(), out = [];
    if (!geo) return out;
    if (P.v_info) {
        const cell = geo.cell_m >= 1000 ? (geo.cell_m / 1000).toFixed(2) + ' km' : Math.round(geo.cell_m) + ' m';
        out.push('CRS: ' + geo.crs_label);
        out.push(`Cell size ${geo.approx_scale ? '≈' : ''}${cell} · vertical exaggeration ${Number(P.v_exag).toFixed(1)}× · grid ${geo.grid.step}°`);
    }
    if (P.v_credits) out.push(CREDIT_TEXT);
    return out;
}
function drawInfo() {
    if (!infoEl) return;
    const lines = infoLines();
    infoEl.style.display = (grid && lines.length) ? 'block' : 'none';
    infoEl.innerHTML = lines.map(t => `<div>${escapeHtml(t)}</div>`).join('');
}
function paintInfo(ctx, W) {
    const lines = infoLines(); if (!grid || !lines.length) return;
    const f = W / host.clientWidth, fs = 11 * f, pad = 7 * f, H = ctx.canvas.height;
    ctx.font = `${fs}px system-ui, sans-serif`; ctx.textBaseline = 'top';
    const w = Math.max(...lines.map(t => ctx.measureText(t).width)) + pad * 2, h = lines.length * fs * 1.45 + pad * 2;
    const x = 12 * f, y = H - h - 10 * f;
    ctx.fillStyle = 'rgba(255,255,255,0.82)'; ctx.beginPath(); ctx.roundRect(x, y, w, h, 5 * f); ctx.fill();
    ctx.fillStyle = '#333'; lines.forEach((t, i) => ctx.fillText(t, x + pad, y + pad + i * fs * 1.45));
}
function paintLocator(ctx, W) {
    const geo = geoOf(); if (!grid || !geo || !geo.center || !P.v_locator) return;
    const f = W / host.clientWidth, R = 72 * f;
    drawGlobe(ctx, W - 14 * f - R, 14 * f + R, R, geo, isDark(P.v_bg));
}

// ---------- lighting ----------
function updateSun() {
    const az = P.v_sunaz * Math.PI / 180, alt = P.v_sunalt * Math.PI / 180, d = dim * 1.6;
    sun.position.set(Math.sin(az) * Math.cos(alt) * d, Math.sin(alt) * d, -Math.cos(az) * Math.cos(alt) * d);
    const s = dim * 0.8, cam = sun.shadow.camera;
    cam.left = -s; cam.right = s; cam.top = s; cam.bottom = -s; cam.near = 1; cam.far = d * 3;
    cam.updateProjectionMatrix();
    sun.castShadow = P.v_shadows;
    sun.intensity = 2.6 * (P.v_shadows ? 1 : 0.6);
    hemi.intensity = 2.0 * (1 - 0.65 * P.v_shstrength);
    renderer.shadowMap.needsUpdate = true;
}

function applyAll() {
    scene.background = new THREE.Color(P.v_bg);
    if (ground) { ground.visible = P.v_ground; ground.material.color.set(P.v_bg); }
    if (mesh) mesh.scale.y = P.v_exag;
    camera.fov = P.v_fov; camera.updateProjectionMatrix();
    controls.autoRotate = P.v_rotate;
    updateSun();
    recolor();
    drawTitle();
    buildGeo(); drawLocator(); drawInfo();
}

// ---------- mesh ----------
function build(msg, state) {
    lastMsg = msg;
    palettes = msg.palettes; zmax = Math.max(msg.zmax, 1); autoTitle = msg.title || '';
    const { nrow: nr, ncol: nc } = msg;
    const bin = atob(msg.data), h = new Float32Array(nr * nc);
    for (let i = 0; i < h.length; i++) { const v = bin.charCodeAt(i); h[i] = v === 255 ? -1 : v / 2; }
    grid = { nr, nc, h };
    dim = Math.max(nr, nc); baseH = 0.12 * dim;

    if (mesh) { scene.remove(mesh); mesh.geometry.dispose(); mesh.material.dispose(); }
    if (ground) { scene.remove(ground); ground.geometry.dispose(); ground.material.dispose(); }

    const pos = new Float32Array(nr * nc * 3);
    for (let i = 0; i < nr; i++) for (let j = 0; j < nc; j++) {
        const k = (i * nc + j) * 3, v = h[i * nc + j];
        pos[k] = j - nc / 2; pos[k + 1] = v < 0 ? 0 : v / zmax * baseH; pos[k + 2] = i - nr / 2;
    }
    const idx = [];
    for (let i = 0; i < nr - 1; i++) for (let j = 0; j < nc - 1; j++) {
        const a = i * nc + j, b = a + 1, c = a + nc, d = c + 1;
        if (h[a] < 0 || h[b] < 0 || h[c] < 0 || h[d] < 0) continue; // cut out the country shape
        idx.push(a, c, b, b, c, d);
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    g.setAttribute('color', new THREE.BufferAttribute(new Float32Array(nr * nc * 3), 3));
    g.setIndex(idx);
    g.computeVertexNormals();
    mesh = new THREE.Mesh(g, new THREE.MeshStandardMaterial({ vertexColors: true, roughness: 0.95, metalness: 0 }));
    mesh.castShadow = mesh.receiveShadow = true;
    scene.add(mesh);

    ground = new THREE.Mesh(new THREE.PlaneGeometry(dim * 4, dim * 4),
        new THREE.MeshStandardMaterial({ color: P.v_bg, roughness: 1 }));
    ground.rotation.x = -Math.PI / 2; ground.position.y = -0.006 * dim;
    ground.receiveShadow = true;
    scene.add(ground);

    if (emptyEl) emptyEl.style.display = 'none';
    camera.near = dim / 500; camera.far = dim * 20; camera.updateProjectionMatrix();
    controls.maxDistance = dim * 4;
    if (state && state.camera) {
        camera.position.fromArray(state.camera.pos); controls.target.fromArray(state.camera.target); controls.update();
    } else { lastW = 0; resize(); if (lastW) setView('oblique'); else needFit = true; }
    if (state && state.cls) { Object.assign(cls, state.cls); renderEditor(); } else resetClasses();
    applyAll();
}

// Camera distance that keeps the whole region in frame for the current panel size and field of view.
function setView(kind) {
    const dirs = { oblique: [0, 0.68, 0.73], top: [0, 1, 0.0005], side: [0, 0.22, 0.98] };
    const v = new THREE.Vector3(...dirs[kind]).normalize();
    const R = 0.40 * Math.hypot(grid ? grid.nc : dim, grid ? grid.nr : dim) + baseH * 0.5 * P.v_exag;
    const vf = camera.fov * Math.PI / 180, hf = 2 * Math.atan(Math.tan(vf / 2) * camera.aspect);
    const dist = 1.0 * R / Math.sin(Math.min(vf, hf) / 2);
    // aim slightly south of centre so the scale bar and southern grid labels clear the info box
    controls.target.set(0, 0, 0.09 * dim);
    camera.position.copy(v.multiplyScalar(dist * 1.05)).add(controls.target);
    controls.update();
}

// ---------- wiring ----------
function setParam(name, value) {
    if (!(name in P)) return;
    P[name] = value;
    if (name === 'v_exag') { if (mesh) mesh.scale.y = P.v_exag; drawInfo(); }
    else if (['v_fov', 'v_rotate', 'v_ground', 'v_bg'].includes(name)) applyAll();
    else if (['v_grid', 'v_gridlabels', 'v_gridop', 'v_scalebar'].includes(name)) buildGeo();
    else if (name === 'v_locator') drawLocator();
    else if (name === 'v_info' || name === 'v_credits') drawInfo();
    else if (['v_sunaz', 'v_sunalt', 'v_shadows', 'v_shstrength'].includes(name)) updateSun();
    else if (name === 'v_palette') { genColors(); renderEditor(); recolor(); }
    else if (name === 'v_classes' || name === 'v_hmax') { resetClasses(); recolor(); }
    else if (name === 'v_stepped') { renderEditor(); recolor(); }
    else if (name.startsWith('v_title') || name === 'v_subtitle') drawTitle();
    else drawLegend(); // legend title / position / size / decimals / visibility
}
if (IN_SHINY) {
    window.jQuery(document).on('shiny:inputchanged', e => setParam(e.name, e.value));
    window.Shiny.addCustomMessageHandler('canopy', msg => {
        const iv = window.Shiny.shinyapp.$inputValues || {};
        Object.keys(P).forEach(k => { if (iv[k] !== undefined) P[k] = iv[k]; });
        build(msg);
    });
}

const on = (id, fn) => { const el = document.getElementById(id); if (el) el.onclick = fn; };
on('view-oblique', () => setView('oblique'));
on('view-top', () => setView('top'));
on('view-side', () => setView('side'));

function snapshot(scale = 1) {
    const w = host.clientWidth, h = host.clientHeight, dpr = renderer.getPixelRatio();
    renderer.setPixelRatio(scale); renderer.setSize(w, h, false);   // render at the chosen resolution
    renderer.shadowMap.needsUpdate = true;
    renderer.render(scene, camera);
    const out = document.createElement('canvas');
    out.width = renderer.domElement.width; out.height = renderer.domElement.height;
    const ctx = out.getContext('2d');
    ctx.drawImage(renderer.domElement, 0, 0);
    paintTitle(ctx, out.width);                                     // title + legend are part of the picture
    paintLegend(ctx, out.width);
    paintLocator(ctx, out.width);
    paintInfo(ctx, out.width);
    const url = out.toDataURL('image/png');
    renderer.setPixelRatio(dpr); renderer.setSize(w, h, false);
    renderer.shadowMap.needsUpdate = true;
    const a = document.createElement('a');
    a.href = url;
    a.download = (titleText() || 'forest-height').replace(/[^a-z0-9]+/gi, '-') + '.png';
    a.click();
}
on('snap', () => snapshot(Number(((window.Shiny && window.Shiny.shinyapp.$inputValues) || {}).snap_scale || 1)));

// Public API: used by the shareable HTML export (and handy for debugging)
window.CanopyViewer = {
    set: setParam,
    setView,
    snapshot,
    load(msg, state) {
        if (state && state.P) Object.assign(P, state.P);
        build(msg, state);
    },
    pushState() { // send the light-weight view state to R (used by the "R code" tab)
        if (!window.Shiny) return;
        const st = this.getState();
        window.Shiny.setInputValue('viewer_state', JSON.stringify({ P: st.P, cls: st.cls, camera: st.camera,
            zmax: st.msg ? st.msg.zmax : null }), { priority: 'event' });
    },
    getState() {
        return {
            P: { ...P },
            cls: { colors: [...cls.colors], bounds: [...cls.bounds], labels: [...cls.labels] },
            camera: { pos: camera.position.toArray(), target: controls.target.toArray() },
            msg: lastMsg
        };
    }
};

(function loop() {
    requestAnimationFrame(loop);
    controls.update();
    renderer.render(scene, camera);
})();
