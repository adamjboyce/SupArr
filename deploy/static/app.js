/**
 * SupArr Deploy GUI — Wizard state machine, conditional rendering, SSE consumer.
 * Vanilla JS, no frameworks.
 */

// ── State ────────────────────────────────────────────────────────────────────

const TOKEN = document.querySelector('meta[name="session-token"]')?.content || '';

const STEPS = [
    { num: 1, label: 'Mode' },
    { num: 2, label: 'Targets' },
    { num: 3, label: 'Storage' },
    { num: 4, label: 'Plex' },
    { num: 5, label: '*arr' },
    { num: 6, label: 'Notifications' },
    { num: 7, label: 'Review' },
    { num: 8, label: 'Deploy' },
    { num: 9, label: 'Report' },
];

let currentStep = 1;
let cfg = {};
let schema = [];
let sshKeysReady = false;
let sshTestsPassed = {};
let autoScroll = true;
let activeTerminalTab = 'all';
let terminalLines = [];
let deploySSE = null;
let postdeploySSE = null;

// ── Init ─────────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', async () => {
    buildStepper();
    await loadSchema();
    await loadExistingConfig();
    showStep(1);
});

async function loadSchema() {
    try {
        const resp = await api('GET', '/api/config/schema');
        schema = resp.schema || [];
        // Populate timezone dropdown
        const sel = document.getElementById('tz-select');
        if (sel && resp.timezones) {
            resp.timezones.forEach(tz => {
                const opt = document.createElement('option');
                opt.value = tz;
                opt.textContent = tz;
                if (tz === 'America/Chicago') opt.selected = true;
                sel.appendChild(opt);
            });
        }
        // Set defaults
        cfg = resp.defaults || {};
    } catch (e) {
        console.error('Failed to load schema:', e);
    }
}

async function loadExistingConfig() {
    try {
        const resp = await api('GET', '/api/config/load');
        if (resp.found && resp.config) {
            // Merge existing values over defaults
            Object.assign(cfg, resp.config);
            populateForm();
        }
    } catch (e) {
        console.error('Failed to load existing config:', e);
    }
}

// ── API Helper ───────────────────────────────────────────────────────────────

async function api(method, path, body) {
    const opts = {
        method,
        headers: {
            'X-Session-Token': TOKEN,
            'Content-Type': 'application/json',
        },
    };
    if (body) opts.body = JSON.stringify(body);
    const resp = await fetch(path, opts);
    return resp.json();
}

// ── Stepper ──────────────────────────────────────────────────────────────────

function buildStepper() {
    const el = document.getElementById('stepper');
    el.innerHTML = STEPS.map((s, i) => {
        const connector = i < STEPS.length - 1 ? '<span class="step-connector"></span>' : '';
        return `<span class="step-indicator" data-step="${s.num}">
            <span class="step-num">${s.num}</span>${s.label}
        </span>${connector}`;
    }).join('');
}

function updateStepper() {
    document.querySelectorAll('.step-indicator').forEach(el => {
        const num = parseInt(el.dataset.step);
        el.classList.remove('active', 'completed');
        if (num === currentStep) el.classList.add('active');
        else if (num < currentStep) el.classList.add('completed');
    });
}

// ── Step Navigation ──────────────────────────────────────────────────────────

function showStep(n) {
    currentStep = n;
    document.querySelectorAll('.step-panel').forEach(el => {
        el.classList.toggle('hidden', parseInt(el.dataset.step) !== n);
    });

    // Widen main for deploy/report steps
    const main = document.getElementById('main-content');
    main.classList.toggle('wide', n >= 8);

    updateStepper();
    updateConditionalFields();
    if (n === 7) buildReview();
}

function nextStep() {
    collectFormValues();
    if (currentStep < 9) showStep(currentStep + 1);
}

function prevStep() {
    collectFormValues();
    if (currentStep > 1) showStep(currentStep - 1);
}

function goToStep(n) {
    collectFormValues();
    showStep(n);
}

// ── Form Value Collection ────────────────────────────────────────────────────

