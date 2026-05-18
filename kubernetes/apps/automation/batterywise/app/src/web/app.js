// BatteryWise — Frontend Application
'use strict';

// ============================================================
// STATE
// ============================================================
const state = {
  dataLoaded: false,
  scenarios: [{ id: 'default', name: 'Scenario 1', result: null }],
  activeScenario: 'default',
  scenarioCounter: 1,
  timeline: new Array(24).fill('idle'), // charge | discharge | idle
  thresholdRules: [],
  touWindows: [],
  charts: {},
  activePlanMeta: { name: 'Current Plan' },
  lastSimulationResult: null,
};

// ============================================================
// INITIALIZATION
// ============================================================
document.addEventListener('DOMContentLoaded', () => {
  initTimeline();
  loadPlanPreset('current');
  loadStrategyPreset('current_optimal');
  checkDataStatus();
});

// ============================================================
// DATA MANAGEMENT
// ============================================================
async function uploadCSV(input) {
  const file = input.files[0];
  if (!file) return;

  const form = new FormData();
  form.append('file', file);

  try {
    const resp = await fetch('/api/upload', { method: 'POST', body: form });
    if (!resp.ok) {
      const text = await resp.text();
      showToast('Upload failed: ' + text, 'error');
      return;
    }
    const data = await resp.json();
    state.dataLoaded = true;
    updateDataStatus(data);
    showToast(`Loaded ${data.records.toLocaleString()} records`, 'success');
    document.getElementById('runBtn').disabled = false;
    document.getElementById('runAllBtn').disabled = false;
  } catch (e) {
    showToast('Upload error: ' + e.message, 'error');
  }
  input.value = '';
}

async function generateSample() {
  try {
    const resp = await fetch('/api/generate-sample', { method: 'POST' });
    const data = await resp.json();
    state.dataLoaded = true;
    updateDataStatus(data);
    showToast(data.message, 'success');
    document.getElementById('runBtn').disabled = false;
    document.getElementById('runAllBtn').disabled = false;
  } catch (e) {
    showToast('Error: ' + e.message, 'error');
  }
}

async function importInfluxData() {
  const start = document.getElementById('influxStart').value.trim();
  const bucket = document.getElementById('influxBucket').value.trim() || 'sigenergy';
  try {
    const resp = await fetch('/api/influx/import', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ start, bucket, every: '1h' }),
    });
    if (!resp.ok) {
      showToast('Influx import failed: ' + await resp.text(), 'error');
      return;
    }
    const data = await resp.json();
    state.dataLoaded = true;
    updateDataStatus(data);
    showToast(data.message || `Imported ${data.records.toLocaleString()} records`, 'success');
    document.getElementById('runBtn').disabled = false;
    document.getElementById('runAllBtn').disabled = false;
  } catch (e) {
    showToast('Influx import error: ' + e.message, 'error');
  }
}

async function checkDataStatus() {
  try {
    const resp = await fetch('/api/data/status');
    const data = await resp.json();
    if (data.loaded) {
      state.dataLoaded = true;
      updateDataStatus(data);
      document.getElementById('runBtn').disabled = false;
      document.getElementById('runAllBtn').disabled = false;
    }
  } catch (e) { /* ignore */ }
}

function updateDataStatus(data) {
  const el = document.getElementById('dataStatus');
  const records = data.records || 0;
  const days = data.days || Math.round(records / 96);
  el.innerHTML = `<span class="dot active"></span><span>${records.toLocaleString()} records · ${days} days</span>`;
  const info = document.getElementById('dataInfo');
  info.style.display = 'block';
  document.getElementById('dataInfoText').textContent = `${records.toLocaleString()} records loaded (${days} days)`;
}

function downloadTemplate() {
  window.open('/api/sample-csv', '_blank');
}

