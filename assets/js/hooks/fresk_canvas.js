// FreskCanvas: renders the fresk display image with card/section/arrow overlays
// from server state, and lets the reviewer pan/zoom, select, move, resize, draw
// and link. All annotation coordinates are normalized (0..1) against the image;
// this hook maps them to image pixels and back.
//
// Server -> hook events:  "canvas:set" {image_url, annotations, links, image}
//                         "canvas:mode" {mode}   ("select" | "card" | "section" | "link")
//                         "canvas:layers" {cards, sections, arrows}  (bool per layer)
//                         "canvas:link-endpoints" {from, to}  (type each new arrow end attaches to)
//                         "canvas:focus" {id}         (center + select an annotation)
//                         "canvas:focus-link" {id}    (center + select a link)
// hook -> server events:  "canvas:select" {id|null, kind}
//                         "link:select" {id}
//                         "annotation:move" {id, x1,y1,x2,y2}
//                         "annotation:create" {type, x1,y1,x2,y2}
//                         "link:create" {source_id, target_id}
//                         "annotation:delete" {id}   (Delete/Backspace on selected box)
//                         "link:delete" {id}         (Delete/Backspace on selected arrow)

const HANDLE = 8; // px, resize-handle hit size (screen space)

function norm(hex, fallback) {
  return hex && /^#[0-9a-fA-F]{6}$/.test(hex) ? hex : fallback;
}