function collectFormValues() {
    document.querySelectorAll('[data-key]').forEach(el => {
        const key = el.dataset.key;
        if (el.type === 'checkbox') {
            cfg[key] = el.checked ? 'true' : 'false';
        } else {
            cfg[key] = el.value;
        }
    });
}

function populateForm() {
    document.querySelectorAll('[data-key]').forEach(el => {
        const key = el.dataset.key;
        if (cfg[key] === undefined) return;
        if (el.type === 'checkbox') {
            el.checked = cfg[key] === 'true';
        } else {
            el.value = cfg[key];
        }
    });
    // Sync UI state
    if (cfg.deploy_mode) selectMode(cfg.deploy_mode, true);
    if (cfg.vpn_type) selectChoice('vpn_type', cfg.vpn_type, true);
    if (cfg.migrate_library === 'true') toggleMigration();
    updateWatchtower();
}

// ── Deploy Mode Selection ────────────────────────────────────────────────────

function selectMode(mode, noCollect) {
    if (!noCollect) collectFormValues();
    cfg.deploy_mode = mode;
    document.querySelectorAll('.mode-card').forEach(el => {
        el.classList.toggle('selected', el.dataset.value === mode);
    });
    updateConditionalFields();
}

// ── Choice Card Selection ────────────────────────────────────────────────────

function selectChoice(key, value, noCollect) {
    if (!noCollect) collectFormValues();
    cfg[key] = value;

    // Update choice card visuals in parent
    const cards = document.querySelectorAll(`.choice-card[data-value]`);
    // Only toggle cards that are siblings (same choice group)
    let targetCard = null;
    cards.forEach(c => {
        if (c.dataset.value === value) targetCard = c;
    });
    if (targetCard) {
        const parent = targetCard.parentElement;
        parent.querySelectorAll('.choice-card').forEach(c => {
            c.classList.toggle('selected', c.dataset.value === value);
        });
    }

    updateConditionalFields();
}

// ── Conditional Field Visibility ─────────────────────────────────────────────

function updateConditionalFields() {
    const mode = cfg.deploy_mode || 'two';
    const isSingle = mode === 'single';
    const vpnType = cfg.vpn_type || 'wireguard';
    const hasNAS = (cfg.nas_ip || '') !== '';

    // Target fields
    toggle('targets-two', !isSingle);
    toggle('targets-single', isSingle);

    // Storage paths
    toggle('paths-two', !isSingle);
    toggle('paths-single', isSingle);

    // NAS fields
    toggle('nas-fields', hasNAS);

    // VPN type
    toggle('vpn-wireguard', vpnType === 'wireguard');
    toggle('vpn-openvpn', vpnType === 'openvpn');

    // Migration fields
    const migrating = cfg.migrate_library === 'true';
    toggle('migration-fields', migrating);
    if (migrating) {
        toggle('migrate-local', !hasNAS);
        toggle('migrate-nas', hasNAS);
    }
}

function toggle(id, show) {
    const el = document.getElementById(id);
    if (el) el.classList.toggle('hidden', !show);
}

// ── Watchtower URL Derivation ────────────────────────────────────────────────

function updateWatchtower() {
    const input = document.querySelector('[data-key="discord_webhook_url"]');
    const output = document.getElementById('watchtower-url');
    if (!input || !output) return;

    const url = input.value || '';
    const match = url.match(/https?:\/\/discord\.com\/api\/webhooks\/(\d+)\/(.+)/);
    if (match) {
        output.value = `discord://${match[2]}@${match[1]}`;
    } else {
        output.value = '';
    }
    cfg.watchtower_notification_url = output.value;
}

// ── Migration Toggle ─────────────────────────────────────────────────────────

function toggleMigration() {
    const cb = document.querySelector('[data-key="migrate_library"]');
    cfg.migrate_library = cb && cb.checked ? 'true' : 'false';
    updateConditionalFields();
}

// ── SSH Connection Test ──────────────────────────────────────────────────────

