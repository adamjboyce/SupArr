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
    { num: 6, label: 'Components' },
    { num: 7, label: 'Notifications' },
    { num: 8, label: 'Review' },
    { num: 9, label: 'Deploy' },
    { num: 10, label: 'Report' },
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

    // Check deploy state and route accordingly
    try {
        const state = await api('GET', '/api/deploy/status');
        if (state) {
            if (['syncing', 'deploying'].includes(state.status)) {
                // Actively deploying — reconnect to live terminal
                showStep(9);
                connectDeploySSE();
                return;
            }
            if (state.status === 'done') {
                // Completed — show report
                showStep(10);
                buildReport(true);
                return;
            }
            if (['error', 'cancelled', 'post_deploy'].includes(state.status)) {
                // Failed or finished post-deploy — go to review so user can re-deploy
                showStep(8);
                return;
            }
        }
    } catch {}

    // Restore last wizard step, or start at 1
    const saved = parseInt(sessionStorage.getItem('suparr_step'));
    showStep(saved >= 1 && saved <= 8 ? saved : 1);
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
    // Layer 1: server-side config from .env files
    try {
        const resp = await api('GET', '/api/config/load');
        if (resp.found && resp.config) {
            Object.assign(cfg, resp.config);
        }
    } catch (e) {
        console.error('Failed to load existing config:', e);
    }
    // Layer 2: localStorage fills in wizard-only fields (IPs, SSH password, etc.)
    // that aren't persisted in .env files. Merge without overwriting server values.
    try {
        const saved = localStorage.getItem('suparr_cfg');
        if (saved) {
            const parsed = JSON.parse(saved);
            for (const [k, v] of Object.entries(parsed)) {
                if (!cfg[k] && v) cfg[k] = v;
            }
        }
    } catch (e) {
        console.error('Failed to restore config from localStorage:', e);
    }
    populateForm();
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
    main.classList.toggle('wide', n >= 9);

    // Persist step so refresh doesn't reset (wizard steps only, not deploy/report)
    if (n <= 8) sessionStorage.setItem('suparr_step', n);

    updateStepper();
    updateConditionalFields();
    if (n === 6) buildPicker();
    if (n === 8) buildReview();
}

function nextStep() {
    collectFormValues();
    if (currentStep < 10) showStep(currentStep + 1);
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
        } else if (el.value) {
            // Only overwrite with non-empty values — prevents blank fields
            // on unvisited steps from nuking saved config
            cfg[key] = el.value;
        }
    });
    // Persist to localStorage so config survives server restarts
    try { localStorage.setItem('suparr_cfg', JSON.stringify(cfg)); } catch {}
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
    updateImportVisibility();
    updateVpnFields();
    restoreMediaCategories();
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

// ── VPN Provider Fields ─────────────────────────────────────────────────────

function updateVpnFields() {
    collectFormValues();
    const provider = cfg.vpn_provider || 'nordvpn';
    const isCustom = provider === 'custom';

    // Protocol choice: hidden for custom (always openvpn)
    const protocolEl = document.getElementById('vpn-protocol');
    if (protocolEl) protocolEl.classList.toggle('hidden', isCustom);
    if (isCustom) cfg.vpn_type = 'openvpn';

    // Custom config field
    const customEl = document.getElementById('vpn-custom');
    if (customEl) customEl.classList.toggle('hidden', !isCustom);

    // Server selection: hidden for custom
    const serverEl = document.getElementById('vpn-server');
    if (serverEl) serverEl.classList.toggle('hidden', isCustom);

    // WireGuard addresses hint: highlight for Mullvad/IVPN
    const wgAddr = document.getElementById('vpn-wg-addresses');
    if (wgAddr) {
        const needsAddr = provider === 'mullvad' || provider === 'ivpn';
        const label = wgAddr.querySelector('.form-label');
        if (label) {
            label.innerHTML = needsAddr
                ? 'WireGuard Addresses <span style="color:var(--warning)">(required)</span>'
                : 'WireGuard Addresses <span class="optional">(optional)</span>';
        }
    }

    // Show/hide based on vpn_type
    updateConditionalFields();
}

// ── Import List Visibility ───────────────────────────────────────────────────

function updateImportVisibility() {
    collectFormValues();
    const sources = ['tmdb', 'trakt', 'mdblist', 'imdb'];
    for (const src of sources) {
        const el = document.getElementById(`import-${src}-fields`);
        if (el) {
            const on = cfg[`import_${src}`] === 'true';
            el.classList.toggle('hidden', !on);
        }
    }
}

// ── Media Categories ─────────────────────────────────────────────────────────

function collectMediaCategories() {
    const cats = [];
    document.querySelectorAll('#media-categories-grid input[data-cat]').forEach(cb => {
        if (cb.checked) cats.push(cb.dataset.cat);
    });
    cfg.media_categories = cats.join(',');
    const hidden = document.querySelector('[data-key="media_categories"]');
    if (hidden) hidden.value = cfg.media_categories;
}

function restoreMediaCategories() {
    const cats = (cfg.media_categories || '').split(',').filter(Boolean);
    document.querySelectorAll('#media-categories-grid input[data-cat]').forEach(cb => {
        cb.checked = cats.length === 0 || cats.includes(cb.dataset.cat);
    });
}

// Patch collectFormValues to also sync media categories
const _origCollectBase = collectFormValues;
collectFormValues = function() {
    _origCollectBase();
    collectMediaCategories();
};

// ── SSH Connection Test ──────────────────────────────────────────────────────