// ============================================================
// TOU PLAN
// ============================================================
const planPresets = {
  current: {
    name: 'Current Plan',
    supply: 1.023, fit: 0.028,
    windows: [
      { start: 0, end: 6, rate: 0.08, label: 'EV Rate' },
      { start: 6, end: 11, rate: 0.4081, label: 'Off-Peak' },
      { start: 11, end: 14, rate: 0.00, label: 'Free' },
      { start: 14, end: 15, rate: 0.4081, label: 'Off-Peak' },
      { start: 15, end: 21, rate: 0.6127, label: 'Peak', months: [1,2,3,6,7,8,11,12] },
      { start: 15, end: 21, rate: 0.4081, label: 'Off-Peak', months: [4,5,9,10] },
      { start: 21, end: 24, rate: 0.4081, label: 'Off-Peak' },
    ]
  },
  evday: {
    name: 'PS EV Day',
    supply: 1.2284, fit: 0.005,
    windows: [
      { start: 0, end: 12, rate: 0.2376, label: 'Off-Peak' },
      { start: 12, end: 14, rate: 0.00, label: 'Free' },
      { start: 14, end: 15, rate: 0.2376, label: 'Off-Peak' },
      { start: 15, end: 21, rate: 0.4620, label: 'Peak' },
      { start: 21, end: 24, rate: 0.2376, label: 'Off-Peak' },
    ]
  },
  evnight: {
    name: 'PS EV Night',
    supply: 1.2284, fit: 0.005,
    windows: [
      { start: 0, end: 6, rate: 0.06, label: 'Shoulder' },
      { start: 6, end: 15, rate: 0.3212, label: 'Off-Peak' },
      { start: 15, end: 21, rate: 0.5805, label: 'Peak' },
      { start: 21, end: 24, rate: 0.3212, label: 'Off-Peak' },
    ]
  },
  flat: {
    name: 'Flat Rate',
    supply: 1.10, fit: 0.05,
    windows: [
      { start: 0, end: 24, rate: 0.30, label: 'Flat' },
    ]
  },
};

function loadPlanPreset(key) {
  const p = planPresets[key];
  if (!p) return;
  state.activePlanMeta = { name: p.name };
  document.getElementById('supplyCharge').value = p.supply;
  document.getElementById('feedInTariff').value = p.fit;
  state.touWindows = p.windows.map(w => ({ ...w }));
  const meta = document.getElementById('emePlanMeta');
  if (meta) meta.textContent = '';
  renderTOUTable();
  renderTOUVisual();
}

async function importEMEPlan() {
  const id = document.getElementById('emePlanId').value.trim();
  const postcode = document.getElementById('emePostcode').value.trim() || '2213';
  if (!id) {
    showToast('Enter an Energy Made Easy plan ID first', 'error');
    return;
  }
  try {
    const resp = await fetch(`/api/eme/plan?id=${encodeURIComponent(id)}&postcode=${encodeURIComponent(postcode)}`);
    if (!resp.ok) {
      showToast('Plan import failed: ' + await resp.text(), 'error');
      return;
    }
    const data = await resp.json();
    const plan = data.plan;
    state.activePlanMeta = {
      name: plan.name || id,
      plan_id: plan.plan_id || id,
      retailer: plan.retailer || '',
      unsupported: plan.unsupported || [],
    };
    document.getElementById('supplyCharge').value = plan.supply_charge ?? 0;
    document.getElementById('feedInTariff').value = plan.feed_in_tariff ?? 0;
    state.touWindows = (plan.windows || []).map(apiWindowToUI);
    renderTOUTable();
    renderTOUVisual();
    const warnings = state.activePlanMeta.unsupported.length ? ` · Warnings: ${state.activePlanMeta.unsupported.join('; ')}` : '';
    document.getElementById('emePlanMeta').textContent = `${plan.retailer || 'Retailer'} — ${plan.name || id}${warnings}`;
    showToast('Imported Energy Made Easy plan', 'success');
  } catch (e) {
    showToast('Plan import error: ' + e.message, 'error');
  }
}

function apiWindowToUI(w) {
  const start = Number.isFinite(w.start_hour) ? w.start_hour : Math.floor((w.start_minute || 0) / 60);
  const end = Number.isFinite(w.end_hour) && w.end_hour > 0 ? w.end_hour : Math.ceil((w.end_minute || 1440) / 60);
  return {
    start,
    end,
    start_minute: w.start_minute || start * 60,
    end_minute: w.end_minute || end * 60,
    rate: w.rate,
    label: w.label || 'Usage',
    months: w.months || [],
    days: w.days || [],
  };
}