async function testHost(key) {
    collectFormValues();
    const host = cfg[key];
    if (!host) return;

    const statusEl = document.getElementById(`status-${key}`);
    statusEl.innerHTML = '<span class="spinner"></span> Testing...';

    const result = await api('POST', '/api/ssh/test', {
        host: host,
        user: cfg.ssh_user || 'root',
    });

    if (result.ok) {
        statusEl.innerHTML = '<span class="status-badge success"><span class="status-dot"></span>Connected</span>';
        sshTestsPassed[key] = true;
    } else {
        statusEl.innerHTML = `<span class="status-badge error"><span class="status-dot"></span>${esc(result.message)}</span>`;
        sshTestsPassed[key] = false;
    }
}

// ── SSH Key Setup ────────────────────────────────────────────────────────────

async function setupSSHKeys() {
    collectFormValues();
    const btn = document.getElementById('ssh-setup-btn');
    const status = document.getElementById('ssh-key-status');

    btn.disabled = true;
    status.innerHTML = '<span class="spinner"></span> Setting up SSH keys...';

    const hosts = [];
    if (cfg.deploy_mode === 'single') {
        if (cfg.single_ip) hosts.push(cfg.single_ip);
    } else {
        if (cfg.plex_ip) hosts.push(cfg.plex_ip);
        if (cfg.arr_ip) hosts.push(cfg.arr_ip);
    }

    const result = await api('POST', '/api/ssh/setup-keys', {
        hosts: hosts,
        user: cfg.ssh_user || 'root',
        password: cfg.ssh_pass || '',
    });

    btn.disabled = false;

    if (result.ok) {
        status.innerHTML = '<span class="status-badge success"><span class="status-dot"></span>Keys deployed</span>';
        sshKeysReady = true;
        document.getElementById('deploy-btn').disabled = false;
    } else {
        const msgs = (result.results || []).filter(r => !r.ok).map(r => r.message).join('; ');
        status.innerHTML = `<span class="status-badge error"><span class="status-dot"></span>${esc(msgs || result.message)}</span>`;
    }
}

// ── Trakt Auth ───────────────────────────────────────────────────────────────

async function startTraktAuth() {
    collectFormValues();
    const clientId = cfg.trakt_client_id;
    const clientSecret = cfg.trakt_client_secret;

    if (!clientId || !clientSecret) {
        document.getElementById('trakt-auth-status').textContent = 'Enter Client ID and Secret first';
        return;
    }

    const result = await api('POST', '/api/trakt/start', {
        client_id: clientId,
        client_secret: clientSecret,
    });

    if (!result.ok) {
        document.getElementById('trakt-auth-status').textContent = result.message;
        return;
    }

    // Show modal
    document.getElementById('trakt-code').textContent = result.user_code;
    const urlEl = document.getElementById('trakt-url');
    urlEl.href = result.verification_url;
    urlEl.textContent = result.verification_url;
    document.getElementById('trakt-modal').classList.remove('hidden');

    // Start polling SSE
    pollTraktAuth();
}

function pollTraktAuth() {
    const es = new EventSource(`/api/trakt/poll?token=${TOKEN}`);
    // Note: SSE doesn't support custom headers, so we pass token as query param
    // The server should also accept query param auth for SSE endpoints

    es.addEventListener('trakt', (e) => {
        const data = JSON.parse(e.data);
        if (data.status === 'success') {
            es.close();
            cfg.trakt_access_token = data.tokens?.access_token || '';
            cfg.trakt_refresh_token = data.tokens?.refresh_token || '';
            document.getElementById('trakt-modal-status').textContent = 'Authorized!';
            document.getElementById('trakt-auth-status').textContent = 'Authorized';
            setTimeout(closeTraktModal, 1500);
        } else if (data.status === 'timeout') {
            es.close();
            document.getElementById('trakt-modal-status').textContent = 'Timed out. Try again.';
        }
    });

    es.addEventListener('heartbeat', () => {});
    es.onerror = () => { es.close(); };
}

function closeTraktModal() {
    document.getElementById('trakt-modal').classList.add('hidden');
}

// ── Review Summary ───────────────────────────────────────────────────────────

