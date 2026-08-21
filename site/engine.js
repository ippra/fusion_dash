/* engine.js — the Fusion Energy Survey dashboard, client side.
 *
 * Renders the site 03_build_dashboard.R assembles: 02_create_question_data.R's
 * question files plus a config.json of presentation content. Nothing here
 * computes a statistic — every percentage and confidence interval was
 * computed upstream by srvyr, so this file only ever picks a slice and draws
 * it. That is what lets the site run with no server, and what makes the claim
 * that the site cannot disagree with 02 inspectable rather than asserted.
 *
 * Components (registered on the `components` object): explore (the survey
 * question explorer) and static_page. Each receives (pageConfig, container)
 * and renders itself from the files it references.
 *
 * Forked 2026-08-21 from wxdash's 11_dashboard/site/engine.js, which serves
 * the Extreme Weather and Society dashboard and continues to be maintained
 * there. This copy has diverged deliberately: the map explorer, landing page
 * and quiz components are gone along with Leaflet and the map half of the PDF
 * export, since this dashboard is one page. The class prefix is `fu-` where
 * the original uses `wx-`; the two files are otherwise close enough that a fix
 * to the table, chart or PDF code in either is worth carrying to the other.
 */

"use strict";

window.FU_ENGINE_LOADED = true; // watchdog diagnostics: proves this file executed

const BUNDLE = (() => {
  // Kept from the fork: a page served from a subdirectory can set
  // window.FU_BUNDLE so relative fetches still resolve to the bundle root.
  const p = window.FU_BUNDLE ||
    new URLSearchParams(location.search).get("bundle") || "./";
  return p.endsWith("/") ? p : p + "/";
})();

let CONFIG = null;
const jsonCache = new Map();

async function fetchJSON(rel) {
  if (jsonCache.has(rel)) return jsonCache.get(rel);
  // Build stamp (set by the bundle's index.html) busts long-lived caches —
  // the c.itation.net Rails static handler serves a 1-year max-age.
  const bust = window.FU_BUILD
    ? (rel.includes("?") ? "&" : "?") + "v=" + window.FU_BUILD : "";
  const res = await fetch(BUNDLE + rel + bust);
  if (!res.ok) throw new Error(`Failed to load ${rel}: ${res.status}`);
  const data = await res.json();
  jsonCache.set(rel, data);
  return data;
}

/* ---------------------------------------------------------------- utils -- */

const esc = (s) => String(s ?? "")
  .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  .replace(/"/g, "&quot;").replace(/'/g, "&#39;");

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else if (k === "html") node.innerHTML = v;
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  for (const c of children) {
    if (c == null) continue;
    node.append(c instanceof Node ? c : document.createTextNode(c));
  }
  return node;
}

// Display token for missing groups/categories — mirrors R's rendering of NA.
const naLabel = (v) => (v == null ? "NA" : v);

// Optional deep-link: ?grouping=Gender preselects the demographic grouping.
const urlGrouping = () => {
  const g = new URLSearchParams(location.search).get("grouping");
  return g && CONFIG.groupings.some(x => x.id === g) ? g : null;
};

// "Snow\nIce" → ["Snow", "Ice"] for multi-line Chart.js tick labels.
const tickLines = (label) => String(label).split("\n");

/* ---- viridis (matches ggplot2 scale_fill_viridis discrete sampling) ------ */
// 32 anchor stops of the viridis colormap; discrete palette of n colors =
// n evenly spaced samples over [0,1] with linear interpolation, like
// viridisLite::viridis(n).
const VIRIDIS_STOPS = [
  [68,1,84],[71,13,96],[72,24,106],[72,35,116],[71,45,123],[69,55,129],
  [66,64,134],[62,73,137],[58,82,139],[54,90,140],[50,98,142],[47,106,142],
  [43,113,142],[40,121,142],[37,128,142],[34,136,142],[31,143,141],[29,151,140],
  [27,158,138],[27,166,135],[30,173,131],[37,180,126],[47,187,119],[61,194,111],
  [77,200,101],[95,206,90],[114,212,77],[135,217,63],[157,221,48],[180,224,33],
  [203,226,25],[253,231,37]
];
function viridis(n) {
  if (n === 1) return ["rgb(68,1,84)"];
  const out = [];
  for (let i = 0; i < n; i++) {
    const t = i / (n - 1) * (VIRIDIS_STOPS.length - 1);
    const lo = Math.floor(t), hi = Math.min(lo + 1, VIRIDIS_STOPS.length - 1);
    const f = t - lo;
    const c = [0, 1, 2].map(k => Math.round(VIRIDIS_STOPS[lo][k] * (1 - f) + VIRIDIS_STOPS[hi][k] * f));
    out.push(`rgb(${c[0]},${c[1]},${c[2]})`);
  }
  return out;
}

// cividis (viridisLite option "cividis") — an alternative sequential ramp.
const CIVIDIS_STOPS = [
  [0,32,76],[0,36,86],[0,40,97],[0,44,108],[0,48,115],[9,53,116],[26,57,117],
  [37,62,117],[46,66,117],[54,71,118],[61,75,118],[68,80,119],[74,84,120],
  [80,89,121],[86,93,122],[92,98,123],[97,102,125],[103,107,126],[108,112,128],
  [113,116,129],[119,121,131],[124,126,133],[129,130,135],[135,135,136],
  [140,140,137],[146,144,137],[152,149,136],[158,154,135],[164,159,134],
  [171,164,132],[177,169,130],[184,174,127],[191,179,124],[198,184,120],
  [205,190,116],[212,195,111],[220,200,105],[227,206,98],[235,211,90],
  [243,217,80],[252,222,68],[255,230,66]
];

// ColorBrewer Greys — greyscale theme's map ramp (see dataStops).
const GREYS_STOPS = [
  [247,247,247],[217,217,217],[189,189,189],[150,150,150],
  [115,115,115],[82,82,82],[37,37,37]
];

// Drought-engine idea, scoped: in the greyscale accessibility theme the maps
// repaint in greys (one-motion theme switch); every other theme keeps the
// viridis/cividis data palettes (parity look + colorblind-safe). Charts are
// untouched — this applies to choropleths/scatter ramps only.
function dataStops(stops) {
  return document.documentElement.dataset.theme === "greyscale" ? GREYS_STOPS : stops;
}

// Continuous colour ramp over stop array; t clamped to [0,1]. Used by the
// choropleth components (clamping is a deliberate deviation from R
// colorNumeric, which paints out-of-domain values grey — see deviations).
function rampColor(stops, t) {
  t = Math.max(0, Math.min(1, t));
  const x = t * (stops.length - 1);
  const lo = Math.floor(x), hi = Math.min(lo + 1, stops.length - 1), f = x - lo;
  const c = [0, 1, 2].map(k => Math.round(stops[lo][k] * (1 - f) + stops[hi][k] * f));
  return `rgb(${c[0]},${c[1]},${c[2]})`;
}

/* ---- user-facing data-color schemes (Joe's demo, Aug 2026) --------------
 * The two explorer tabs open in blue and offer viridis and print-safe grey
 * as viewer choices; every other surface keeps the approved viridis look,
 * which is why the default lives here rather than in the scheme list order.
 * The greyscale accessibility theme still overrides ramps via dataStops(). */