function renderTOUTable() {
  const tbody = document.getElementById('touBody');
  tbody.innerHTML = state.touWindows.map((w, i) => `
    <tr>
      <td><input type="number" value="${w.start}" min="0" max="23" style="width:44px"
           onchange="updateTOU(${i},'start',this.value)"></td>
      <td><input type="number" value="${w.end}" min="1" max="24" style="width:44px"
           onchange="updateTOU(${i},'end',this.value)"></td>
      <td class="rate-cell"><input type="number" value="${w.rate}" step="0.001" min="0" style="width:64px"
           onchange="updateTOU(${i},'rate',this.value)"></td>
      <td><input type="text" value="${escapeAttr(w.label || '')}" style="width:78px"
           onchange="updateTOU(${i},'label',this.value)"></td>
      <td><input type="text" value="${formatList(w.months)}" placeholder="All" style="width:72px"
           onchange="updateTOU(${i},'months',this.value)"></td>
      <td><input type="text" value="${formatList(w.days, '|')}" placeholder="All" style="width:86px"
           onchange="updateTOU(${i},'days',this.value)"></td>
      <td><button class="delete-btn" onclick="removeTOU(${i})">×</button></td>
    </tr>
  `).join('');
}

function formatList(value, sep = ',') {
  if (!value || !value.length) return '';
  return value.join(sep);
}

function parseMonths(value) {
  const clean = value.trim();
  if (!clean || /^all$/i.test(clean)) return [];
  return clean.split(/[|,\s]+/).map(v => parseInt(v, 10)).filter(v => v >= 1 && v <= 12);
}

function parseDays(value) {
  const clean = value.trim();
  if (!clean || /^all$/i.test(clean)) return [];
  return clean.split(/[|,\s]+/).map(v => v.trim().toUpperCase()).filter(Boolean);
}

function escapeAttr(value) {
  return String(value).replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');
}

function renderTOUVisual() {
  const container = document.getElementById('touVisual');
  const displayMonth = new Date().getMonth() + 1;
  const displayDay = ['SUN','MON','TUE','WED','THU','FRI','SAT'][new Date().getDay()];
  const colors = {
    'Free': '#22c55e', 'Peak': '#ef4444', 'Off-Peak': '#3b82f6',
    'EV Rate': '#8b5cf6', 'Shoulder': '#a78bfa', 'Flat': '#6b7280',
  };

  const visible = state.touWindows.filter(w =>
    (!w.months || !w.months.length || w.months.includes(displayMonth)) &&
    (!w.days || !w.days.length || w.days.includes(displayDay))
  );
  container.innerHTML = visible.map(w => {
    const width = ((w.end - w.start) / 24) * 100;
    const bg = colors[w.label] || '#6b7280';
    const rateText = w.rate === 0 ? 'FREE' : `${(w.rate * 100).toFixed(1)}c`;
    return `<div class="tou-visual-block" style="width:${width}%;background:${bg}"
                 title="${w.label}: ${w.start}:00-${w.end}:00 @ ${rateText}">
              ${width > 8 ? rateText : ''}
            </div>`;
  }).join('');
}

function updateTOU(idx, field, value) {
  if (field === 'rate') state.touWindows[idx].rate = parseFloat(value);
  else if (field === 'start') {
    state.touWindows[idx].start = parseInt(value);
    state.touWindows[idx].start_minute = state.touWindows[idx].start * 60;
  }
  else if (field === 'end') {
    state.touWindows[idx].end = parseInt(value);
    state.touWindows[idx].end_minute = state.touWindows[idx].end * 60;
  }
  else if (field === 'months') state.touWindows[idx].months = parseMonths(value);
  else if (field === 'days') state.touWindows[idx].days = parseDays(value);
  else state.touWindows[idx].label = value;
  renderTOUVisual();
}

function addTOUWindow() {
  state.touWindows.push({ start: 0, end: 24, rate: 0.30, label: 'Custom', months: [], days: [] });
  renderTOUTable();
  renderTOUVisual();
}

function removeTOU(idx) {
  state.touWindows.splice(idx, 1);
  renderTOUTable();
  renderTOUVisual();
}

// ============================================================
// STRATEGY TIMELINE
// ============================================================
function initTimeline() {
  const grid = document.getElementById('timelineGrid');
  const labels = document.getElementById('timelineLabels');

  for (let h = 0; h < 24; h++) {
    const cell = document.createElement('div');
    cell.className = 'timeline-hour idle';
    cell.dataset.hour = h;
    cell.textContent = h.toString().padStart(2, '0');
    cell.onclick = () => cycleHour(h);
    grid.appendChild(cell);

    const lbl = document.createElement('span');
    lbl.textContent = h.toString().padStart(2, '0');
    labels.appendChild(lbl);
  }
}