function buildReview() {
    collectFormValues();
    const el = document.getElementById('review-summary');

    const sections = [
        { title: 'Deploy Mode', keys: ['deploy_mode'] },
        { title: 'Targets', keys: cfg.deploy_mode === 'single' ? ['single_ip'] : ['plex_ip', 'arr_ip'] },
        { title: 'Storage', keys: ['puid', 'pgid', 'tz', 'local_subnet'] },
        { title: 'Plex', keys: ['plex_claim_token', 'plex_token', 'tmdb_api_key', 'trakt_client_id'] },
        { title: 'VPN', keys: ['vpn_type', 'nord_country', 'nord_city'] },
        { title: 'Notifications', keys: ['discord_webhook_url'] },
    ];

    // Secret fields that should be masked
    const secretKeys = new Set(['ssh_pass', 'nord_pass', 'nord_wireguard_key', 'qbit_password',
        'trakt_client_secret', 'immich_db_password', 'plex_token']);

    el.innerHTML = sections.map(s => {
        const rows = s.keys
            .filter(k => cfg[k])
            .map(k => {
                const field = schema.find(f => f.key === k);
                const label = field ? field.label : k;
                const val = cfg[k] || '';
                const isSecret = secretKeys.has(k) || (field && field.secret);
                const display = isSecret ? maskValue(val) : esc(val);
                const cls = isSecret ? ' secret clickable' : '';
                const dataAttr = isSecret ? ` data-secret-key="${esc(k)}"` : '';
                return `<div class="summary-row">
                    <span class="summary-key">${esc(label)}</span>
                    <span class="summary-value${cls}"${dataAttr}>${display}</span>
                </div>`;
            }).join('');
        if (!rows) return '';
        return `<div class="summary-section">
            <div class="summary-section-title">${esc(s.title)}</div>
            ${rows}
        </div>`;
    }).join('');

    // Attach click handlers for secret reveal (avoids inline onclick XSS)
    el.querySelectorAll('[data-secret-key]').forEach(span => {
        span.addEventListener('click', () => {
            const key = span.dataset.secretKey;
            const val = cfg[key] || '';
            const masked = maskValue(val);
            span.textContent = span.textContent.includes('*') ? val : masked;
        });
    });

    // Enable deploy button if SSH keys are ready
    document.getElementById('deploy-btn').disabled = !sshKeysReady;
}

function maskValue(val) {
    if (!val) return '';
    if (val.length <= 4) return '****';
    return val.substring(0, 2) + '*'.repeat(Math.min(val.length - 4, 12)) + val.substring(val.length - 2);
}

// ── Deploy ───────────────────────────────────────────────────────────────────

async function startDeploy() {
    collectFormValues();

    // Save config first
    const saveResult = await api('POST', '/api/config/save', { config: cfg });
    if (!saveResult.ok) {
        alert('Config validation failed: ' + JSON.stringify(saveResult.errors));
        return;
    }

    // Start deploy
    const result = await api('POST', '/api/deploy/start', { config: cfg });
    if (!result.ok) {
        alert(result.message);
        return;
    }

    // Switch to deploy progress view
    terminalLines = [];
    showStep(8);
    connectDeploySSE();
}

function connectDeploySSE() {
    if (deploySSE) deploySSE.close();

    // Use fetch + ReadableStream for SSE with auth header
    const ctrl = new AbortController();
    deploySSE = ctrl;

    fetch('/api/deploy/stream', {
        headers: { 'X-Session-Token': TOKEN },
        signal: ctrl.signal,
    }).then(resp => {
        const reader = resp.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';

        function read() {
            reader.read().then(({ done, value }) => {
                if (done) return;
                buffer += decoder.decode(value, { stream: true });

                // Parse SSE events from buffer
                const parts = buffer.split('\n\n');
                buffer = parts.pop(); // Keep incomplete chunk

                parts.forEach(chunk => {
                    const lines = chunk.split('\n');
                    let eventType = 'message';
                    let eventData = '';
                    lines.forEach(line => {
                        if (line.startsWith('event: ')) eventType = line.slice(7);
                        else if (line.startsWith('data: ')) eventData = line.slice(6);
                    });
                    if (eventData) handleDeployEvent(eventType, eventData);
                });

                read();
            }).catch(() => {});
        }
        read();
    }).catch(() => {});
}

