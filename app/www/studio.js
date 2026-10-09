// App-only glue: 3D-map / R-code tabs, and the script copy / download buttons.
(function () {
    const $ = id => document.getElementById(id);
    let current = null;

    function show(which) {
        const code = which === 'code';
        $('pane-map').style.display = code ? 'none' : 'block';
        $('pane-code').style.display = code ? 'flex' : 'none';
        $('tab-map').classList.toggle('active', !code);
        $('tab-code').classList.toggle('active', code);
        if (code) request();
    }
    function request() {
        $('code-info').textContent = 'Generating script from your current view\u2026';
        if (window.CanopyViewer && window.CanopyViewer.pushState) window.CanopyViewer.pushState();
    }

    document.addEventListener('DOMContentLoaded', () => {
        $('tab-map').onclick = () => show('map');
        $('tab-code').onclick = () => show('code');
        $('code-refresh').onclick = request;
        $('code-copy').onclick = () => {
            if (!current) return;
            navigator.clipboard && navigator.clipboard.writeText(current.text);
            $('code-info').textContent = 'Copied to clipboard.';
        };
        $('code-dl').onclick = () => {
            if (!current) return;
            const url = URL.createObjectURL(new Blob([current.text], { type: 'text/plain' }));
            const a = document.createElement('a'); a.href = url; a.download = current.name || 'forest-3d.R'; a.click();
            setTimeout(() => URL.revokeObjectURL(url), 3000);
        };
        window.Shiny.addCustomMessageHandler('code', m => {
            current = m;
            $('code-view').textContent = m.text;
            $('code-info').textContent = `${m.text.split('\n').length} lines \u00b7 reproduces the map you are looking at \u00b7 edit the SETTINGS block to experiment.`;
        });
    });
})();