const BLUES_STOPS = [
  [239,243,255],[198,219,239],[158,202,225],[107,174,214],
  [66,146,198],[33,113,181],[8,69,148]
];
const COLOR_SCHEMES = [
  { id: "viridis", label: "Viridis (multiple hues)", stops: VIRIDIS_STOPS },
  { id: "blue", label: "Blue (one hue)", stops: BLUES_STOPS },
  { id: "grey", label: "Grey (print safe)", stops: GREYS_STOPS }
];
const DEFAULT_SCHEME = "blue";
const urlScheme = () => {
  const s = getParam("scheme");
  return COLOR_SCHEMES.some(x => x.id === s) ? s : DEFAULT_SCHEME;
};
const schemeStops = (id) =>
  (COLOR_SCHEMES.find(x => x.id === id)
   || COLOR_SCHEMES.find(x => x.id === DEFAULT_SCHEME)).stops;
// Discrete series colors. Viridis keeps its ggplot sampling; the sequential
// ramps sample dark→light so a single series is always the dark end.
function schemeSeriesColors(id, n) {
  if (id === "viridis") return viridis(n);
  const stops = schemeStops(id);
  const out = [];
  for (let i = 0; i < n; i++) out.push(rampColor(stops, n === 1 ? 1 : 1 - (i / (n - 1)) * 0.8));
  return out;
}
function schemeSelect(current, onChange) {
  const wrap = el("div");
  wrap.append(el("label", { class: "field-label", for: "scheme-sel" }, "Change color scheme"));
  const sel = el("select", { class: "grouping", id: "scheme-sel", onchange: () => onChange(sel.value) });
  for (const sc of COLOR_SCHEMES) sel.append(el("option", { value: sc.id }, sc.label));
  sel.value = current;
  wrap.append(sel);
  return wrap;
}

/* ---- PDF export (Joe's demo affordance; jsPDF vendored per bundle) ------ */
// Composite the visible chart canvas onto the theme's panel background (the
// chart itself is transparent — dark themes would otherwise export
// light-on-white text).
function chartSnapshot(canvas) {
  const out = document.createElement("canvas");
  out.width = canvas.width; out.height = canvas.height;
  const ctx = out.getContext("2d");
  ctx.fillStyle = getComputedStyle(document.body).getPropertyValue("--panel").trim() || "#ffffff";
  ctx.fillRect(0, 0, out.width, out.height);
  ctx.drawImage(canvas, 0, 0);
  return out;
}
// Page prose as a flat block list the PDF flow can set: the lede becomes a
// heading, list items keep their bullet, everything else is a paragraph.
// Reading it off the rendered page rather than re-authoring it is what keeps
// a downloaded sheet saying the same thing as the screen it came from.
function htmlBlocks(html) {
  const root = document.createElement("div");
  root.innerHTML = String(html || "");
  const txt = (n) => (n.textContent || "").replace(/\s+/g, " ").trim();
  const out = [];
  (function walk(node) {
    for (const n of node.children) {
      const tag = n.tagName.toLowerCase();
      if (tag === "ul" || tag === "ol") {
        for (const li of n.children) { const t = txt(li); if (t) out.push({ type: "li", text: t }); }
      } else if (tag === "div" || tag === "section") {
        walk(n);
      } else if (tag === "hr") {
        continue;
      } else {
        const t = txt(n);
        if (!t) continue;
        const head = /^h[1-6]$/.test(tag) || n.classList.contains("fu-lede");
        out.push({ type: head ? "h" : "p", text: t });
      }
    }
  })(root);
  return out;
}

/* A standalone one-or-more page document: header, the plot, its legends, and
 * the page's own notes set in columns underneath, with a footer on every
 * page. The notes are the point — a map or a chart lifted out of the site
 * with no statement of what was asked, how it was scored or where it came
 * from is not something anyone can hand to a third party. */