const FreskCanvas = {
  mounted() {
    this.canvas = this.el.querySelector("canvas");
    this.ctx = this.canvas.getContext("2d");
    this.state = { annotations: [], links: [], image: null, img: null };
    this.view = { scale: 1, x: 0, y: 0, fitted: false };
    this.mode = "select";
    this.layers = { cards: true, sections: true, arrows: true };
    this.linkFrom = "card"; // which type a new arrow's tail attaches to
    this.linkTo = "card"; //   which type a new arrow's head attaches to
    this.linkSource = null; // pending tail box id while click-to-link is in progress
    this.selectedId = null;
    this.selectedLinkId = null;
    this.drag = null;

    this.handleEvent("canvas:set", (payload) => this.setData(payload));
    this.handleEvent("canvas:mode", ({ mode }) => {
      this.mode = mode;
      this.linkSource = null;
      this.updateCursor();
      this.render();
    });
    this.handleEvent("canvas:layers", (layers) => {
      this.layers = { ...this.layers, ...layers };
      this.render();
    });
    this.handleEvent("canvas:link-endpoints", ({ from, to }) => {
      if (from) this.linkFrom = from;
      if (to) this.linkTo = to;
    });
    this.handleEvent("canvas:focus", ({ id }) => {
      this.selectedId = id;
      this.selectedLinkId = null;
      const a = this.state.annotations.find((x) => x.id === id);
      if (a) this.centerOn(a);
      this.render();
    });
    this.handleEvent("canvas:focus-link", ({ id }) => {
      this.selectedLinkId = id;
      this.selectedId = null;
      const l = this.state.links.find((x) => x.id === id);
      const byId = Object.fromEntries(this.state.annotations.map((a) => [a.id, a]));
      const s = l && byId[l.source_id];
      const t = l && byId[l.target_id];
      if (s && t) {
        this.centerOn({
          x1: (Math.min(s.x1, s.x2) + Math.min(t.x1, t.x2)) / 2,
          y1: (Math.min(s.y1, s.y2) + Math.min(t.y1, t.y2)) / 2,
          x2: (Math.max(s.x1, s.x2) + Math.max(t.x1, t.x2)) / 2,
          y2: (Math.max(s.y1, s.y2) + Math.max(t.y1, t.y2)) / 2,
        });
      }
      this.render();
    });

    this.ro = new ResizeObserver(() => this.resizeCanvas());
    this.ro.observe(this.el);

    this.bind();
    this.resizeCanvas();
    this.updateCursor();
  },

  updateCursor() {
    const c = { pan: "grab", card: "crosshair", section: "crosshair", link: "crosshair" };
    this.canvas.style.cursor = c[this.mode] || "default";
  },

  destroyed() {
    this.ro && this.ro.disconnect();
  },

  setData({ image_url, annotations, links, image }) {
    this.state.annotations = annotations || [];
    this.state.links = links || [];
    this.state.image = image;
    if (image_url && (!this.state.img || this.state.imgUrl !== image_url)) {
      this.state.imgUrl = image_url;
      const img = new Image();
      img.onload = () => {
        this.state.img = img;
        this.fit();
        this.render();
      };
      img.src = image_url;
    } else {
      this.render();
    }
  },

  // --- coordinate helpers (image px <-> screen px) ---
  imgW() { return this.state.img ? this.state.img.width : (this.state.image?.width || 1); },
  imgH() { return this.state.img ? this.state.img.height : (this.state.image?.height || 1); },
  toScreen(ix, iy) { return [ix * this.view.scale + this.view.x, iy * this.view.scale + this.view.y]; },
  toImage(sx, sy) { return [(sx - this.view.x) / this.view.scale, (sy - this.view.y) / this.view.scale]; },
  boxPx(a) {
    const W = this.imgW(), H = this.imgH();
    return { x1: Math.min(a.x1, a.x2) * W, y1: Math.min(a.y1, a.y2) * H,
             x2: Math.max(a.x1, a.x2) * W, y2: Math.max(a.y1, a.y2) * H };
  },

  centerOn(a) {
    const b = this.boxPx(a);
    const r = this.el.getBoundingClientRect();
    const cx = (b.x1 + b.x2) / 2, cy = (b.y1 + b.y2) / 2;
    this.view.x = r.width / 2 - cx * this.view.scale;
    this.view.y = r.height / 2 - cy * this.view.scale;
  },

  fit() {
    if (!this.state.img) return;
    const r = this.el.getBoundingClientRect();
    const s = Math.min(r.width / this.imgW(), r.height / this.imgH()) * 0.98;
    this.view.scale = s;
    this.view.x = (r.width - this.imgW() * s) / 2;
    this.view.y = (r.height - this.imgH() * s) / 2;
    this.view.fitted = true;
  },

  resizeCanvas() {
    const r = this.el.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    this.canvas.width = r.width * dpr;
    this.canvas.height = r.height * dpr;
    this.canvas.style.width = r.width + "px";
    this.canvas.style.height = r.height + "px";
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (!this.view.fitted) this.fit();
    this.render();
  },

  // --- rendering ---
  render() {
    const ctx = this.ctx;
    const r = this.el.getBoundingClientRect();
    ctx.clearRect(0, 0, r.width, r.height);
    if (this.state.img) ctx.drawImage(this.state.img, this.view.x, this.view.y,
      this.imgW() * this.view.scale, this.imgH() * this.view.scale);

    if (this.layers.arrows) this.drawLinks();
    for (const a of this.state.annotations) if (this.visible(a)) this.drawBox(a);
    if (this.drag && this.drag.type === "create") this.drawDraft();
  },

  visible(a) {
    return a.type === "section" ? this.layers.sections : this.layers.cards;
  },

  center(a) {
    const b = this.boxPx(a);
    return this.toScreen((b.x1 + b.x2) / 2, (b.y1 + b.y2) / 2);
  },

  annMap() {
    return Object.fromEntries(this.state.annotations.map((a) => [a.id, a]));
  },

  screenBox(a) {
    const b = this.boxPx(a);
    const [x1, y1] = this.toScreen(b.x1, b.y1);
    const [x2, y2] = this.toScreen(b.x2, b.y2);
    return { x1, y1, x2, y2 };
  },

  // Point on a box's border along the ray from its center toward (tx,ty).
  edgePoint(box, tx, ty) {
    const cx = (box.x1 + box.x2) / 2, cy = (box.y1 + box.y2) / 2;
    const dx = tx - cx, dy = ty - cy;
    if (dx === 0 && dy === 0) return [cx, cy];
    const hw = Math.max((box.x2 - box.x1) / 2, 1), hh = Math.max((box.y2 - box.y1) / 2, 1);
    const scale = 1 / Math.max(Math.abs(dx) / hw, Math.abs(dy) / hh);
    return [cx + dx * scale, cy + dy * scale];
  },

  // Screen-space segment for a link, clipped to each endpoint box's border.
  linkSegment(l, byId = this.annMap()) {
    const s = byId[l.source_id], t = byId[l.target_id];
    if (!s || !t) return null;
    const sb = this.screenBox(s), tb = this.screenBox(t);
    const sc = [(sb.x1 + sb.x2) / 2, (sb.y1 + sb.y2) / 2];
    const tc = [(tb.x1 + tb.x2) / 2, (tb.y1 + tb.y2) / 2];
    const [x1, y1] = this.edgePoint(sb, tc[0], tc[1]);
    const [x2, y2] = this.edgePoint(tb, sc[0], sc[1]);
    return { x1, y1, x2, y2 };
  },

  drawLinks() {
    const ctx = this.ctx;
    const byId = this.annMap();
    for (const l of this.state.links) {
      const seg = this.linkSegment(l, byId);
      if (!seg) continue;
      const { x1, y1, x2, y2 } = seg;
      const color = norm(l.color, "#111827");
      const dashed = l.line_style === "dashed";
      const selected = l.id === this.selectedLinkId;
      const dash = dashed ? [9, 6] : [];

      ctx.save();
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      // contrast casing (same dash pattern so gaps stay clear)
      ctx.setLineDash(dash);
      ctx.strokeStyle = selected ? "#111827" : "rgba(255,255,255,0.9)";
      ctx.lineWidth = selected ? 6 : 4;
      ctx.beginPath();
      ctx.moveTo(x1, y1);
      ctx.lineTo(x2, y2);
      ctx.stroke();
      // colored line on top
      ctx.strokeStyle = color;
      ctx.lineWidth = selected ? 3.5 : 2;
      ctx.setLineDash(dash);
      ctx.beginPath();
      ctx.moveTo(x1, y1);
      ctx.lineTo(x2, y2);
      ctx.stroke();
      this.arrowHead(x1, y1, x2, y2, color, selected);
      ctx.restore();
    }
  },

  arrowHead(x1, y1, x2, y2, color, selected) {
    const ctx = this.ctx;
    const a = Math.atan2(y2 - y1, x2 - x1);
    const L = selected ? 14 : 11;
    const spread = 0.42;
    const wing = (len) => {
      ctx.beginPath();
      ctx.moveTo(x2, y2);
      ctx.lineTo(x2 - len * Math.cos(a - spread), y2 - len * Math.sin(a - spread));
      ctx.lineTo(x2 - len * Math.cos(a + spread), y2 - len * Math.sin(a + spread));
      ctx.closePath();
      ctx.fill();
    };
    ctx.save();
    ctx.setLineDash([]);
    ctx.fillStyle = selected ? "#111827" : "rgba(255,255,255,0.9)"; // casing
    wing(L + 3);
    ctx.fillStyle = color; // colored head
    wing(L);
    ctx.restore();
  },

  drawBox(a) {
    const ctx = this.ctx;
    const b = this.boxPx(a);
    const [sx1, sy1] = this.toScreen(b.x1, b.y1);
    const [sx2, sy2] = this.toScreen(b.x2, b.y2);
    const w = sx2 - sx1, h = sy2 - sy1;
    const selected = a.id === this.selectedId;
    const section = a.type === "section";
    const color = norm(a.color, section ? "#6b7280" : "#2563eb");

    ctx.save();
    if (section) {
      ctx.setLineDash([6, 4]);
      ctx.lineWidth = selected ? 3 : 2;
      ctx.strokeStyle = selected ? "#111827" : "#6b7280";
      ctx.strokeRect(sx1, sy1, w, h);
    } else {
      ctx.fillStyle = color + "33"; // translucent fill
      ctx.fillRect(sx1, sy1, w, h);
      ctx.setLineDash([]);
      ctx.lineWidth = selected ? 3 : 1.5;
      ctx.strokeStyle = selected ? "#111827" : color;
      ctx.strokeRect(sx1, sy1, w, h);
    }
    // status marker: green when validated, amber when pending / low-confidence
    ctx.setLineDash([]);
    if (a.status === "validated") {
      ctx.fillStyle = "#16a34a";
      ctx.beginPath();
      ctx.arc(sx1 + 6, sy1 + 6, 3.5, 0, Math.PI * 2);
      ctx.fill();
    } else if ((a.confidence != null && a.confidence < 0.5) || a.status === "pending") {
      ctx.fillStyle = "#f59e0b";
      ctx.beginPath();
      ctx.arc(sx1 + 6, sy1 + 6, 3, 0, Math.PI * 2);
      ctx.fill();
    }
    if (a.id === this.linkSource) {
      // pending tail of a click-to-link in progress
      ctx.setLineDash([]);
      ctx.strokeStyle = "#2563eb";
      ctx.lineWidth = 3;
      ctx.strokeRect(sx1 - 2, sy1 - 2, w + 4, h + 4);
    }
    if (selected) this.drawHandles(sx1, sy1, sx2, sy2);
    if (selected && a.title) this.drawLabel(a.title, sx1, sy1);
    ctx.restore();
  },

  drawLabel(text, x, y) {
    const ctx = this.ctx;
    ctx.save();
    ctx.setLineDash([]);
    ctx.font = "600 12px ui-sans-serif, system-ui, -apple-system, sans-serif";
    ctx.textBaseline = "top";
    const pad = 3;
    const tw = ctx.measureText(text).width;
    const bh = 16;
    let ly = y - bh - 3;
    if (ly < 2) ly = y + 3; // keep it on-screen when the box hugs the top
    ctx.fillStyle = "rgba(17,24,39,0.92)";
    ctx.fillRect(x, ly, tw + pad * 2, bh);
    ctx.fillStyle = "#ffffff";
    ctx.fillText(text, x + pad, ly + 2);
    ctx.restore();
  },

  handlePoints(sx1, sy1, sx2, sy2) {
    return {
      nw: [sx1, sy1], ne: [sx2, sy1], sw: [sx1, sy2], se: [sx2, sy2],
    };
  },

  drawHandles(sx1, sy1, sx2, sy2) {
    const ctx = this.ctx;
    ctx.setLineDash([]);
    ctx.fillStyle = "#ffffff";
    ctx.strokeStyle = "#111827";
    ctx.lineWidth = 1;
    for (const [x, y] of Object.values(this.handlePoints(sx1, sy1, sx2, sy2))) {
      ctx.fillRect(x - HANDLE / 2, y - HANDLE / 2, HANDLE, HANDLE);
      ctx.strokeRect(x - HANDLE / 2, y - HANDLE / 2, HANDLE, HANDLE);
    }
  },

  drawDraft() {
    const ctx = this.ctx;
    const { x1, y1, x2, y2 } = this.drag;
    const [ax, ay] = this.toScreen(x1, y1);
    const [bx, by] = this.toScreen(x2, y2);
    ctx.save();
    ctx.setLineDash([4, 3]);
    ctx.strokeStyle = "#111827";
    ctx.lineWidth = 1.5;
    ctx.strokeRect(ax, ay, bx - ax, by - ay);
    ctx.restore();
  },

  drawRubber(from, sx, sy) {
    if (sx == null || sy == null) return;
    const ctx = this.ctx;
    ctx.save();
    ctx.strokeStyle = "#2563eb";
    ctx.setLineDash([5, 4]);
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(from[0], from[1]);
    ctx.lineTo(sx, sy);
    ctx.stroke();
    ctx.restore();
  },

  // --- hit testing ---
  hitHandle(a, sx, sy) {
    if (a.id !== this.selectedId) return null;
    const b = this.boxPx(a);
    const [x1, y1] = this.toScreen(b.x1, b.y1);
    const [x2, y2] = this.toScreen(b.x2, b.y2);
    for (const [name, [hx, hy]] of Object.entries(this.handlePoints(x1, y1, x2, y2))) {
      if (Math.abs(sx - hx) <= HANDLE && Math.abs(sy - hy) <= HANDLE) return name;
    }
    return null;
  },

  // preferType ("card"|"section") restricts the hit to that type — used when
  // drawing a link so the endpoint attaches to the chosen kind even where a
  // card sits inside a section. Without it, prefer cards then smallest box.
  hitBox(sx, sy, preferType = null) {
    const [ix, iy] = this.toImage(sx, sy);
    const hits = this.state.annotations.filter((a) => {
      if (!this.visible(a)) return false;
      if (preferType && a.type !== preferType) return false;
      const b = this.boxPx(a);
      return ix >= b.x1 && ix <= b.x2 && iy >= b.y1 && iy <= b.y2;
    });
    hits.sort((a, b) => {
      if (a.type !== b.type) return a.type === "card" ? -1 : 1;
      return this.area(a) - this.area(b);
    });
    return hits[0] || null;
  },

  area(a) {
    const b = this.boxPx(a);
    return (b.x2 - b.x1) * (b.y2 - b.y1);
  },

  hitLink(sx, sy) {
    if (!this.layers.arrows) return null;
    const byId = this.annMap();
    let best = null, bestD = 8;
    for (const l of this.state.links) {
      const seg = this.linkSegment(l, byId);
      if (!seg) continue;
      const d = this.segDist(sx, sy, seg.x1, seg.y1, seg.x2, seg.y2);
      if (d < bestD) { bestD = d; best = l; }
    }
    return best;
  },

  segDist(px, py, x1, y1, x2, y2) {
    const dx = x2 - x1, dy = y2 - y1;
    const len2 = dx * dx + dy * dy;
    let t = len2 ? ((px - x1) * dx + (py - y1) * dy) / len2 : 0;
    t = Math.max(0, Math.min(1, t));
    return Math.hypot(px - (x1 + t * dx), py - (y1 + t * dy));
  },

  // --- interaction ---
  bind() {
    const pos = (e) => {
      const r = this.canvas.getBoundingClientRect();
      return [e.clientX - r.left, e.clientY - r.top];
    };

    this.canvas.addEventListener("wheel", (e) => {
      e.preventDefault();
      const [sx, sy] = pos(e);
      const [ix, iy] = this.toImage(sx, sy);
      const factor = Math.exp(-e.deltaY * 0.0015);
      this.view.scale = Math.max(0.05, Math.min(20, this.view.scale * factor));
      this.view.x = sx - ix * this.view.scale;
      this.view.y = sy - iy * this.view.scale;
      this.render();
    }, { passive: false });

    this.canvas.addEventListener("mousedown", (e) => {
      const [sx, sy] = pos(e);
      const sel = this.state.annotations.find((a) => a.id === this.selectedId);

      if (this.mode === "pan") {
        this.drag = { type: "pan", sx, sy, ox: this.view.x, oy: this.view.y };
        this.canvas.style.cursor = "grabbing";
        return;
      }
      if (this.mode === "card" || this.mode === "section") {
        const [ix, iy] = this.toImage(sx, sy);
        this.drag = { type: "create", x1: ix, y1: iy, x2: ix, y2: iy };
        return;
      }
      if (this.mode === "link") {
        // Decide on mouseup: a drag links press→release; a click picks the
        // tail, then the next click picks the head.
        this.drag = { type: "link", x0: sx, y0: sy, sx, sy, moved: false };
        return;
      }
      // select mode: handle > box > link > pan
      if (sel) {
        const handle = this.hitHandle(sel, sx, sy);
        if (handle) { this.drag = { type: "resize", handle, a: sel }; return; }
      }
      const hit = this.hitBox(sx, sy);
      if (hit) {
        this.select(hit);
        const b = this.boxPx(hit);
        const [ix, iy] = this.toImage(sx, sy);
        this.drag = { type: "move", a: hit, dx: ix - b.x1, dy: iy - b.y1, moved: false };
        return;
      }
      const link = this.hitLink(sx, sy);
      if (link) { this.selectLink(link); return; }
      this.select(null);
      this.drag = { type: "pan", sx, sy, ox: this.view.x, oy: this.view.y };
    });

    window.addEventListener("mousemove", (e) => {
      const [sx, sy] = pos(e);
      if (!this.drag) {
        // click-to-link in progress: rubber-band from the pending tail to cursor
        if (this.mode === "link" && this.linkSource != null) {
          const s = this.state.annotations.find((a) => a.id === this.linkSource);
          this.render();
          if (s) this.drawRubber(this.center(s), sx, sy);
        }
        return;
      }
      const [ix, iy] = this.toImage(sx, sy);
      const d = this.drag;
      if (d.type === "pan") {
        this.view.x = d.ox + (sx - d.sx);
        this.view.y = d.oy + (sy - d.sy);
      } else if (d.type === "create") {
        d.x2 = ix; d.y2 = iy;
      } else if (d.type === "move") {
        const W = this.imgW(), H = this.imgH();
        const w = (Math.max(d.a.x1, d.a.x2) - Math.min(d.a.x1, d.a.x2));
        const h = (Math.max(d.a.y1, d.a.y2) - Math.min(d.a.y1, d.a.y2));
        const nx = (ix - d.dx) / W, ny = (iy - d.dy) / H;
        d.a.x1 = nx; d.a.y1 = ny; d.a.x2 = nx + w; d.a.y2 = ny + h;
        d.moved = true;
      } else if (d.type === "resize") {
        this.applyResize(d.a, d.handle, ix, iy);
      } else if (d.type === "link") {
        d.sx = sx; d.sy = sy;
        if (Math.abs(sx - d.x0) > 4 || Math.abs(sy - d.y0) > 4) d.moved = true;
        d.hover = this.hitBox(sx, sy, this.linkTo);
      }
      this.render();
      if (d.type === "link") {
        const anchor =
          this.linkSource != null
            ? this.state.annotations.find((a) => a.id === this.linkSource)
            : this.hitBox(d.x0, d.y0, this.linkFrom);
        if (anchor) this.drawRubber(this.center(anchor), d.sx, d.sy);
      }
    });

    window.addEventListener("mouseup", (e) => {
      const d = this.drag;
      this.drag = null;
      if (!d) return;
      if (d.type === "create") {
        const x1 = Math.min(d.x1, d.x2) / this.imgW(), y1 = Math.min(d.y1, d.y2) / this.imgH();
        const x2 = Math.max(d.x1, d.x2) / this.imgW(), y2 = Math.max(d.y1, d.y2) / this.imgH();
        if ((x2 - x1) > 0.005 && (y2 - y1) > 0.005) {
          this.pushEvent("annotation:create", { type: this.mode, x1, y1, x2, y2 });
        }
      } else if (d.type === "move" && d.moved) {
        this.pushEvent("annotation:move", this.boxEvent(d.a));
      } else if (d.type === "resize") {
        this.pushEvent("annotation:move", this.boxEvent(d.a));
      } else if (d.type === "link") {
        const [sx, sy] = pos(e);
        if (this.linkSource != null) {
          // completing a click-to-link: tail is the pending box, head is here.
          // (Handles a jittery second click too — any release completes it.)
          const tgt = this.hitBox(sx, sy, this.linkTo);
          if (tgt && tgt.id !== this.linkSource) {
            this.pushEvent("link:create", { source_id: this.linkSource, target_id: tgt.id });
          }
          this.linkSource = null;
        } else if (d.moved) {
          // drag: tail = box under press, head = box under release
          const src = this.hitBox(d.x0, d.y0, this.linkFrom);
          const tgt = this.hitBox(sx, sy, this.linkTo);
          if (src && tgt && src.id !== tgt.id) {
            this.pushEvent("link:create", { source_id: src.id, target_id: tgt.id });
          }
        } else {
          // first click: pick the tail
          const src = this.hitBox(sx, sy, this.linkFrom);
          this.linkSource = src ? src.id : null;
        }
      }
      this.render();
      this.updateCursor();
    });

    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        if (this.linkSource != null) {
          this.linkSource = null;
          this.render();
        }
        return;
      }
      if (e.key !== "Delete" && e.key !== "Backspace") return;
      if (this.selectedLinkId != null) {
        e.preventDefault();
        this.pushEvent("link:delete", { id: this.selectedLinkId });
        this.selectedLinkId = null;
        this.render();
      } else if (this.selectedId != null) {
        e.preventDefault();
        this.pushEvent("annotation:delete", { id: this.selectedId });
        this.select(null);
      }
    });
    this.el.tabIndex = 0;
  },

  applyResize(a, handle, ix, iy) {
    const W = this.imgW(), H = this.imgH();
    const nx = ix / W, ny = iy / H;
    if (handle.includes("n")) a.y1 = ny;
    if (handle.includes("s")) a.y2 = ny;
    if (handle.includes("w")) a.x1 = nx;
    if (handle.includes("e")) a.x2 = nx;
  },

  boxEvent(a) {
    return {
      id: a.id,
      x1: Math.min(a.x1, a.x2), y1: Math.min(a.y1, a.y2),
      x2: Math.max(a.x1, a.x2), y2: Math.max(a.y1, a.y2),
    };
  },

  select(a) {
    this.selectedId = a ? a.id : null;
    this.selectedLinkId = null;
    this.pushEvent("canvas:select", a ? { id: a.id, kind: a.type } : { id: null });
    this.render();
  },

  selectLink(l) {
    this.selectedLinkId = l.id;
    this.selectedId = null;
    this.pushEvent("link:select", { id: l.id });
    this.render();
  },
};

export default FreskCanvas;
