// Runs inside the web page (main world) to find the DOM elements under a drawing.
//
// background.js injects `inspectPage` with chrome.scripting.executeScript({world: "MAIN"})
// each time Critique asks. It has to run in the page's own world, not the extension's
// isolated one, because React/Vue/Svelte keep their component trees on DOM expando
// properties (`__reactFiber$…`, `__vueParentComponent`, `__svelte_meta`) that isolated
// worlds can't see. It returns plain JSON only.
//
// Request: {screen: {x, y, w, h}, scale, hint}
//   screen — the drawn area in global screen points (top-left origin, primary display at 0,0)
//   scale  — the display's backing scale factor (2 on Retina)
//   hint   — what macOS Accessibility saw there, e.g. `button “Sign up”`
//
// Screen → viewport mapping (and its limits):
//   On macOS, window.screenX/screenY and outerWidth/outerHeight are in the same
//   screen points Critique uses, while innerWidth/innerHeight are in CSS px.
//   Page zoom = devicePixelRatio / backing scale, so viewport CSS px =
//   (screen point − window origin − browser chrome) / zoom.
//   The browser's chrome (tab strip + toolbar) is assumed to be all on top:
//   chromeTop = outerHeight − innerHeight·zoom. Anything that shrinks the viewport
//   from the bottom (DevTools docked at the bottom, a download shelf) is wrongly
//   counted as top chrome. Horizontal chrome (Arc's sidebar, Chrome's side panel,
//   DevTools docked left/right) is tried on the left and then on the right, and
//   the AX hint picks the one that finds matching text. Pinch zoom and iframes are
//   not handled: only the top document is inspected.