function pdfDocument({ title, subtitle, canvas, legends, notesHTML, filename }) {
  if (!window.jspdf) { alert("The PDF library did not load — try reloading the page."); return; }
  const landscape = canvas.width >= canvas.height;
  const doc = new window.jspdf.jsPDF({
    orientation: landscape ? "l" : "p", unit: "pt", format: "letter" });
  const pw = doc.internal.pageSize.getWidth(), ph = doc.internal.pageSize.getHeight();
  const M = 44;
  const INK = [46, 42, 87], BODY = [35, 33, 48], GREY = [110, 115, 122],
        RULE = [214, 214, 224];
  const legendList = (legends == null ? [] : [].concat(legends)).filter(Boolean);
  const project = (CONFIG.project && CONFIG.project.nav_subtitle) || "Fusion Energy Survey";
  const stamp = new Date().toLocaleDateString(undefined,
    { year: "numeric", month: "long", day: "numeric" });

  const footer = () => {
    const y = ph - 26;
    doc.setDrawColor(...RULE); doc.setLineWidth(0.5);
    doc.line(M, y - 10, pw - M, y - 10);
    doc.setFont("helvetica", "normal"); doc.setFontSize(7.5); doc.setTextColor(...GREY);
    doc.text(project, M, y);
    doc.text(`Downloaded ${stamp}`, pw - M, y, { align: "right" });
  };

  // --- header
  doc.setFont("helvetica", "bold"); doc.setFontSize(14); doc.setTextColor(...INK);
  const titleLines = doc.splitTextToSize(String(title || ""), pw - 2 * M);
  doc.text(titleLines, M, M + 10);
  let y = M + 10 + titleLines.length * 17;
  if (subtitle) {
    doc.setFont("helvetica", "normal"); doc.setFontSize(9); doc.setTextColor(...GREY);
    const subLines = doc.splitTextToSize(String(subtitle), pw - 2 * M);
    doc.text(subLines, M, y);
    y += subLines.length * 11;
  }
  y += 6;
  doc.setDrawColor(...RULE); doc.setLineWidth(0.5);
  doc.line(M, y, pw - M, y);
  y += 16;

  // --- how much room the notes need, before the plot claims the page.
  // Measured with the same wrapping the flow will use, so the plot can be
  // sized to leave exactly enough and the document comes out one page.
  const blocks = htmlBlocks(notesHTML);
  const gap = 30;
  const contentW = pw - 2 * M;
  // Two columns only when there is enough prose to fill them — a short
  // caption set in two columns leaves one of them empty. A lone column runs
  // the full width of the page rather than a reading measure: the notes are
  // the foot of a one-page document, and a narrow block of text under a
  // full-width plot reads as an unfinished page.
  const long = blocks.reduce((n, b) => n + b.text.length, 0) > 700;
  const cols = long ? 2 : 1;
  const colW = long ? (contentW - gap) / 2 : contentW;
  const style = {
    h:  { size: 9.5, font: "bold",   color: INK,  before: 4, after: 4, lead: 12, indent: 0 },
    p:  { size: 8.5, font: "normal", color: BODY, before: 0, after: 7, lead: 11, indent: 0 },
    li: { size: 8.5, font: "normal", color: BODY, before: 0, after: 4, lead: 11, indent: 11 }
  };
  const measured = blocks.map(b => {
    const st = style[b.type];
    doc.setFont("helvetica", st.font); doc.setFontSize(st.size);
    const lines = doc.splitTextToSize(b.text, colW - st.indent);
    return { b, st, lines, height: st.before + lines.length * st.lead + st.after };
  });
  // Column breaks land on block boundaries, so the flow runs a little taller
  // than an even split of the total.
  const notesH = measured.length
    ? measured.reduce((n, m) => n + m.height, 0) / cols * 1.12 : 0;

  // --- plot, sized to what the page has left once the notes are allowed for
  const bottom = ph - 46;
  const maxW = contentW;
  const legendH = legendList.length ? 36 : 0;
  const room = bottom - y - legendH - notesH - 16;
  const maxH = Math.max(ph * 0.26, Math.min(ph * 0.52, room));
  const scale = Math.min(maxW / canvas.width, maxH / canvas.height);
  const w = canvas.width * scale, h = canvas.height * scale;
  const imgX = M + (maxW - w) / 2;
  doc.addImage(canvas.toDataURL("image/png"), "PNG", imgX, y, w, h);
  y += h + 16;

  // --- legends, each under the map it describes. Anchored to the image
  // rather than the page margin: the plot is centred and, when two maps are
  // composited, a second legend measured from the margin lands under the gap
  // between them instead of under its own map.
  legendList.forEach((lg, i) => {
    const slot = w / legendList.length;
    const lx = imgX + i * slot;
    const lw = Math.min(200, slot - 24), steps = 55;
    doc.setFont("helvetica", "normal"); doc.setFontSize(8); doc.setTextColor(...BODY);
    doc.text(String(lg.title || ""), lx, y);
    for (let k = 0; k < steps; k++) {
      const c = rampColor(lg.stops, k / (steps - 1)).match(/\d+/g).map(Number);
      doc.setFillColor(c[0], c[1], c[2]);
      doc.rect(lx + (lw / steps) * k, y + 4, lw / steps + 0.5, 9, "F");
    }
    // lg.fmt keeps 1-5 estimate ends readable ("1.5", not "2") while
    // alert-day counts stay whole numbers.
    const lf = lg.fmt || ((v) => String(Math.round(v)));
    doc.setFontSize(7.5); doc.setTextColor(...GREY);
    doc.text(lf(lg.domain[0]), lx, y + 22);
    doc.text(lf((lg.domain[0] + lg.domain[1]) / 2), lx + lw / 2, y + 22, { align: "center" });
    doc.text(lf(lg.domain[1]), lx + lw, y + 22, { align: "right" });
  });
  if (legendList.length) y += 36;

  // --- notes, flowed into the columns measured above
  if (measured.length) {
    let col = 0, top = y, cy = y;
    const colX = () => M + col * (colW + gap);
    const nextColumn = () => {
      if (col === 0 && cols === 2) { col = 1; cy = top; return; }
      footer(); doc.addPage(); col = 0; top = M; cy = M;
    };
    for (const { b, st, lines } of measured) {
      doc.setFont("helvetica", st.font); doc.setFontSize(st.size);
      // Never leave a heading stranded at the foot of a column.
      const need = st.before + lines.length * st.lead +
        (b.type === "h" ? style.p.lead : 0);
      if (cy + need > bottom && !(cy === top)) nextColumn();
      cy += st.before;
      doc.setTextColor(...st.color);
      for (const line of lines) {
        if (cy + st.lead > bottom) { nextColumn(); doc.setFont("helvetica", st.font); doc.setFontSize(st.size); doc.setTextColor(...st.color); }
        if (b.type === "li" && line === lines[0]) {
          doc.text("•", colX(), cy + st.lead - 3);
        }
        doc.text(line, colX() + st.indent, cy + st.lead - 3);
        cy += st.lead;
      }
      cy += st.after;
    }
  }
  footer();
  doc.save(filename || "fusion.pdf");
}

function pdfButton(label, onClick) {
  return el("button", { class: "fu-pdf-btn", onclick: onClick }, label);
}

// Charts owned by the current page; destroyed
// on navigation alongside the legacy single activeChart.
let pageCharts = [];
function trackChart(c) { pageCharts.push(c); return c; }

// Error bars for Chart.js (CIs) — reads dataset.errorLow / dataset.errorHigh
// arrays parallel to data. Draws along the value axis with a cap at each end:
// vertical normally, horizontal when the chart uses indexAxis "y" (flipped
// bars), where the caps come out as short vertical ticks.
const ErrorBarsPlugin = {
  id: "wxErrorBars",
  afterDatasetsDraw(chart) {
    const { ctx } = chart;
    const flipped = chart.options.indexAxis === "y";
    chart.data.datasets.forEach((ds, di) => {
      if (!ds.errorLow) return;
      const meta = chart.getDatasetMeta(di);
      if (meta.hidden) return;
      ctx.save();
      ctx.strokeStyle = ds.borderColor || "#000";
      ctx.lineWidth = 2;
      meta.data.forEach((pt, i) => {
        const lo = ds.errorLow[i], hi = ds.errorHigh[i];
        if (lo == null || hi == null) return;
        const scale = flipped ? chart.scales.x : chart.scales.y;
        const p1 = scale.getPixelForValue(lo);
        const p2 = scale.getPixelForValue(hi);
        // Capped at both ends, across the bar rather than along it: on the
        // horizontal explorer bars a bare line reads as part of the bar, and
        // the caps are what make the interval's ends findable. Sized off the
        // bar so they stay proportional as the canvas grows with the group
        // count, and clamped so thin bars still get a visible tick.
        const half = Math.max(3, Math.min(7,
          (flipped ? pt.height : pt.width) * 0.35)) / 2;
        ctx.beginPath();
        if (flipped) {
          ctx.moveTo(p1, pt.y); ctx.lineTo(p2, pt.y);
          ctx.moveTo(p1, pt.y - half); ctx.lineTo(p1, pt.y + half);
          ctx.moveTo(p2, pt.y - half); ctx.lineTo(p2, pt.y + half);
        } else {
          ctx.moveTo(pt.x, p1); ctx.lineTo(pt.x, p2);
          ctx.moveTo(pt.x - half, p1); ctx.lineTo(pt.x + half, p1);
          ctx.moveTo(pt.x - half, p2); ctx.lineTo(pt.x + half, p2);
        }
        ctx.stroke();
      });
      ctx.restore();
    });
  }
};

// URL state helpers — page id stays in the hash, per-page state lives in the
// query string (merged, so dev's ?bundle= survives).
function getParam(k) { return new URLSearchParams(location.search).get(k); }
function setParams(obj) {
  const q = new URLSearchParams(location.search);
  for (const [k, v] of Object.entries(obj)) {
    if (v == null || v === "") q.delete(k); else q.set(k, v);
  }
  history.replaceState(null, "", location.pathname + "?" + q.toString() + location.hash);
}

/* ------------------------------------------------------ shared widgets -- */

function groupingSelect(onChange, initial, labelText = "Select a grouping") {
  const wrap = el("div");
  wrap.append(el("label", { class: "field-label", for: "grouping-sel" }, labelText));
  const sel = el("select", { class: "grouping", id: "grouping-sel", onchange: () => onChange(sel.value) });
  for (const g of CONFIG.groupings) {
    sel.append(el("option", { value: g.id }, g.label));
  }
  sel.value = initial || CONFIG.groupings[0].id;
  wrap.append(sel);
  return wrap;
}