function cycleHour(h) {
  const cycle = { idle: 'charge', charge: 'discharge', discharge: 'idle' };
  state.timeline[h] = cycle[state.timeline[h]];
  updateTimelineUI();
}

function updateTimelineUI() {
  const cells = document.querySelectorAll('.timeline-hour');
  cells.forEach((cell, i) => {
    cell.className = `timeline-hour ${state.timeline[i]}`;
    const labels = { charge: 'CHG', discharge: 'DIS', idle: '' };
    cell.textContent = labels[state.timeline[i]] || i.toString().padStart(2, '0');
  });
}

function updateSOCLabel(inputId, labelId) {
  document.getElementById(labelId).textContent = document.getElementById(inputId).value + '%';
}

// Strategy presets
const strategyPresets = {
  current_optimal: {
    name: 'Current Plan Optimal',
    timeline: [
      'charge','charge','charge','charge','charge','charge',
      'discharge','discharge','discharge','discharge','discharge',
      'charge','charge','charge',
      'discharge','discharge','discharge','discharge','discharge','discharge',
      'discharge','discharge','discharge','discharge'
    ],
    socTarget: 100, socFloor: 0,
    solar: true,
    thresholds: [],
  },
  peak_shave: {
    name: 'Peak Shave Only',
    timeline: [
      'idle','idle','idle','idle','idle','idle',
      'idle','idle','idle','idle','idle',
      'idle','idle','idle','idle',
      'discharge','discharge','discharge','discharge','discharge','discharge',
      'idle','idle','idle'
    ],
    socTarget: 100, socFloor: 10,
    solar: true,
    thresholds: [],
  },
  full_arb: {
    name: 'Full Arbitrage',
    timeline: new Array(24).fill('idle'),
    socTarget: 100, socFloor: 0,
    solar: true,
    thresholds: [
      { action: 'charge', threshold: 0.10 },
      { action: 'discharge', threshold: 0.30 },
    ],
  },
};

function loadStrategyPreset(key) {
  const p = strategyPresets[key];
  if (!p) return;
  state.timeline = [...p.timeline];
  state.thresholdRules = p.thresholds.map(t => ({ ...t }));
  document.getElementById('socTarget').value = p.socTarget;
  document.getElementById('socFloor').value = p.socFloor;
  document.getElementById('socTargetVal').textContent = p.socTarget + '%';
  document.getElementById('socFloorVal').textContent = p.socFloor + '%';
  const toggle = document.getElementById('solarToggle');
  toggle.classList.toggle('active', p.solar);
  updateTimelineUI();
  renderThresholdRules();
}

function toggleSolar() {
  document.getElementById('solarToggle').classList.toggle('active');
}

// Threshold rules
function addThresholdRule() {
  state.thresholdRules.push({ action: 'charge', threshold: 0.10 });
  renderThresholdRules();
}

function renderThresholdRules() {
  const container = document.getElementById('thresholdRules');
  container.innerHTML = state.thresholdRules.map((r, i) => `
    <div class="rule-row">
      <select onchange="state.thresholdRules[${i}].action=this.value">
        <option value="charge" ${r.action === 'charge' ? 'selected' : ''}>Charge</option>
        <option value="discharge" ${r.action === 'discharge' ? 'selected' : ''}>Discharge</option>
      </select>
      <span class="rule-label">when price ${r.action === 'charge' ? '≤' : '≥'}</span>
      <input type="number" value="${r.threshold}" step="0.01" min="0" style="width:70px"
             onchange="state.thresholdRules[${i}].threshold=parseFloat(this.value)">
      <span class="rule-label">$/kWh</span>
      <button class="delete-btn" onclick="removeThreshold(${i})">×</button>
    </div>
  `).join('');
}

function removeThreshold(idx) {
  state.thresholdRules.splice(idx, 1);
  renderThresholdRules();
}

// ============================================================
// SCENARIOS
// ============================================================
function addScenario() {
  state.scenarioCounter++;
  const id = 'scenario_' + Date.now();
  state.scenarios.push({ id, name: `Scenario ${state.scenarioCounter}`, result: null });
  renderScenarioTabs();
  switchScenario(id);
}