function inspectPage(req) {
  const MAX_TEXT = 80;
  const INTERACTIVE_TAGS = new Set(["a", "button", "input", "select", "textarea", "summary", "option", "label", "details"]);
  const INTERACTIVE_ROLES = new Set(["button", "link", "checkbox", "radio", "tab", "menuitem", "menuitemcheckbox",
    "menuitemradio", "switch", "textbox", "combobox", "option", "slider", "searchbox", "spinbutton", "listbox", "treeitem"]);
  const MEDIA_TAGS = new Set(["img", "video", "canvas", "svg", "picture", "iframe"]);
  const TEST_ATTRS = ["data-testid", "data-test-id", "data-test", "data-cy", "data-qa"];
  const INTERACTIVE_SELECTOR = "a,button,input,select,textarea,summary,label,[role],[tabindex],[contenteditable],"
    + TEST_ATTRS.map(a => `[${a}]`).join(",");

  const win = window, doc = document;
  const vw = win.innerWidth, vh = win.innerHeight;
  // Page zoom: Chrome's devicePixelRatio is backingScale × zoom.
  const zoom = req.scale > 0 ? win.devicePixelRatio / req.scale : 1;
  const chromeTop = Math.max(0, win.outerHeight - vh * zoom);
  const chromeSide = Math.max(0, win.outerWidth - vw * zoom);
  const hintText = quoted(req.hint);

  // ---- helpers ----------------------------------------------------------

  function quoted(hint) {
    if (!hint) return null;
    const m = /[“"']([^”"']{2,})[”"']/.exec(hint);
    return m ? m[1].trim().toLowerCase() : null;
  }

  function clean(s, max = MAX_TEXT) {
    if (!s) return "";
    s = String(s).replace(/\s+/g, " ").trim();
    return s.length > max ? s.slice(0, max - 1) + "…" : s;
  }

  function isGeneratedClass(c) {
    // css-1a2b3c, sc-bdVaJa, _header_x7k2p, svelte-1abc, emotion-… are noise in a selector
    return /^(css|sc|jsx|svelte|emotion|chakra)-/i.test(c) || /\d{3,}|[0-9a-f]{5,}/i.test(c) || /^_|__/.test(c) || c.length > 40;
  }

  function stableClasses(el) {
    return Array.from(el.classList).filter(c => !isGeneratedClass(c));
  }

  function unique(sel) {
    try { return doc.querySelectorAll(sel).length === 1; } catch { return false; }
  }

  function testAttr(el) {
    for (const a of TEST_ATTRS) {
      const v = el.getAttribute(a);
      if (v) return { attr: a, value: v };
    }
    return null;
  }

  // A short selector that matches only this element, anchored at the nearest id or test id.
  function selectorFor(el) {
    const parts = [];
    let node = el;
    while (node && node.nodeType === 1 && node !== doc.documentElement && node !== doc.body && parts.length < 6) {
      if (node.id && !/\s/.test(node.id) && !/^\d/.test(node.id)) {
        parts.unshift("#" + CSS.escape(node.id));
        const sel = parts.join(" > ");
        if (unique(sel)) return sel;
        break;
      }
      const t = testAttr(node);
      if (t) {
        parts.unshift(`[${t.attr}="${t.value.replace(/["\\]/g, "\\$&")}"]`);
        const sel = parts.join(" > ");
        if (unique(sel)) return sel;
        break;
      }
      let seg = node.localName;
      const classes = stableClasses(node).slice(0, 2);
      if (classes.length) seg += "." + classes.map(CSS.escape).join(".");
      const parent = node.parentElement;
      if (parent) {
        const sameTag = Array.from(parent.children).filter(s => s.localName === node.localName);
        const sameSeg = sameTag.filter(s => classes.every(c => s.classList.contains(c)));
        if (sameSeg.length > 1) seg += `:nth-of-type(${sameTag.indexOf(node) + 1})`;
      }
      parts.unshift(seg);
      const sel = parts.join(" > ");
      if (unique(sel)) return sel;
      node = parent;
    }
    return parts.join(" > ");
  }

  function implicitRole(el) {
    const tag = el.localName;
    if (tag === "a") return el.hasAttribute("href") ? "link" : null;
    if (tag === "button" || tag === "summary") return "button";
    if (tag === "input") {
      const type = (el.getAttribute("type") || "text").toLowerCase();
      if (type === "checkbox" || type === "radio") return type;
      if (["button", "submit", "reset", "image"].includes(type)) return "button";
      if (type === "range") return "slider";
      if (["hidden", "file", "color", "date", "time", "datetime-local", "month", "week"].includes(type)) return null;
      return type === "search" ? "searchbox" : "textbox";
    }
    if (tag === "select") return "combobox";
    if (tag === "textarea") return "textbox";
    if (tag === "img") return "img";
    if (/^h[1-6]$/.test(tag)) return "heading";
    if (tag === "nav") return "navigation";
    if (tag === "li") return "listitem";
    if (tag === "option") return "option";
    return null;
  }

  function isInteractive(el, role) {
    if (INTERACTIVE_TAGS.has(el.localName)) return true;
    if (role && INTERACTIVE_ROLES.has(role)) return true;
    if (el.hasAttribute("contenteditable") && el.getAttribute("contenteditable") !== "false") return true;
    const tabindex = el.getAttribute("tabindex");
    return tabindex !== null && Number(tabindex) >= 0;
  }

  function textOf(el) {
    const tag = el.localName;
    if (tag === "input" || tag === "textarea") {
      // Never the value — it may be private. The placeholder says what the field is for.
      return clean(el.getAttribute("placeholder") || el.getAttribute("aria-label") || "");
    }
    if (tag === "img") return clean(el.getAttribute("alt") || "");
    if (tag === "select") return clean(el.selectedOptions && el.selectedOptions[0] ? el.selectedOptions[0].textContent : "");
    return clean(el.innerText != null ? el.innerText : el.textContent);
  }

  // ---- framework hints ----------------------------------------------------

  function shortFile(file) {
    if (!file) return null;
    file = String(file).replace(/^webpack-internal:\/\/\/\.?\/?/, "").replace(/^file:\/\//, "");
    try { if (/^https?:\/\//.test(file)) file = new URL(file).pathname; } catch {}
    file = file.replace(/^\/@fs\//, "/").replace(/\?.*$/, "");
    // Keep it relative to the project where we can: src/… first, then other common roots.
    for (const roots of ["src", "app|pages|components|lib|packages|apps"]) {
      const m = new RegExp(`(?:^|/)((?:${roots})/.*)$`).exec(file);
      if (m) return m[1];
    }
    return file.replace(/^\.?\//, "");
  }

  function reactTypeName(type) {
    if (!type) return null;
    if (typeof type === "function") return type.displayName || type.name || null;
    if (typeof type === "object") {
      // forwardRef / memo wrap the real component; providers, contexts, lazy, fragments aren't named
      if (type.displayName) return type.displayName;
      if (typeof type.render === "function") return type.render.displayName || type.render.name || null;
      if (type.type) return reactTypeName(type.type);
    }
    return null;
  }

  function sourceFromStack(stack) {
    if (!stack) return null;
    for (const line of String(stack).split("\n")) {
      if (/node_modules|react-dom|react-refresh|\/react\.|scheduler|chunk-|@vite|webpack\/runtime/.test(line)) continue;
      const m = /((?:[a-z]+:\/\/|\/)[^\s()]+?\.(?:[jt]sx?|mjs|cjs|vue|svelte))(?:\?[^:\s]*)?:(\d+)(?::\d+)?/i.exec(line);
      if (m) return shortFile(m[1]) + ":" + m[2];
    }
    return null;
  }

  function reactInfo(el) {
    const key = Object.keys(el).find(k => k.startsWith("__reactFiber$") || k.startsWith("__reactInternalInstance$"));
    if (!key) return null;
    const info = { framework: "React" };
    const names = [];
    let fiber = el[key], hops = 0;
    while (fiber && hops++ < 60 && names.length < 3) {
      const name = typeof fiber.type === "string" ? null : reactTypeName(fiber.type);
      if (name && name !== "Anonymous" && !/^(Fragment|Suspense|Provider|Consumer|Context|StrictMode|Profiler)$/.test(name)) {
        if (names.length === 0) {
          // _debugSource: React ≤18 dev builds. _debugStack: React 19 dev builds (an Error whose stack has the JSX call site).
          const src = fiber._debugSource;
          let source = null;
          if (src && src.fileName) source = shortFile(src.fileName) + (src.lineNumber ? ":" + src.lineNumber : "");
          else if (fiber._debugStack) source = sourceFromStack(fiber._debugStack.stack || fiber._debugStack);
          else if (fiber._debugOwner && fiber._debugOwner._debugStack) source = sourceFromStack(fiber._debugOwner._debugStack.stack);
          if (source) info.source = source;
        }
        names.push(name);
      }
      fiber = fiber.return;
    }
    if (names.length) {
      info.component = names[0];
      if (names.length > 1) info.parents = names.slice(1);
    }
    return info;
  }

  function baseName(file) {
    return String(file).split(/[\\/]/).pop().replace(/\.\w+$/, "");
  }

  function vueInfo(el) {
    let instance = el.__vueParentComponent; // Vue 3
    if (instance) {
      const info = { framework: "Vue" };
      const names = [];
      let hops = 0;
      while (instance && hops++ < 40 && names.length < 3) {
        const type = instance.type || {};
        const name = type.name || type.__name || (type.__file ? baseName(type.__file) : null);
        if (name) {
          if (names.length === 0 && type.__file) info.source = shortFile(type.__file);
          names.push(name);
        }
        instance = instance.parent;
      }
      if (names.length) { info.component = names[0]; if (names.length > 1) info.parents = names.slice(1); }
      return info;
    }
    const vm = el.__vue__; // Vue 2
    if (vm && vm.$options) {
      const info = { framework: "Vue" };
      const o = vm.$options;
      const name = o.name || o._componentTag || (o.__file ? baseName(o.__file) : null);
      if (name) info.component = name;
      if (o.__file) info.source = shortFile(o.__file);
      return info;
    }
    return null;
  }

  function svelteInfo(el) {
    const meta = el.__svelte_meta;
    if (!meta) return null;
    const info = { framework: "Svelte" };
    if (meta.loc && meta.loc.file) {
      info.source = shortFile(meta.loc.file) + (meta.loc.line ? ":" + meta.loc.line : "");
      info.component = baseName(meta.loc.file);
    }
    return info;
  }

  function angularInfo(el) {
    const ng = win.ng;
    if (!ng || typeof ng.getComponent !== "function" || !("__ngContext__" in el)) return null;
    const info = { framework: "Angular" };
    try {
      const own = ng.getComponent(el) || (ng.getOwningComponent && ng.getOwningComponent(el));
      if (own && own.constructor) info.component = own.constructor.name;
    } catch {}
    return info;
  }

  function frameworkInfo(el) {
    // The fiber/instance usually hangs off the element itself, but text wrappers
    // and SVG children sometimes carry nothing, so look a few levels up.
    let node = el, hops = 0;
    while (node && node.nodeType === 1 && hops++ < 4) {
      const info = reactInfo(node) || vueInfo(node) || svelteInfo(node) || angularInfo(node);
      if (info) return info;
      node = node.parentElement;
    }
    return null;
  }

  // ---- describe one element ------------------------------------------------

  function describe(el, drawn) {
    const r = el.getBoundingClientRect();
    const explicitRole = el.getAttribute("role");
    const role = explicitRole || implicitRole(el);
    const t = testAttr(el);
    const out = {
      tag: el.localName,
      rect: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)],
      interactive: isInteractive(el, role),
    };
    if (el.id) out.id = el.id;
    const classes = Array.from(el.classList).slice(0, 8).map(c => clean(c, 40));
    if (classes.length) out.classes = classes;
    out.selector = selectorFor(el);
    if (t) { out.testId = t.value; out.testAttr = t.attr; }
    if (explicitRole) out.role = explicitRole;
    const aria = el.getAttribute("aria-label");
    if (aria) out.ariaLabel = clean(aria);
    const text = textOf(el);
    if (text) out.text = text;
    if (el.localName === "a" && el.getAttribute("href")) out.href = clean(el.getAttribute("href"), 120);
    if (["input", "select", "textarea", "button"].includes(el.localName)) {
      const name = el.getAttribute("name"); if (name) out.name = clean(name, 60);
      const type = el.getAttribute("type"); if (type) out.type = type;
    }
    const fw = frameworkInfo(el);
    if (fw) Object.assign(out, fw);
    // How much of the element the drawing covers, for ranking.
    const ix = Math.max(0, Math.min(r.right, drawn.right) - Math.max(r.left, drawn.left));
    const iy = Math.max(0, Math.min(r.bottom, drawn.bottom) - Math.max(r.top, drawn.top));
    out.covered = r.width * r.height > 0 ? Math.round(100 * ix * iy / (r.width * r.height)) / 100 : 0;
    return out;
  }

  // ---- sample the drawn area -----------------------------------------------

  function collect(chromeLeft) {
    const left = (req.screen.x - win.screenX - chromeLeft) / zoom;
    const top = (req.screen.y - win.screenY - chromeTop) / zoom;
    const width = req.screen.w / zoom, height = req.screen.h / zoom;
    const drawn = { left, top, right: left + width, bottom: top + height };
    const x0 = Math.max(0, left), y0 = Math.max(0, top);
    const x1 = Math.min(vw, left + width), y1 = Math.min(vh, top + height);
    if (x1 <= x0 || y1 <= y0) return { elements: [], drawn, outside: true };

    // elementsFromPoint is cheap, so sample densely enough to catch a one-line heading or a text field.
    const cols = Math.max(2, Math.min(14, Math.round((x1 - x0) / 16)));
    const rows = Math.max(2, Math.min(14, Math.round((y1 - y0) / 16)));
    const drawnArea = Math.max(1, width * height);
    const found = new Set();

    function consider(el) {
      if (!el || el === doc.documentElement || el === doc.body || found.has(el) || found.size >= 24) return;
      const r = el.getBoundingClientRect();
      const area = r.width * r.height;
      const role = el.getAttribute("role") || implicitRole(el);
      // A wrapper much bigger than the drawing isn't what you drew around (the page's main column,
      // say). A card the size of the drawing is, even when it's big.
      if (!isInteractive(el, role) && !MEDIA_TAGS.has(el.localName) && area > drawnArea * 4) return;
      found.add(el);
    }

    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const x = x0 + (x1 - x0) * (c + 0.5) / cols;
        const y = y0 + (y1 - y0) * (r + 0.5) / rows;
        const stack = doc.elementsFromPoint(x, y);
        if (!stack.length) continue;
        const hit = stack[0];
        consider(hit);
        // The thing you meant is often the link/button/test-id'd wrapper around the text you hit.
        const owner = hit.closest ? hit.closest(INTERACTIVE_SELECTOR) : null;
        if (owner && owner !== hit) {
          let depth = 0, n = hit;
          while (n && n !== owner && depth < 6) { n = n.parentElement; depth++; }
          if (n === owner) consider(owner);
        }
        // A transparent overlay (modal backdrop, drag layer) hides what's under it; peek one layer down.
        if (stack.length > 1 && !hit.id && !hit.classList.length && !(hit.textContent || "").trim()) consider(stack[1]);
      }
    }

    const elements = Array.from(found).map(el => describe(el, drawn));
    const interactive = elements.filter(e => e.interactive);
    const rest = elements.filter(e => !e.interactive);
    const rank = (a, b) => (b.covered - a.covered) || ((b.testId ? 1 : 0) - (a.testId ? 1 : 0));
    interactive.sort(rank);
    rest.sort(rank);
    const picked = interactive.slice(0, 8).concat(rest.slice(0, Math.max(0, 10 - Math.min(interactive.length, 8))));
    return { elements: picked, drawn };
  }

  function matchesHint(elements) {
    if (!hintText) return false;
    return elements.some(e => (e.text && e.text.toLowerCase().includes(hintText))
      || (e.ariaLabel && e.ariaLabel.toLowerCase().includes(hintText)));
  }

  // Side chrome (Arc's sidebar, DevTools docked left) is usually on the left; try that first,
  // then no offset (Chrome's side panel / DevTools on the right). The AX hint breaks ties.
  const candidates = chromeSide > 8 ? [chromeSide, 0] : [0];
  let result = null, chromeLeft = candidates[0];
  for (const c of candidates) {
    const attempt = collect(c);
    if (!result || (attempt.elements.length && !result.elements.length)) { result = attempt; chromeLeft = c; }
    if (matchesHint(attempt.elements)) { result = attempt; chromeLeft = c; break; }
  }

  const out = {
    url: location.href,
    elements: result.elements,
    viewport: {
      w: vw, h: vh, zoom: Math.round(zoom * 100) / 100, dpr: win.devicePixelRatio,
      chromeTop: Math.round(chromeTop), chromeLeft: Math.round(chromeLeft),
      drawn: [Math.round(result.drawn.left), Math.round(result.drawn.top),
              Math.round(result.drawn.right - result.drawn.left), Math.round(result.drawn.bottom - result.drawn.top)],
    },
  };
  const title = clean(doc.title, 120);
  if (title) out.title = title;
  if (result.outside) out.outside = true;
  return out;
}