/* Generic table: sort (click header), global search, optional per-column
   filters (Shiny DT filter="top" equivalent), pagination. rows = array of
   objects; columns = [{id, label, width?}]. */
function dataTable({ columns, rows, pageSize = 25, pageSizeOptions = null, columnFilters = true, clickable = false, onRowClick = null, searchFields = [] }) {
  let sortCol = null, sortDir = 1, page = 0, globalQ = "";
  const colQ = {};
  // Columns filtered by menu match exactly; text columns match on substring.
  // A menu that matched substrings would let "Regulation" also select a topic
  // merely containing the word.
  const selectCols = new Set();
  let filtered = rows.slice();
  let selectedRow = null;

  const root = el("div");
  const tools = el("div", { class: "table-tools" });
  const search = el("input", { type: "search", placeholder: "Search…",
    oninput: () => { globalQ = search.value.toLowerCase(); page = 0; refresh(); } });
  const count = el("span", { class: "count" });
  tools.append(search);
  if (pageSizeOptions) {   // viewer-adjustable page length (opt-in per table)
    const psSel = el("select", { onchange: () => {
      pageSize = Number(psSel.value); page = 0; refresh();
    } });
    for (const n of pageSizeOptions) psSel.append(el("option", { value: n }, String(n)));
    psSel.value = String(pageSize);
    tools.append(el("label", { class: "pagesize" }, "Show ", psSel, " rows"));
  }
  tools.append(count);

  const scroll = el("div", { class: "table-scroll" });
  const table = el("table", { class: "data" + (clickable ? " clickable" : "") });
  const thead = el("thead");
  const headRow = el("tr");
  for (const c of columns) {
    const th = el("th", c.width ? { style: `width:${c.width}` } : {});
    const name = el("span", { class: "col-name", onclick: () => {
      if (sortCol === c.id) sortDir = -sortDir; else { sortCol = c.id; sortDir = 1; }
      refresh();
    } }, c.label, " ", el("span", { class: "arrow" }, ""));
    th.append(name);
    if (columnFilters) {
      // A column with a small closed set of values filters better as a menu
      // than as a text box: the reader sees what is on offer instead of
      // guessing at spelling, and picks in one motion. Options are read off
      // the rows, so a value added upstream appears without an edit here.
      if (c.filter === "select") {
        const sel = el("select", { onchange: () => {
          colQ[c.id] = sel.value; page = 0; refresh();
        } });
        sel.append(el("option", { value: "" }, c.filterAll || "All"));
        const values = [...new Set(rows.map(r => String(r[c.id] ?? "")))]
          .filter(Boolean).sort((a, b) => a.localeCompare(b));
        for (const v of values) sel.append(el("option", { value: v }, v));
        th.append(sel);
        selectCols.add(c.id);
      } else {
        const inp = el("input", { type: "text", placeholder: "Filter…",
          oninput: () => { colQ[c.id] = inp.value.toLowerCase(); page = 0; refresh(); } });
        th.append(inp);
      }
    }
    headRow.append(th);
  }
  thead.append(headRow);
  const tbody = el("tbody");
  table.append(thead, tbody);
  scroll.append(table);

  const pager = el("div", { class: "pager" });
  const prev = el("button", { onclick: () => { page--; refresh(); } }, "‹ Prev");
  const info = el("span");
  const next = el("button", { onclick: () => { page++; refresh(); } }, "Next ›");
  pager.append(prev, info, next);

  function refresh() {
    filtered = rows.filter(r => {
      // Global search covers the visible columns plus any hidden searchFields
      // (e.g. Joe's content keywords, so "reception" finds questions whose
      // wording never uses the word).
      if (globalQ && !columns.some(c => String(r[c.id] ?? "").toLowerCase().includes(globalQ)) &&
          !searchFields.some(f => String(r[f] ?? "").toLowerCase().includes(globalQ))) return false;
      for (const c of columns) {
        const q = colQ[c.id];
        if (!q) continue;
        const v = String(r[c.id] ?? "");
        if (selectCols.has(c.id) ? v !== q : !v.toLowerCase().includes(q)) return false;
      }
      return true;
    });
    if (sortCol) {
      filtered.sort((a, b) => {
        const av = a[sortCol] ?? "", bv = b[sortCol] ?? "";
        const an = parseFloat(av), bn = parseFloat(bv);
        const cmp = (!isNaN(an) && !isNaN(bn)) ? an - bn : String(av).localeCompare(String(bv));
        return cmp * sortDir;
      });
    }
    const pages = Math.max(1, Math.ceil(filtered.length / pageSize));
    page = Math.min(Math.max(0, page), pages - 1);
    const slice = filtered.slice(page * pageSize, (page + 1) * pageSize);

    tbody.textContent = "";
    for (const r of slice) {
      const tr = el("tr");
      if (r === selectedRow) tr.classList.add("selected");
      // A column may render its own cell. Sorting, search and the column
      // filter still read r[c.id], so what a custom cell shows has to be a
      // presentation of that value rather than a different one.
      for (const c of columns)
        tr.append(c.render ? el("td", {}, c.render(r))
                           : el("td", {}, String(r[c.id] ?? "")));
      if (clickable) tr.addEventListener("click", () => {
        selectedRow = r;
        refresh();
        onRowClick && onRowClick(r);
      });
      tbody.append(tr);
    }
    count.textContent = `${filtered.length} of ${rows.length} rows`;
    info.textContent = `Page ${page + 1} of ${pages}`;
    prev.disabled = page === 0;
    next.disabled = page >= pages - 1;
    headRow.querySelectorAll(".arrow").forEach((a, i) =>
      a.textContent = columns[i].id === sortCol ? (sortDir === 1 ? "▲" : "▼") : "");
  }

  refresh();
  root.append(tools, scroll, pager);
  // Select (and page to) the first row matching pred — for deep-linked rows.
  root.selectRow = (pred) => {
    const i = rows.findIndex(pred);
    if (i >= 0) { selectedRow = rows[i]; page = Math.floor(i / pageSize); refresh(); }
  };
  root.selectFirst = () => root.selectRow(() => true);
  return root;
}

/* Grouped bar chart from long rows [{group, category, value, label}].
   Category axis order + series (group) order = first-appearance order in the
   data (which preserves R's factor-level ordering from the compiler), unless
   an explicit categoryOrder is supplied by config. */