function switchScenario(id) {
  state.activeScenario = id;
  renderScenarioTabs();
}

function removeScenario(id) {
  if (state.scenarios.length <= 1) return;
  state.scenarios = state.scenarios.filter(s => s.id !== id);
  if (state.activeScenario === id) {
    state.activeScenario = state.scenarios[0].id;
  }
  renderScenarioTabs();
}

function renderScenarioTabs() {
  const bar = document.getElementById('scenariosBar');
  const tabs = state.scenarios.map(s => {
    const active = s.id === state.activeScenario ? 'active' : '';
    const hasResult = s.result ? ' ✓' : '';
    const removeBtn = state.scenarios.length > 1
      ? `<span class="remove" onclick="event.stopPropagation();removeScenario('${s.id}')">×</span>` : '';
    return `<button class="scenario-tab ${active}" onclick="switchScenario('${s.id}')"
                data-id="${s.id}">${s.name}${hasResult}${removeBtn}</button>`;
  }).join('');

  bar.innerHTML = tabs + `
    <button class="btn btn-secondary btn-sm btn-icon" onclick="addScenario()" title="Add scenario">＋</button>
    <div style="flex:1"></div>
    <button class="btn btn-primary btn-sm" onclick="runSimulation()" id="runBtn" ${state.dataLoaded ? '' : 'disabled'}>▶ Run</button>
    <button class="btn btn-success btn-sm" onclick="runAllScenarios()" id="runAllBtn" ${state.dataLoaded ? '' : 'disabled'}>▶▶ Compare All</button>
  `;
}

// ============================================================
// BUILD SCENARIO FROM UI
// ============================================================
function buildScenario() {
  // Battery
  const battery = {
    capacity_kwh: parseFloat(document.getElementById('battCapacity').value),
    usable_percent: parseFloat(document.getElementById('battUsable').value),
    round_trip_eff: parseFloat(document.getElementById('battEff').value),
    max_charge_kw: parseFloat(document.getElementById('battCharge').value),
    max_discharge_kw: parseFloat(document.getElementById('battDischarge').value),
    cost_dollars: parseFloat(document.getElementById('battCost').value),
  };

  // Plan
  const plan = {
    name: state.activePlanMeta?.name || 'Custom',
    plan_id: state.activePlanMeta?.plan_id || '',
    retailer: state.activePlanMeta?.retailer || '',
    unsupported: state.activePlanMeta?.unsupported || [],
    windows: state.touWindows.map(w => ({
      start_hour: w.start,
      end_hour: w.end,
      start_minute: w.start_minute || w.start * 60,
      end_minute: w.end_minute || w.end * 60,
      rate: w.rate,
      label: w.label,
      months: w.months || [],
      days: w.days || [],
    })),
    supply_charge: parseFloat(document.getElementById('supplyCharge').value),
    feed_in_tariff: parseFloat(document.getElementById('feedInTariff').value),
  };

  // Strategy
  const socTarget = parseFloat(document.getElementById('socTarget').value);
  const socFloor = parseFloat(document.getElementById('socFloor').value);
  const captureSolar = document.getElementById('solarToggle').classList.contains('active');

  const rules = [];

  // Convert timeline to time rules (merge consecutive same-action hours)
  let i = 0;
  while (i < 24) {
    const action = state.timeline[i];
    if (action === 'idle') { i++; continue; }
    let j = i + 1;
    while (j < 24 && state.timeline[j] === action) j++;
    rules.push({
      type: 'time',
      action: action,
      start_hour: i,
      end_hour: j,
      soc_target: action === 'charge' ? socTarget : 0,
      soc_floor: action === 'discharge' ? socFloor : 0,
      threshold: 0,
    });
    i = j;
  }

  // Add threshold rules
  for (const tr of state.thresholdRules) {
    rules.push({
      type: 'threshold',
      action: tr.action,
      start_hour: 0, end_hour: 0,
      soc_target: tr.action === 'charge' ? socTarget : 0,
      soc_floor: tr.action === 'discharge' ? socFloor : 0,
      threshold: tr.threshold,
    });
  }

  return {
    scenario: {
      name: state.scenarios.find(s => s.id === state.activeScenario)?.name || 'Scenario',
      plan, battery,
      strategy: {
        name: 'Custom',
        rules,
        always_capture_solar: captureSolar,
      },
    },
  };
}