async function testHost(key) {
    collectFormValues();
    const host = cfg[key];
    if (!host) return;

    const statusEl = document.getElementById(`status-${key}`);
    statusEl.innerHTML = '<span class="spinner"></span> Testing...';

    // Try key-based auth first
    let result = await api('POST', '/api/ssh/test', {
        host: host,
        user: cfg.ssh_user || 'root',
    });

    // If key auth fails and we have a password, deploy key and retry
    if (!result.ok && cfg.ssh_pass) {
        statusEl.innerHTML = '<span class="spinner"></span> Deploying SSH key...';
        const setup = await api('POST', '/api/ssh/setup-keys', {
            hosts: [host],
            user: cfg.ssh_user || 'jolly',
            password: cfg.ssh_pass,
            root_password: cfg.root_pass || '',
        });
        if (setup.ok) {
            result = { ok: true, message: `Connected to ${host}` };
        } else {
            const failMsg = setup.results?.find(r => !r.ok)?.message || setup.message || 'Key setup failed';
            result = { ok: false, message: failMsg };
        }
    }

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

// ── Component Picker ─────────────────────────────────────────────────────────

let componentData = null;

async function loadComponentData() {
    if (componentData) return componentData;
    try {
        const resp = await api('GET', '/api/config/components');
        componentData = resp;
        return resp;
    } catch (e) {
        console.error('Failed to load components:', e);
        return null;
    }
}

async function buildPicker() {
    const container = document.getElementById('component-picker');
    if (!container) return;

    const data = await loadComponentData();
    if (!data) {
        container.innerHTML = '<p>Failed to load component data.</p>';
        return;
    }

    // Initialize selected_services from defaults if not set
    if (!cfg.selected_services || typeof cfg.selected_services !== 'object') {
        cfg.selected_services = {};
        for (const [key, comp] of Object.entries(data.components)) {
            if (!comp.always && comp.profile) {
                cfg.selected_services[key] = comp.default !== undefined ? comp.default : false;
            }
        }
    }

    let html = '';
    for (const tier of data.tiers) {
        const comps = Object.entries(data.components)
            .filter(([_, c]) => c.tier === tier.id);
        if (!comps.length) continue;

        const warnClass = tier.warn ? ' tier-warn' : '';
        html += `<div class="picker-tier${warnClass}" data-tier="${tier.id}">`;
        html += `<div class="picker-tier-header">`;
        html += `<span class="picker-tier-label">${tier.label}</span>`;
        html += `<span class="picker-tier-hint">${tier.hint}</span>`;
        html += `</div>`;

        if (tier.warn) {
            html += `<div class="picker-warn-banner">Deselecting these is not recommended. They provide critical automation for the stack.</div>`;
        }

        html += `<div class="picker-grid">`;
        for (const [key, comp] of comps) {
            const checked = cfg.selected_services[key] ? 'checked' : '';
            const autoTag = comp.auto_with ? `<span class="picker-auto">auto</span>` : '';
            html += `<label class="picker-item" data-key="${key}">`;
            html += `<input type="checkbox" ${checked} onchange="toggleComponent('${key}', this.checked)">`;
            html += `<div class="picker-item-info">`;
            html += `<span class="picker-item-label">${comp.label}${autoTag}</span>`;
            if (comp.desc) html += `<span class="picker-item-desc">${comp.desc}</span>`;
            html += `</div></label>`;
        }
        html += `</div></div>`;
    }

    container.innerHTML = html;
    applyDependencies();
}

function toggleComponent(key, checked) {
    if (!cfg.selected_services) cfg.selected_services = {};
    cfg.selected_services[key] = checked;
    applyDependencies();
}

function applyDependencies() {
    if (!componentData || !cfg.selected_services) return;

    // Whisparr enables stash + stash-tagger
    const whisparrOn = cfg.selected_services['whisparr'];
    for (const [key, comp] of Object.entries(componentData.components)) {
        if (comp.auto_with === 'whisparr') {
            cfg.selected_services[key] = !!whisparrOn;
            const cb = document.querySelector(`.picker-item[data-key="${key}"] input`);
            if (cb) {
                cb.checked = !!whisparrOn;
                cb.disabled = !!whisparrOn;
            }
        }
    }
}

// selected_services is kept in cfg as an object — serializes directly to JSON

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
    const secretKeys = new Set(['ssh_pass', 'root_pass', 'nord_pass', 'nord_wireguard_key', 'qbit_password',
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
    showStep(9);
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

    if (success) {
        // Clear saved config on successful deploy
        try { localStorage.removeItem('suparr_cfg'); } catch {}
        // Success: advance to report step after brief delay
        setTimeout(() => {
            showStep(10);
            buildReport(true);
            connectPostdeploySSE();
        }, 1500);
    } else {
        // Failure: stay on terminal (step 9) so user can see the output
        // Add error banner above terminal
        const termPanel = document.querySelector('[data-step="9"]');
        let banner = document.getElementById('deploy-error-banner');
        if (!banner) {
            banner = document.createElement('div');
            banner.id = 'deploy-error-banner';
            banner.style.cssText = 'background:var(--error-bg, #2d1b1b);border:1px solid var(--error, #e74c3c);color:var(--error, #e74c3c);padding:12px 16px;border-radius:8px;margin-bottom:12px;display:flex;justify-content:space-between;align-items:center;';
            termPanel.insertBefore(banner, termPanel.firstChild);
        }
        const errMsg = error || 'Deploy failed';
        banner.innerHTML = `<span><strong>Deploy failed:</strong> ${esc(errMsg)}</span>` +
            `<button class="btn btn-sm" onclick="showStep(10);buildReport(false,'${esc(errMsg).replace(/'/g, "\\'")}')">View Report</button>`;

        // Build report in background so it's ready if user navigates
        buildReport(false, error);
    }
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