let activeChart = null;
function groupedBarChart(canvas, rows, { title = "", xLabel = "", yLabel = "", categoryOrder = null, showCI = false, horizontal = false, colors = null, legend = true, categoryWidth = null }) {
  const groupsSeen = [], catsSeen = [];
  for (const r of rows) {
    const g = naLabel(r.group), c = naLabel(r.category);
    if (!groupsSeen.includes(g)) groupsSeen.push(g);
    if (!catsSeen.includes(c)) catsSeen.push(c);
  }
  let cats = catsSeen;
  if (categoryOrder) {
    const order = categoryOrder.map(naLabel);
    cats = order.filter(c => catsSeen.includes(c))
      .concat(catsSeen.filter(c => !order.includes(c))); // unknowns (e.g. NA) go last
  }
  const lookup = new Map(rows.map(r => [naLabel(r.group) + "\x1F" + naLabel(r.category), r]));
  colors = colors || viridis(groupsSeen.length);
  const datasets = groupsSeen.map((g, i) => ({
    label: g,
    backgroundColor: colors[i],
    data: cats.map(c => {
      const r = lookup.get(g + "\x1F" + c);
      return r ? r.value : null;
    }),
    barLabels: cats.map(c => {
      const r = lookup.get(g + "\x1F" + c);
      return r ? String(r.label ?? "") : "";
    }),
    // CI whiskers (opt-in): stroked by ErrorBarsPlugin in the theme's ink —
    // a same-color whisker would vanish where it overlaps its own bar.
    ...(showCI ? {
      borderColor: getComputedStyle(document.body).getPropertyValue("--text").trim() || "#000",
      errorLow: cats.map(c => { const r = lookup.get(g + "\x1F" + c); return r && r.low != null ? r.low : null; }),
      errorHigh: cats.map(c => { const r = lookup.get(g + "\x1F" + c); return r && r.upp != null ? r.upp : null; })
    } : {})
  }));

  if (activeChart) { activeChart.destroy(); activeChart = null; }
  activeChart = new Chart(canvas, {
    type: "bar",
    data: { labels: cats.map(tickLines), datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      // horizontal (Joe's Aug-2026 explorer): categories run down the y-axis
      indexAxis: horizontal ? "y" : "x",
      interaction: { mode: "nearest", intersect: false, axis: horizontal ? "y" : "x" },
      layout: { padding: horizontal ? { right: 48 } : { top: 24 } },
      plugins: {
        title: title ? { display: true, text: title, align: "start",
          font: { size: 15, weight: "600" }, padding: { bottom: 16 } } : { display: false },
        // legend:false for single-group charts (quiz reveal) — a one-entry
        // "Group: All" legend is noise.
        legend: legend ? { position: "bottom", title: { display: true, text: "Group" } }
          : { display: false },
        datalabels: showCI ? { display: false } : {
          anchor: "end", align: "end", offset: 0, clip: false,
          color: getComputedStyle(document.body).getPropertyValue("--text").trim() || "#000",
          font: { size: groupsSeen.length > 8 ? 9 : 11 },
          formatter: (v, ctx) => ctx.dataset.barLabels[ctx.dataIndex]
        },
        tooltip: {
          callbacks: {
            label: (ctx) => {
              const base = `${ctx.dataset.label}: ${ctx.dataset.barLabels[ctx.dataIndex]}`;
              const lo = ctx.dataset.errorLow && ctx.dataset.errorLow[ctx.dataIndex];
              const hi = ctx.dataset.errorHigh && ctx.dataset.errorHigh[ctx.dataIndex];
              return lo != null && hi != null
                ? `${base} (95% CI ${lo.toFixed(1)}–${hi.toFixed(1)})` : base;
            }
          }
        }
      },
      // autoSkip off on the category axis. Chart.js drops every other tick
      // when the labels are tall, which on a select-all battery leaves half
      // the bars unlabelled and silently mis-attributes the rest to the
      // nearest label that did survive. The canvas is grown to fit the bars
      // instead, in the caller.
      scales: horizontal ? {   // xLabel/yLabel keep their meaning: category / value
        // The category axis is pinned rather than left to fit itself, so the
        // label column is as wide as the caller wrapped its text for. Chart.js
        // sizes it to the widest label otherwise, which on a chart of long
        // options leaves the plot a sliver and on a chart of short ones wastes
        // the width the wrap already gave up.
        y: { title: { display: !!xLabel, text: xLabel }, grid: { display: false },
             ticks: { autoSkip: false },
             afterFit: (scale) => { if (categoryWidth) scale.width = categoryWidth; } },
        x: { title: { display: !!yLabel, text: yLabel }, beginAtZero: true, grace: "15%" }
      } : {
        x: { title: { display: !!xLabel, text: xLabel }, grid: { display: false },
             ticks: { autoSkip: false } },
        y: { title: { display: !!yLabel, text: yLabel }, beginAtZero: true, grace: "15%" }
      }
    },
    plugins: [ChartDataLabels, ErrorBarsPlugin]   // ErrorBarsPlugin no-ops without errorLow
  });
  return activeChart;
}

/* ------------------------------------------------------------ components -- */

const components = {};

/* Explore: question table + split dropdown + distribution chart.
 *
 * The whole dashboard. Intro line → control bar (split, colors, intervals,
 * PDF) → the selected question as a heading → full-width chart → caption →
 * the question table. Everything it draws was computed by
 * 02_create_question_data.R; this file picks a slice and renders it. */

// SVG/Chart.js tick labels don't wrap on their own, and response labels here
// are whole sentences — the three regulatory proposals run to 539 characters —
// so they are broken into tick lines at word boundaries.
//
// Nothing is truncated. An option cut off at an ellipsis is a bar the reader
// cannot identify, and the three proposals differ only in their later clauses:
// trimmed to a common prefix they would read as the same answer three times.
// The chart grows to fit instead; see draw(), which sizes the canvas from the
// line counts this returns.
// Approximate width of a character in the chart's 12px sans tick font. Used
// to turn an available pixel width into a wrap column; being a few percent out
// only shifts a word between lines.
const CHAR_PX = 6.6;

function wrapTickLabel(text, width = 48) {
  const words = String(text).split(/\s+/);
  const lines = [];
  let line = "";
  for (const w of words) {
    if (line && (line + " " + w).length > width) { lines.push(line); line = w; }
    else line = line ? line + " " + w : w;
  }
  if (line) lines.push(line);
  return lines.join("\n");
}