function planPresetToAPI(p) {
  return {
    name: p.name,
    windows: p.windows.map(w => ({
      start_hour: w.start,
      end_hour: w.end,
      start_minute: (w.start_minute ?? w.start * 60),
      end_minute: (w.end_minute ?? w.end * 60),
      rate: w.rate,
      label: w.label,
      months: w.months || [],
      days: w.days || [],
    })),
    supply_charge: p.supply,
    feed_in_tariff: p.fit,
  };
}

async function compareCandidatePlan() {
  if (!state.dataLoaded) {
    showToast('Load usage data before comparing plans', 'error');
    return;
  }
  const candidate = buildScenario().scenario.plan;
  const current = planPresetToAPI(planPresets.current);
  const manualPayback = parseFloat(document.getElementById('paybackYears').value);
  const simPayback = state.lastSimulationResult && state.lastSimulationResult.payback_years < 99
    ? state.lastSimulationResult.payback_years : 0;
  const payback = Number.isFinite(manualPayback) && manualPayback > 0 ? manualPayback : simPayback;
  const batteryCost = parseFloat(document.getElementById('compareBatteryCost').value) || parseFloat(document.getElementById('battCost').value) || 12000;

  try {
    const resp = await fetch('/api/compare-plan', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ current_plan: current, candidate_plan: candidate, battery_cost: batteryCost, payback_years: payback }),
    });
    if (!resp.ok) {
      showToast('Comparison failed: ' + await resp.text(), 'error');
      return;
    }
    const result = await resp.json();
    renderPlanComparison(result);
    showToast('Plan comparison complete', 'success');
  } catch (e) {
    showToast('Comparison error: ' + e.message, 'error');
  }
}

function renderPlanComparison(c) {
  document.getElementById('emptyState').style.display = 'none';
  const area = document.getElementById('planComparisonArea');
  area.style.display = 'block';
  const deltaClass = c.annual_delta < 0 ? 'positive' : (c.annual_delta > 0 ? 'negative' : 'accent');
  const horizonClass = c.horizon_delta < 0 ? 'positive' : (c.horizon_delta > 0 ? 'negative' : 'accent');
  document.getElementById('planComparisonMetrics').innerHTML = [
    { label: 'Current Annual', value: money(c.current.annual_cost), cls: '' },
    { label: 'Candidate Annual', value: money(c.candidate.annual_cost), cls: 'accent' },
    { label: 'Annual Difference', value: signedMoney(c.annual_delta), cls: deltaClass },
    { label: `${c.horizon_years}y Difference`, value: signedMoney(c.horizon_delta), cls: horizonClass },
    { label: 'Battery Payback', value: c.battery_payback_years ? `${c.battery_payback_years}y` : `${c.horizon_years}y`, cls: '' },
    { label: 'Verdict', value: c.verdict.toUpperCase(), cls: deltaClass },
  ].map(m => `
    <div class="metric-card">
      <div class="metric-label">${m.label}</div>
      <div class="metric-value ${m.cls}">${m.value}</div>
    </div>
  `).join('');
  document.getElementById('planComparisonAnalysis').innerHTML = (c.analysis || [])
    .map(line => `<div class="analysis-item">${escapeHTML(line)}</div>`).join('');
}

function money(v) {
  return `$${Math.round(v).toLocaleString()}`;
}

function signedMoney(v) {
  const sign = v > 0 ? '+' : (v < 0 ? '−' : '');
  return `${sign}$${Math.round(Math.abs(v)).toLocaleString()}`;
}

function escapeHTML(value) {
  return String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

// ============================================================
// SIMULATION
// ============================================================
async function runSimulation() {
  const req = buildScenario();
  const btn = document.getElementById('runBtn');
  btn.disabled = true;
  btn.textContent = '⏳ Running...';

  try {
    const resp = await fetch('/api/simulate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req),
    });

    if (!resp.ok) {
      const text = await resp.text();
      showToast('Simulation failed: ' + text, 'error');
      return;
    }

    const result = await resp.json();
    state.lastSimulationResult = result;
    if (result.payback_years && result.payback_years < 99) {
      document.getElementById('paybackYears').placeholder = result.payback_years.toFixed(1);
    }
    const sc = state.scenarios.find(s => s.id === state.activeScenario);
    if (sc) sc.result = result;

    renderResults(result);
    renderScenarioTabs();
    showToast('Simulation complete', 'success');
  } catch (e) {
    showToast('Error: ' + e.message, 'error');
  } finally {
    btn.disabled = false;
    btn.textContent = '▶ Run';
  }
}