function handleDeployEvent(type, rawData) {
    let data;
    try { data = JSON.parse(rawData); } catch { data = { data: rawData }; }

    if (type === 'heartbeat') return;

    if (type === 'status') {
        if (data.status === 'done') {
            finishDeploy(true);
        } else if (data.status === 'error') {
            finishDeploy(false, data.error);
        } else if (data.status === 'cancelled') {
            finishDeploy(false, 'Deploy cancelled');
        }
        return;
    }

    // Log line
    const line = {
        type: type,
        text: data.data || data.text || rawData,
        machine: data.machine || 'system',
    };
    terminalLines.push(line);

    // Update progress bars
    updateProgress();

    // Render to terminal
    appendTerminalLine(line);
}

function appendTerminalLine(line) {
    if (activeTerminalTab !== 'all' && line.machine !== activeTerminalTab && line.machine !== 'system') {
        return;
    }

    const body = document.getElementById('terminal-body');
    const div = document.createElement('div');
    div.className = `log-line ${line.type}`;
    const prefix = line.machine !== 'system' ? `[${line.machine}] ` : '';
    div.textContent = prefix + line.text;
    body.appendChild(div);

    if (autoScroll) {
        body.scrollTop = body.scrollHeight;
    }
}

let _progressTimer = null;
function updateProgress() {
    // Debounce: don't flood the server with status polls on every log line
    if (_progressTimer) return;
    _progressTimer = setTimeout(() => { _progressTimer = null; }, 2000);
    // Poll deploy status for phase info
    api('GET', '/api/deploy/status').then(state => {
        if (!state) return;

        // Plex progress
        const plexPct = state.plex_total_phases > 0
            ? Math.round((state.plex_phase / state.plex_total_phases) * 100) : 0;
        const plexBar = document.getElementById('progress-plex-bar');
        const plexText = document.getElementById('progress-plex-text');
        if (plexBar) {
            plexBar.style.width = plexPct + '%';
            if (state.plex_result === 0) plexBar.classList.add('complete');
            else if (state.plex_result > 0) plexBar.classList.add('error');
        }
        if (plexText) {
            if (state.plex_result === 0) plexText.textContent = 'Complete';
            else if (state.plex_result > 0) plexText.textContent = 'Failed';
            else if (state.plex_phase > 0) plexText.textContent = `Phase ${state.plex_phase}/${state.plex_total_phases}`;
        }

        // Arr progress
        const arrPct = state.arr_total_phases > 0
            ? Math.round((state.arr_phase / state.arr_total_phases) * 100) : 0;
        const arrBar = document.getElementById('progress-arr-bar');
        const arrText = document.getElementById('progress-arr-text');
        if (arrBar) {
            arrBar.style.width = arrPct + '%';
            if (state.arr_result === 0) arrBar.classList.add('complete');
            else if (state.arr_result > 0) arrBar.classList.add('error');
        }
        if (arrText) {
            if (state.arr_result === 0) arrText.textContent = 'Complete';
            else if (state.arr_result > 0) arrText.textContent = 'Failed';
            else if (state.arr_phase > 0) arrText.textContent = `Phase ${state.arr_phase}/${state.arr_total_phases}`;
        }

        // Tab dots
        updateTabDot('tab-dot-plex', state.plex_result);
        updateTabDot('tab-dot-arr', state.arr_result);
    });
}

function updateTabDot(id, result) {
    const dot = document.getElementById(id);
    if (!dot) return;
    dot.classList.remove('running', 'success', 'error');
    if (result === 0) dot.classList.add('success');
    else if (result > 0) dot.classList.add('error');
    else dot.classList.add('running');
}

function finishDeploy(success, error) {
    if (deploySSE && deploySSE.abort) deploySSE.abort();
    deploySSE = null;

    document.getElementById('cancel-btn').disabled = true;

    // Auto-advance to report after a short delay
    setTimeout(() => {
        showStep(9);
        buildReport(success, error);
        if (success) connectPostdeploySSE();
    }, 1500);
}