components.explore = async function (page, container) {
  const questions = await fetchJSON(page.questions.replace(/^data\//, "data/"));
  let grouping = urlGrouping() || page.default_grouping || "All";
  let showCI = getParam("ci") === "1";   // ?ci=1 deep-links the CI view
  let currentArm = getParam("arm");      // ?arm= deep-links a split-sample arm
  let scheme = urlScheme();              // ?scheme= deep-links a color scheme
  let currentQuestionText = "";          // for the PDF title
  let currentSurveyLabel = "";           // and its subtitle line
  // Question files are keyed by the canonical variable name. One row per
  // question rather than per wave: a question asked in both waves is one entry
  // whose pooled distribution the survey-year split can take apart.
  const keyOf = (r) => r.id;
  // ?q=<id> deep-links a question; else row 1.
  const urlQ = getParam("q");
  let currentKey = (urlQ && questions.some(x => keyOf(x) === urlQ))
    ? urlQ : (questions[0] && keyOf(questions[0]));

  const chartCard = el("div", { class: "card" });
  const weightedTip = explain("weighted_pct");
  const wrap = el("div", { class: "chart-wrap" });
  const canvas = el("canvas");
  wrap.append(canvas);

  // Chrome created up front so draw() can update it.
  const qIntro = el("p", { class: "fu-question-intro" }, "");
  const qHead = el("h3", { class: "fu-question-head" }, "");
  const qFlags = el("div", { class: "fu-question-flags" });
  const armBox = el("div", { class: "fu-arm-pick" });
  const caption = el("div", { class: "fu-caption fu-explore-caption" });
  const ciBox = el("input", { type: "checkbox", id: "ci-toggle" });
  ciBox.checked = showCI;
  ciBox.onchange = () => { showCI = ciBox.checked; setParams({ ci: showCI ? "1" : null }); draw(); };
  chartCard.append(qIntro, qHead, qFlags, armBox, wrap, caption);

  let groupingSel = null;   // set below; draw() updates it on split fallback
  let currentArmLabel = null;   // for the PDF subtitle

  // The arm menu, inside the chart card rather than the toolbar above it: it
  // belongs to this question, not to the page, and it disappears with the
  // question. Only split-sample items have one.
  function renderArmPicker(v, armList, armKey) {
    armBox.textContent = "";
    armBox.style.display = armList ? "" : "none";
    if (!armList) return;
    const sel = el("select", { class: "fu-arm-select", onchange: () => {
      currentArm = sel.value;
      setParams({ arm: currentArm });   // keep the URL shareable
      draw();
    } });
    for (const a of armList) sel.append(el("option", { value: a.id }, a.label));
    sel.value = armKey;
    armBox.append(
      el("span", { class: "fu-arm-label" }, (v.arm_prompt || "Version") + ":"),
      sel);
  }

  // The split-aware caption: how many answered, which waves, that the
  // percentages are weighted, the smallest group, and the provenance carrying
  // the variable code. Templates are authored in 03_build_dashboard.R so the
  // engine stays generic; every number in them comes from the question file.
  function renderCaption(v, g, summaries, armLabel) {
    const tpl = CONFIG.explore_caption;
    const s = summaries && summaries[g];
    caption.textContent = "";
    if (!s) return;
    const waves = /[-,]/.test(s.years)
      ? fillTpl(tpl.waves_many, { years: s.years.replace("-", " and ") })
      : fillTpl(tpl.waves_one, { years: s.years });
    const gcfg = CONFIG.groupings.find(x => x.id === g);
    const splitClause = g === "All" ? ""
      : fillTpl(tpl.split_clause, { group_phrase: (gcfg && gcfg.phrase) || "group" });
    let text = fillTpl(tpl.answered, {
      n: Number(s.n).toLocaleString(), waves, split_clause: splitClause });
    if (g !== "All") text += fillTpl(tpl.smallest, {
      smallest: s.smallest, smallest_n: Number(s.smallest_n).toLocaleString() });
    // Respondents who answered the question but have no value for this
    // grouping. Said rather than absorbed: without it the count above is a
    // count of a different set of people from the one the bars rest on.
    if (s.dropped > 0) text += fillTpl(tpl.dropped, {
      dropped: Number(s.dropped).toLocaleString(),
      group_phrase: (gcfg && gcfg.phrase) || "group" });
    // A select-all battery is one bar per option, each its own share of the
    // same people — so they do not sum to 100. Said before the reader works it
    // out from bars that look too small.
    if (v.multi_response) text += " " + tpl.multi_response;
    caption.append(el("p", {}, text));
    // Which version this is, in the caption as well as the menu: the PDF's
    // notes are read off the caption, so a download that omitted it would not
    // say which half of the sample it describes.
    if (armLabel) caption.append(el("p", {}, fillTpl(tpl.arm, {
      n: v.arms.length, prompt: v.arm_prompt, label: armLabel })));
    if (v.asked_if) caption.append(el("p", {},
      fillTpl(tpl.asked_if, { condition: v.asked_if })));
    caption.append(el("p", { class: "fu-caption-provenance",
      html: fillTpl(tpl.provenance, { variable: esc(v.variable) }) }));
  }

  async function draw() {
    if (!currentKey) return;
    const v = await fetchJSON(`data/q/${currentKey}.json`);
    // Split-sample questions carry one set of splits per arm; everything else
    // carries a single set under "all". Reading through the arm either way
    // keeps one code path. An arm from the URL that this question does not
    // have falls back to the first rather than drawing nothing.
    const armList = Array.isArray(v.arms) && v.arms.length ? v.arms : null;
    const armKey = armList
      ? (armList.some(a => a.id === currentArm) ? currentArm : armList[0].id)
      : "all";
    if (armList) currentArm = armKey;
    const armLabel = armList
      ? (armList.find(a => a.id === armKey) || {}).label : null;
    const SPLITS = v.splits[armKey] || {};
    const SUMMARIES = v.summaries[armKey] || {};

    renderArmPicker(v, armList, armKey);

    // A question is not asked under every split — fall back to Everyone
    // rather than drawing an empty panel, and show the select doing it.
    let g = grouping;
    if (!(SPLITS[g] && SPLITS[g].length)) g = "All";
    if (groupingSel) groupingSel.value = g;
    const labelFor = (resp) => {
      const hit = (v.options || []).find(o => String(o.value) === String(resp));
      // An unlabelled value is shown as itself rather than dropped: it means
      // the data carries a code the instrument does not document.
      return hit ? hit.label : String(resp);
    };
    currentQuestionText = v.question || currentKey;
    // concat, not join alone: a one-wave question's `waves` arrives as a bare
    // string if anything upstream unboxes it, and a string has no join().
    currentSurveyLabel = [v.topic, v.variable && `Variable ${v.variable}`,
      [].concat(v.waves || []).join(" + ")].filter(Boolean).join("  ·  ");
    // The stem a battery shares sits above the item, smaller: "Please rate
    // your level of concern…" is what makes "National security" a question.
    qIntro.textContent = v.intro || "";
    qIntro.style.display = v.intro ? "" : "none";
    qHead.textContent = v.question || currentKey;
    if (weightedTip) qHead.append(" ", infoTip(weightedTip));
    // An item whose stimulus varied between respondents is not a clean
    // population measure, and the chart cannot show that on its own.
    qFlags.textContent = "";
    if (v.experimental) {
      const note = explain("experimental");
      qFlags.append(el("span", { class: "fu-flag" }, "Split-sample item"));
      if (note) qFlags.append(" ", infoTip(note));
    }
    renderCaption(v, g, SUMMARIES, armLabel);
    currentArmLabel = armLabel;
    // How much room the labels get, measured rather than assumed. A third of
    // a full-width page is about 95 characters a line, which takes the three
    // 539-character regulatory proposals from ten wrapped lines to five; on a
    // narrow window it falls back to something the plot can still live beside.
    const availPx = wrap.clientWidth || 1200;
    const axisPx = Math.round(Math.min(Math.max(availPx * 0.34, 240), 820));
    const wrapChars = Math.max(24, Math.floor((axisPx - 16) / CHAR_PX));

    const rows = (SPLITS[g] || []).map(r => ({
      group: r.group, category: wrapTickLabel(labelFor(r.resp), wrapChars),
      value: r.p, label: Math.round(r.p) + "%", low: r.p_low, upp: r.p_upp
    }));
    // Declared, not inferred. The chart otherwise orders categories by first
    // appearance, and a response nobody in the first group gave then lands at
    // the end of the axis — which on a 0-10 scale reads as a scale with its
    // rungs shuffled.
    const categoryOrder = (v.options || []).map(o => wrapTickLabel(o.label, wrapChars));
    const nGroups = new Set(rows.map(r => naLabel(r.group))).size;
    // Sized from the labels themselves rather than a flat per-category
    // allowance, because they run from one line to a dozen. Each category gets
    // whichever is taller: the room its wrapped label needs, or the room its
    // bars need. No cap — a capped height is a truncated label by another
    // route, since Chart.js would drop ticks to fit.
    const LINE = 14, LABEL_PAD = 13, BAR_PAD = 12;
    const catHeight = categoryOrder.reduce((total, label) =>
      total + Math.max(tickLines(label).length * LINE + LABEL_PAD,
                       nGroups * 18 + BAR_PAD), 0);
    // Chrome outside the plot: the value axis and its title, plus the legend
    // only when there is more than one series to label.
    const chrome = 52 + (nGroups > 1 ? 40 : 0);
    wrap.style.height = Math.max(340, chrome + catHeight) + "px";
    groupedBarChart(canvas, rows, {
      title: "",
      xLabel: page.chart.x_label, yLabel: page.chart.y_label,
      showCI,
      horizontal: true,
      categoryOrder,
      // A one-entry legend reading "All" labels nothing; the split dropdown
      // above already says whose responses these are.
      legend: nGroups > 1,
      categoryWidth: axisPx,
      colors: schemeSeriesColors(scheme, nGroups)
    });
  }

  const tableCard = el("div", { class: "card" });
  tableCard.append(el("h3", {}, "Questions (click on a question)"));
  const qTable = dataTable({
    columns: [
      { id: "topic", label: "Topic", width: "18%",
        filter: "select", filterAll: "All topics" },
      // The stem above the item, where there is one. Without it a row of the
      // select-all batteries reads "Don't know", which is not a question.
      { id: "question", label: "Question Text", width: "52%",
        render: (r) => {
          const cell = el("div");
          if (r.intro) cell.append(el("div", { class: "fu-row-intro" }, r.intro));
          cell.append(el("div", {}, r.question));
          return cell;
        } },
      { id: "kind", label: "Type", width: "18%" },
      { id: "waves", label: "Asked" }
    ],
    rows: questions, pageSize: 10, clickable: true,
    // Search also matches the variable name, scale family, content keywords
    // and the shared stem ("trust" finds the battery whose items are only
    // organization names, and "concern" finds worry_sec, whose own text is
    // "National security (including terrorism and war)").
    searchFields: ["variable", "response_scale", "keywords", "intro"],
    pageSizeOptions: [10, 25, 50, 100],
    onRowClick: (r) => {
      currentKey = keyOf(r);
      setParams({ q: currentKey });   // keep the URL shareable
      // The chart lives well above the table — scroll it into view so the
      // click visibly loads the new question.
      window.scrollTo({ top: 0, behavior: "smooth" });
      draw();
    }
  });
  if (currentKey === urlQ) qTable.selectRow(r => keyOf(r) === urlQ);
  else qTable.selectFirst();
  tableCard.append(qTable);

  const intro = el("p", { class: "fu-explore-intro" }, page.intro ||
    "Click a survey question in the table below to see the weighted distribution of responses, split by the group you choose.");
  const bar = el("div", { class: "card fu-toolbar" });
  const gWrap = groupingSelect(g => { grouping = g; draw(); }, grouping, "Split responses by");
  groupingSel = gWrap.querySelector("select");
  bar.append(gWrap);
  bar.append(schemeSelect(scheme, (sc) => {
    scheme = sc;
    setParams({ scheme: sc === DEFAULT_SCHEME ? null : sc });
    draw();
  }));
  bar.append(el("label", { class: "fu-ci-label", for: "ci-toggle" },
    ciBox, " Show 95% confidence intervals"));
  // The caption below the chart is the document's notes: how many answered,
  // that the percentages are weighted, which waves, the smallest group, and
  // the provenance with the variable code. A chart without them cannot be
  // handed to anyone.
  bar.append(pdfButton("Download chart (PDF)", () => pdfDocument({
    title: currentQuestionText,
    subtitle: [
      currentSurveyLabel,
      currentArmLabel,
      grouping === "All" ? "All respondents"
        : "Split by " + ((CONFIG.groupings.find(x => x.id === grouping) || {}).label || grouping),
      showCI ? "95% confidence intervals shown" : null
    ].filter(Boolean).join("  ·  "),
    canvas: chartSnapshot(canvas),
    notesHTML: caption.innerHTML,
    filename: `fusion-${currentKey}.pdf`
  })));
  container.append(el("div", { class: "page fu-explore-page" },
    el("div", { class: "content" }, intro, bar, chartCard, tableCard)));
  await draw();
};
/* ---- methodology affordances --------------------------------------------
 * "What does this number mean?" popovers replace sidebar prose walls. All
 * text is compiler-authored in config.explainers (templated with {tokens}),
 * so the engine stays generic. Panels open BELOW their trigger. */

function fillTpl(s, vals) {
  return String(s || "").replace(/\{(\w+)\}/g, (_, k) => (vals && vals[k] != null) ? vals[k] : "");
}
function explain(key, vals) {
  const t = CONFIG.explainers && CONFIG.explainers[key];
  return t ? fillTpl(t, vals) : null;
}

let openTipClose = null;
document.addEventListener("click", (e) => {
  if (openTipClose && !e.target.closest(".tip-wrap")) openTipClose();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && openTipClose) openTipClose();
});

function infoTip(html, opts = {}) {
  const wrap = el("span", { class: "tip-wrap" });
  const btn = el("button", {
    class: "tip-btn" + (opts.text ? " text" : ""), type: "button",
    "aria-label": opts.label || opts.text || "What does this mean?",
    "aria-expanded": "false",
    onclick: (e) => { e.stopPropagation(); toggle(); }
  }, opts.text || "?");
  const panel = el("div", { class: "tip-panel", role: "note", html });
  function close() {
    wrap.classList.remove("open");
    btn.setAttribute("aria-expanded", "false");
    if (openTipClose === close) openTipClose = null;
  }
  function toggle() {
    if (wrap.classList.contains("open")) return close();
    if (openTipClose) openTipClose();
    wrap.classList.add("open");
    btn.setAttribute("aria-expanded", "true");
    // keep the panel on-screen: right-align when the trigger sits right of center
    panel.classList.toggle("align-right", btn.getBoundingClientRect().left > window.innerWidth * 0.55);
    openTipClose = close;
  }
  wrap.append(btn, panel);
  // ?tips=open auto-opens a tip — headless-screenshot aid. Opens the first
  // tip created on the page, or the Nth with &tipn=N.
  if (getParam("tips") === "open") {
    infoTip._count = (infoTip._count || 0) + 1;
    if (infoTip._count === (parseInt(getParam("tipn"), 10) || 1)) setTimeout(toggle, 60);
  }
  return wrap;
}

components.static_page = async function (page, container) {
  container.append(el("div", { class: "page" },
    el("div", { class: "content" },
      el("div", { class: "card fu-static", html: page.html || "" }))));
};
/* ------------------------------------------------------------- routing -- */

function currentPageId() {
  return location.hash.replace(/^#/, "") || CONFIG.pages[0].id;
}

async function renderPage() {
  const app = document.getElementById("app");
  const id = currentPageId();
  const page = CONFIG.pages.find(p => p.id === id) || CONFIG.pages[0];

  document.querySelectorAll("#nav-pages a").forEach(a =>
    a.classList.toggle("active", a.getAttribute("href") === "#" + page.id));
  document.querySelectorAll("#nav-pages .nav-group").forEach(g => {
    g.classList.remove("open");
    g.querySelector(".nav-group-btn").classList.toggle("active",
      !!g.querySelector(`a[href="#${page.id}"]`));
  });

  if (activeChart) { activeChart.destroy(); activeChart = null; }
  pageCharts.forEach(c => c.destroy());
  pageCharts = [];
  app.textContent = "";
  const renderer = components[page.component];
  if (!renderer) {
    app.append(el("div", { class: "error" }, `Unknown component: ${page.component}`));
    return;
  }
  try {
    await renderer(page, app);
  } catch (err) {
    console.error(err);
    app.append(el("div", { class: "error" }, `Failed to render "${page.label}": ${err.message}`));
  }
}

/* ---- viewer theme switcher (user-approved roster, 2026-07-07) ----------- */
// Themes restyle chrome only; chart data colors stay viridis in all of them.
const THEMES = [
  { id: "fusion", label: "Fusion", swatch: "#443A83" },
  { id: "dark", label: "Dark", swatch: "#0f172a" },
  { id: "greyscale", label: "Greyscale (high contrast)", swatch: "#000000" }
];

function applyTheme(id, { rerender = false } = {}) {
  document.documentElement.dataset.theme = id;
  // Chart text (titles, ticks, legends) follows the theme's ink so dark
  // themes don't render Chart.js's default grey-on-dark.
  if (window.Chart)
    Chart.defaults.color = getComputedStyle(document.body).getPropertyValue("--text").trim() || "#666";
  try { sessionStorage.setItem("engine-theme", id); } catch { /* private mode */ }
  document.querySelectorAll("#theme-menu button").forEach(b =>
    b.classList.toggle("active", b.dataset.theme === id));
  // Charts capture label colors at creation — redraw the page so they follow.
  if (rerender) renderPage();
}

function themeSwitcher() {
  const wrap = el("div", { id: "theme-switch" });
  const btn = el("button", { id: "theme-btn", title: "Adjust colors",
    onclick: () => menu.classList.toggle("open") }, "◐ Adjust colors");
  const menu = el("div", { id: "theme-menu" });
  for (const t of THEMES) {
    menu.append(el("button", { "data-theme": t.id, onclick: () => {
      applyTheme(t.id, { rerender: true });
      menu.classList.remove("open");
    } }, el("span", { class: "swatch", style: `background:${t.swatch}` }), t.label));
  }
  document.addEventListener("click", (e) => {
    if (!wrap.contains(e.target)) menu.classList.remove("open");
  });
  wrap.append(btn, menu);
  return wrap;
}

async function boot() {
  try {
    CONFIG = await fetchJSON("config.json");
  } catch (err) {
    document.getElementById("app").innerHTML =
      `<div class="error">Could not load bundle config from <code>${esc(BUNDLE)}config.json</code>. ` +
      `Serve the repo root and pass ?bundle=/DASHBOARDS/&lt;slug&gt;/ or copy the engine into the bundle.</div>`;
    return;
  }
  document.title = CONFIG.project.title;
  // Brand lockup: wordmark + optional small institutional subtitle line.
  const navTitle = document.getElementById("nav-title");
  navTitle.textContent = "";
  navTitle.append(el("span", { class: "brand-name" }, CONFIG.project.nav_title || CONFIG.project.title));
  if (CONFIG.project.nav_subtitle)
    navTitle.append(el("span", { class: "brand-sub" }, CONFIG.project.nav_subtitle));
  const nav = document.getElementById("nav-pages");
  // Featured pages render as links; pages carrying nav_group fold into a
  // labeled dropdown at the position of the group's first member.
  const navGroups = new Map();
  const closeMenus = () => nav.querySelectorAll(".nav-group.open")
    .forEach(g => { g.classList.remove("open");
      g.querySelector(".nav-group-btn").setAttribute("aria-expanded", "false"); });
  for (const p of CONFIG.pages) {
    if (p.hidden) continue; // e.g. the place-profile page (reached via stubs/search)
    if (!p.nav_group) { nav.append(el("a", { href: "#" + p.id }, p.label)); continue; }
    if (!navGroups.has(p.nav_group)) {
      const wrap = el("div", { class: "nav-group" });
      const btn = el("button", { class: "nav-group-btn", type: "button",
        "aria-expanded": "false", "aria-haspopup": "true",
        onclick: (e) => {
          e.stopPropagation();
          const open = wrap.classList.contains("open");
          closeMenus();
          if (!open) {
            // Fixed positioning from the button's viewport rect: the
            // navbar scrolls horizontally (overflow-x), which clips
            // absolutely-positioned children — fixed escapes any ancestor
            // overflow in every theme.
            const r = btn.getBoundingClientRect();
            menu.style.left = Math.round(r.left) + "px";
            menu.style.top = Math.round(r.bottom) + "px";
            wrap.classList.add("open");
            btn.setAttribute("aria-expanded", "true");
          }
        } }, p.nav_group, el("span", { class: "nav-caret" }, " ▾"));
      const menu = el("div", { class: "nav-menu", role: "menu" });
      wrap.append(btn, menu);
      nav.append(wrap);
      navGroups.set(p.nav_group, menu);
    }
    navGroups.get(p.nav_group).append(el("a", { href: "#" + p.id, onclick: closeMenus }, p.label));
  }
  document.addEventListener("click", closeMenus);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeMenus(); });
  // Theme precedence: ?theme= deep link > viewer's per-tab pick > bundle default.
  let saved = null;
  try { saved = sessionStorage.getItem("engine-theme"); } catch { /* private mode */ }
  const themeParam = new URLSearchParams(location.search).get("theme");
  const initialTheme = [themeParam, saved, CONFIG.theme && CONFIG.theme.default, "fusion"]
    .find(t => t && THEMES.some(x => x.id === t));
  if (CONFIG.theme && CONFIG.theme.allow_viewer_switch !== false) {
    document.getElementById("navbar").append(themeSwitcher());
  }
  applyTheme(initialTheme);
  // Guarded: a blocked/failed vendor script must not freeze boot on the
  // loading screen — chartless pages still render, chart pages fail visibly
  // through renderPage's per-component catch.
  if (window.Chart) Chart.defaults.font.family = getComputedStyle(document.body).fontFamily;
  // Config-driven footer: a clear end-of-page bookend (navbar colors).
  if (CONFIG.footer && !document.getElementById("site-footer")) {
    const f = CONFIG.footer;
    const brand = el("div", { class: "foot-brand" },
      el("span", { class: "brand-name" }, CONFIG.project.nav_title || CONFIG.project.title));
    if (f.tagline) brand.append(el("p", { class: "foot-tag" }, f.tagline));
    const cols = el("div", { class: "foot-inner" }, brand);
    if (f.links_html) cols.append(el("nav", { class: "foot-links", html: f.links_html }));
    const meta = el("div", { class: "foot-meta" });
    if (f.funding) meta.append(el("p", {}, f.funding));
    meta.append(el("p", { class: "foot-build" }, "BUILD " + (window.FU_BUILD || "dev")));
    cols.append(meta);
    document.body.append(el("footer", { id: "site-footer" }, cols));
  }
  window.addEventListener("hashchange", renderPage);
  await renderPage();
}

boot();