async function runAllScenarios() {
  // Run current scenario config for the active one
  await runSimulation();
  updateComparison();
}

function updateComparison() {
  const withResults = state.scenarios.filter(s => s.result);
  if (withResults.length < 1) return;

  const section = document.getElementById('comparisonSection');
  section.style.display = 'block';

  const tbody = document.getElementById('comparisonBody');
  const bestSave = Math.max(...withResults.map(s => s.result.annual_savings));

  tbody.innerHTML = withResults.map(s => {
    const r = s.result;
    const isBest = r.annual_savings === bestSave && withResults.length > 1;
    return `<tr>
      <td>${s.name}</td>
      <td>$${r.baseline_annual.toLocaleString(undefined, { minimumFractionDigits: 0 })}</td>
      <td>$${r.optimized_annual.toLocaleString(undefined, { minimumFractionDigits: 0 })}</td>
      <td class="${isBest ? 'best' : ''}">$${r.annual_savings.toLocaleString(undefined, { minimumFractionDigits: 0 })}</td>
      <td>${r.payback_years < 99 ? r.payback_years.toFixed(1) + 'y' : '—'}</td>
      <td>${r.annual_cycles}</td>
    </tr>`;
  }).join('');
}

// ============================================================
// RENDER RESULTS
// ============================================================
function renderResults(result) {
  document.getElementById('emptyState').style.display = 'none';
  document.getElementById('resultsArea').style.display = 'block';

  renderMetrics(result);
  renderSOCChart(result);
  renderCostChart(result);
  renderFlowChart(result);
  renderMonthlyChart(result);
  updateComparison();
}

function renderMetrics(r) {
  const grid = document.getElementById('metricsGrid');
  const metrics = [
    { label: 'Baseline Annual', value: `$${Math.round(r.baseline_annual).toLocaleString()}`, cls: '' },
    { label: 'With Battery', value: `$${Math.round(r.optimized_annual).toLocaleString()}`, cls: 'accent' },
    { label: 'Annual Savings', value: `$${Math.round(r.annual_savings).toLocaleString()}`, cls: 'positive', sub: `${((r.annual_savings / r.baseline_annual) * 100).toFixed(0)}% reduction` },
    { label: 'Payback', value: r.payback_years < 99 ? `${r.payback_years}y` : '—', cls: r.payback_years < 5 ? 'positive' : (r.payback_years < 8 ? 'accent' : 'negative') },
    { label: 'Cycles / Year', value: r.annual_cycles.toString(), cls: '', sub: `${r.days_simulated} days simulated` },
    { label: 'Grid → Battery', value: `${r.total_grid_charge.toLocaleString()} kWh`, cls: '' },
    { label: 'Solar Captured', value: `${r.total_solar_capture.toLocaleString()} kWh`, cls: '' },
    { label: 'Discharged', value: `${r.total_discharge.toLocaleString()} kWh`, cls: '' },
  ];

  grid.innerHTML = metrics.map(m => `
    <div class="metric-card">
      <div class="metric-label">${m.label}</div>
      <div class="metric-value ${m.cls}">${m.value}</div>
      ${m.sub ? `<div class="metric-sub">${m.sub}</div>` : ''}
    </div>
  `).join('');
}

// ============================================================
// CHARTS
// ============================================================
const chartDefaults = {
  responsive: true,
  maintainAspectRatio: true,
  aspectRatio: 2,
  plugins: {
    legend: { labels: { color: '#94a3b8', font: { family: "'Space Grotesk'", size: 11 } } },
  },
  scales: {
    x: { ticks: { color: '#64748b', font: { family: "'JetBrains Mono'", size: 10 } }, grid: { color: '#1e2d4a' } },
    y: { ticks: { color: '#64748b', font: { family: "'JetBrains Mono'", size: 10 } }, grid: { color: '#1e2d4a' } },
  },
};

function destroyChart(id) {
  if (state.charts[id]) { state.charts[id].destroy(); delete state.charts[id]; }
}