async function cancelDeploy() {
    await api('POST', '/api/deploy/cancel');
}

// ── Terminal Controls ────────────────────────────────────────────────────────

function switchTerminalTab(machine) {
    activeTerminalTab = machine;
    document.querySelectorAll('.terminal-tab').forEach(el => {
        el.classList.toggle('active', el.dataset.machine === machine);
    });
    // Re-render
    const body = document.getElementById('terminal-body');
    body.innerHTML = '';
    terminalLines.forEach(line => appendTerminalLine(line));
}

function toggleScrollLock() {
    autoScroll = !autoScroll;
    const btn = document.getElementById('scroll-lock-btn');
    btn.style.color = autoScroll ? 'var(--accent)' : 'var(--text-muted)';
    if (autoScroll) {
        const body = document.getElementById('terminal-body');
        body.scrollTop = body.scrollHeight;
    }
}

// ── Post-Deploy Report ───────────────────────────────────────────────────────

async function buildReport(success, error) {
    const msgEl = document.getElementById('deploy-result-msg');
    if (success) {
        msgEl.textContent = 'Both machines deployed successfully.';
        msgEl.style.color = 'var(--success)';
    } else {
        msgEl.textContent = error || 'Deploy failed.';
        msgEl.style.color = 'var(--error)';
    }

    // Fetch service URLs
    try {
        const state = await api('GET', '/api/deploy/status');
        if (state.services) {
            renderServices('services-plex', state.services.plex || []);
            renderServices('services-arr', state.services.arr || []);
        }
    } catch (e) {
        console.error('Failed to load services:', e);
    }
}

function renderServices(containerId, services) {
    const el = document.getElementById(containerId);
    if (!el) return;
    el.innerHTML = services.map(s =>
        `<a class="service-card" href="${esc(s.url)}" target="_blank">
            <div>
                <div class="service-name">${esc(s.name)}</div>
                <div class="service-port">:${s.port}</div>
            </div>
        </a>`
    ).join('');
}

function connectPostdeploySSE() {
    if (postdeploySSE) postdeploySSE.close();

    const ctrl = new AbortController();
    postdeploySSE = ctrl;

    fetch('/api/postdeploy/stream', {
        headers: { 'X-Session-Token': TOKEN },
        signal: ctrl.signal,
    }).then(resp => {
        const reader = resp.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';

        function read() {
            reader.read().then(({ done, value }) => {
                if (done) return;
                buffer += decoder.decode(value, { stream: true });

                const parts = buffer.split('\n\n');
                buffer = parts.pop();

                parts.forEach(chunk => {
                    const lines = chunk.split('\n');
                    let eventType = 'message';
                    let eventData = '';
                    lines.forEach(line => {
                        if (line.startsWith('event: ')) eventType = line.slice(7);
                        else if (line.startsWith('data: ')) eventData = line.slice(6);
                    });
                    if (eventData) handlePostdeployEvent(eventType, eventData);
                });

                read();
            }).catch(() => {});
        }
        read();
    }).catch(() => {});
}

function handlePostdeployEvent(type, rawData) {
    if (type === 'heartbeat') return;
    let data;
    try { data = JSON.parse(rawData); } catch { data = { data: rawData }; }

    const log = document.getElementById('postdeploy-log');
    if (!log) return;

    const div = document.createElement('div');
    const text = data.data || rawData;
    const cls = type === 'success' ? 'alert-success' : type === 'error' ? 'alert-error' :
                type === 'warning' ? 'alert-warning' : 'alert-info';
    div.className = `alert ${cls}`;
    div.textContent = text;
    log.appendChild(div);

    if (type === 'done' || (data.type === 'done')) {
        if (postdeploySSE && postdeploySSE.abort) postdeploySSE.abort();
        postdeploySSE = null;
    }
}

// ── Utilities ────────────────────────────────────────────────────────────────

function esc(str) {
    if (!str) return '';
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}
