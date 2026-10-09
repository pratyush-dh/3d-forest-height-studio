// "Canopy Runner": a tiny chrome-dino-style game to play while tiles download.
// Space / Up / click / tap to jump. Runs only while its canvas is visible.
(function () {
    const cv = document.getElementById('runner');
    if (!cv) return;
    const ctx = cv.getContext('2d');
    const W = cv.width, H = cv.height, GROUND = H - 28;
    let best = Number(localStorage.getItem('runnerBest') || 0);
    let s;

    function reset() {
        s = { y: 0, vy: 0, obs: [], clouds: [{ x: 120, y: 30 }, { x: 420, y: 55 }], speed: 5.2,
              score: 0, t: 0, next: 60, over: false, started: false };
    }
    reset();

    function jump() {
        if (s.over) { reset(); s.started = true; return; }
        s.started = true;
        if (s.y === 0) s.vy = 11.5;
    }
    const visible = () => cv.offsetParent !== null;
    window.addEventListener('keydown', e => {
        if (!visible()) return;
        if ((e.code === 'Space' || e.code === 'ArrowUp') && !/INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName)) {
            e.preventDefault(); jump();
        }
    });
    cv.addEventListener('pointerdown', jump);

    function step() {
        if (!s.started || s.over) return;
        s.t++; s.score += s.speed / 40; s.speed = Math.min(12, s.speed + 0.0009);
        s.vy -= 0.62; s.y = Math.max(0, s.y + s.vy); if (s.y === 0) s.vy = 0;
        if (--s.next <= 0) {
            const tall = Math.random() < 0.4;
            s.obs.push({ x: W + 10, w: tall ? 16 : 22 + Math.random() * 14, h: tall ? 44 : 22 + Math.random() * 10, tall });
            s.next = 55 + Math.random() * 70 * (6 / s.speed + 0.4);
        }
        s.obs.forEach(o => o.x -= s.speed);
        s.obs = s.obs.filter(o => o.x > -50);
        s.clouds.forEach(c => { c.x -= s.speed * 0.25; if (c.x < -60) { c.x = W + 20; c.y = 20 + Math.random() * 50; } });
        const px = 50, pw = 26, ph = 34, py = GROUND - s.y - ph;
        for (const o of s.obs) {
            if (px + pw - 5 > o.x + 3 && px + 5 < o.x + o.w - 3 && py + ph - 2 > GROUND - o.h) {
                s.over = true;
                if (s.score > best) { best = Math.floor(s.score); localStorage.setItem('runnerBest', best); }
            }
        }
    }

    function draw() {
        const dark = false;
        ctx.clearRect(0, 0, W, H);
        ctx.fillStyle = '#f3f8f4'; ctx.fillRect(0, 0, W, H);
        ctx.fillStyle = '#dbe8de';
        s.clouds.forEach(c => { ctx.fillRect(c.x, c.y, 46, 10); ctx.fillRect(c.x + 10, c.y - 8, 26, 8); });
        ctx.fillStyle = '#6b5a3e'; ctx.fillRect(0, GROUND, W, 2);
        ctx.fillStyle = '#b9a98a';
        for (let i = 0; i < 24; i++) ctx.fillRect(((i * 53 - s.t * s.speed * 0.9) % W + W) % W, GROUND + 8 + (i % 3) * 6, 10, 2);

        // obstacles: stumps and tall pines
        s.obs.forEach(o => {
            if (o.tall) {
                ctx.fillStyle = '#205544';
                ctx.beginPath(); ctx.moveTo(o.x + o.w / 2, GROUND - o.h); ctx.lineTo(o.x + o.w + 4, GROUND - 8);
                ctx.lineTo(o.x - 4, GROUND - 8); ctx.fill();
                ctx.fillStyle = '#6b4f2a'; ctx.fillRect(o.x + o.w / 2 - 2, GROUND - 8, 4, 8);
            } else {
                ctx.fillStyle = '#7a5a30'; ctx.fillRect(o.x, GROUND - o.h, o.w, o.h);
                ctx.fillStyle = '#c9a56b'; ctx.fillRect(o.x, GROUND - o.h, o.w, 4);
            }
        });

        // player: little green forester with running legs
        const px = 50, py = GROUND - s.y - 34, leg = s.y > 0 ? 0 : Math.floor(s.t / 5) % 2;
        ctx.fillStyle = '#2f7d4f'; ctx.fillRect(px, py + 8, 26, 18);
        ctx.fillStyle = '#f2c9a0'; ctx.fillRect(px + 6, py, 14, 10);
        ctx.fillStyle = '#205544'; ctx.fillRect(px + 3, py - 4, 20, 5);
        ctx.fillStyle = '#222'; ctx.fillRect(px + 15, py + 3, 3, 3);
        ctx.fillStyle = '#3b3b3b';
        ctx.fillRect(px + 4, py + 26, 6, leg ? 8 : 5); ctx.fillRect(px + 16, py + 26, 6, leg ? 5 : 8);

        ctx.fillStyle = '#205544'; ctx.font = '600 14px system-ui, sans-serif'; ctx.textAlign = 'right';
        ctx.fillText('HI ' + String(best).padStart(5, '0') + '   ' + String(Math.floor(s.score)).padStart(5, '0'), W - 12, 22);
        ctx.textAlign = 'center';
        if (!s.started) ctx.fillText('Press SPACE or tap to start — hop the stumps while your tiles download', W / 2, 70);
        if (s.over) { ctx.font = '700 20px system-ui, sans-serif'; ctx.fillText('Timber! Press SPACE to retry', W / 2, 70); }
    }

    (function loop() { requestAnimationFrame(loop); if (!visible()) return; step(); draw(); })();
})();