function renderSOCChart(result) {
  destroyChart('soc');
  const ctx = document.getElementById('socChart').getContext('2d');
  const hp = result.hourly_profile;

  state.charts.soc = new Chart(ctx, {
    type: 'line',
    data: {
      labels: hp.map(h => h.hour.toString().padStart(2, '0') + ':00'),
      datasets: [{
        label: 'Avg SOC (kWh)',
        data: hp.map(h => h.avg_soc.toFixed(1)),
        borderColor: '#38bdf8',
        backgroundColor: 'rgba(56,189,248,0.1)',
        fill: true,
        tension: 0.4,
        pointRadius: 3,
        pointBackgroundColor: '#38bdf8',
      }],
    },
    options: {
      ...chartDefaults,
      scales: {
        ...chartDefaults.scales,
        y: { ...chartDefaults.scales.y, min: 0, title: { display: true, text: 'kWh', color: '#64748b' } },
      },
    },
  });
}

function renderCostChart(result) {
  destroyChart('cost');
  const ctx = document.getElementById('costChart').getContext('2d');
  const hp = result.hourly_profile;

  // Build baseline cost for comparison (price × grid import without battery)
  state.charts.cost = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: hp.map(h => h.hour.toString().padStart(2, '0')),
      datasets: [
        {
          label: 'With Battery',
          data: hp.map(h => h.cost.toFixed(0)),
          backgroundColor: '#38bdf8',
          borderRadius: 3,
        },
      ],
    },
    options: {
      ...chartDefaults,
      scales: {
        ...chartDefaults.scales,
        y: { ...chartDefaults.scales.y, title: { display: true, text: '$/year', color: '#64748b' } },
      },
    },
  });
}

function renderFlowChart(result) {
  destroyChart('flow');
  const ctx = document.getElementById('flowChart').getContext('2d');
  const hp = result.hourly_profile;

  state.charts.flow = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: hp.map(h => h.hour.toString().padStart(2, '0')),
      datasets: [
        { label: 'Grid Charge', data: hp.map(h => h.grid_charge.toFixed(0)), backgroundColor: '#22c55e', stack: 'charge' },
        { label: 'Solar Capture', data: hp.map(h => h.solar_capture.toFixed(0)), backgroundColor: '#facc15', stack: 'charge' },
        { label: 'Discharge', data: hp.map(h => -h.discharge.toFixed(0)), backgroundColor: '#f97316', stack: 'discharge' },
        { label: 'Grid Import', data: hp.map(h => h.grid_import.toFixed(0)), backgroundColor: '#3b82f6', stack: 'import' },
      ],
    },
    options: {
      ...chartDefaults,
      plugins: { ...chartDefaults.plugins, tooltip: { mode: 'index', intersect: false } },
      scales: {
        ...chartDefaults.scales,
        x: { ...chartDefaults.scales.x, stacked: true },
        y: { ...chartDefaults.scales.y, stacked: true, title: { display: true, text: 'kWh/year', color: '#64748b' } },
      },
    },
  });
}

function renderMonthlyChart(result) {
  destroyChart('monthly');
  const ctx = document.getElementById('monthlyChart').getContext('2d');
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  state.charts.monthly = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: months,
      datasets: [
        {
          label: 'Baseline',
          data: result.monthly_baseline.map(v => v.toFixed(0)),
          backgroundColor: 'rgba(239,68,68,0.3)',
          borderColor: '#ef4444',
          borderWidth: 1,
          borderRadius: 3,
        },
        {
          label: 'With Battery',
          data: result.monthly_costs.map(v => v.toFixed(0)),
          backgroundColor: 'rgba(56,189,248,0.3)',
          borderColor: '#38bdf8',
          borderWidth: 1,
          borderRadius: 3,
        },
      ],
    },
    options: {
      ...chartDefaults,
      scales: {
        ...chartDefaults.scales,
        y: { ...chartDefaults.scales.y, title: { display: true, text: '$/month', color: '#64748b' } },
      },
    },
  });
}

// ============================================================
// PANELS
// ============================================================
function togglePanel(id) {
  document.getElementById(id).classList.toggle('collapsed');
}

// ============================================================
// TOAST NOTIFICATIONS
// ============================================================
function showToast(message, type = 'info') {
  const existing = document.querySelector('.toast');
  if (existing) existing.remove();

  const toast = document.createElement('div');
  toast.className = `toast ${type}`;
  toast.textContent = message;
  document.body.appendChild(toast);
  setTimeout(() => toast.remove(), 4000);
}
