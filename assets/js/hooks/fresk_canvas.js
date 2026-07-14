// FreskCanvas: renders the fresk display image with card/section/arrow overlays
// from server state, and lets the reviewer pan/zoom, select, move, resize, draw
// and link. All annotation coordinates are normalized (0..1) against the image;
// this hook maps them to image pixels and back.
//
// Server -> hook events:  "canvas:set" {image_url, annotations, links, image}
//                         "canvas:mode" {mode}   ("select" | "card" | "section" | "link")
// hook -> server events:  "canvas:select" {id|null, kind}
//                         "annotation:move" {id, x1,y1,x2,y2}
//                         "annotation:create" {type, x1,y1,x2,y2}
//                         "link:create" {source_id, target_id}
//                         "annotation:delete" {id}   (Delete/Backspace on selection)

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
    this.selectedId = null;
    this.drag = null;

    this.handleEvent("canvas:set", (payload) => this.setData(payload));
    this.handleEvent("canvas:mode", ({ mode }) => {
      this.mode = mode;
      this.render();
    });
    this.handleEvent("canvas:focus", ({ id }) => {
      this.selectedId = id;
      const a = this.state.annotations.find((x) => x.id === id);
      if (a) this.centerOn(a);
      this.render();
    });

    this.ro = new ResizeObserver(() => this.resizeCanvas());
    this.ro.observe(this.el);

    this.bind();
    this.resizeCanvas();
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

    this.drawLinks();
    for (const a of this.state.annotations) this.drawBox(a);
    if (this.drag && this.drag.type === "create") this.drawDraft();
  },

  center(a) {
    const b = this.boxPx(a);
    return this.toScreen((b.x1 + b.x2) / 2, (b.y1 + b.y2) / 2);
  },

  drawLinks() {
    const ctx = this.ctx;
    const byId = Object.fromEntries(this.state.annotations.map((a) => [a.id, a]));
    for (const l of this.state.links) {
      const s = byId[l.source_id], t = byId[l.target_id];
      if (!s || !t) continue;
      const [x1, y1] = this.center(s);
      const [x2, y2] = this.center(t);
      ctx.save();
      ctx.strokeStyle = norm(l.color, "#111827");
      ctx.lineWidth = 2;
      ctx.setLineDash(l.line_style === "dashed" ? [7, 5] : []);
      ctx.beginPath();
      ctx.moveTo(x1, y1);
      ctx.lineTo(x2, y2);
      ctx.stroke();
      this.arrowHead(x1, y1, x2, y2, ctx.strokeStyle);
      ctx.restore();
    }
  },

  arrowHead(x1, y1, x2, y2, color) {
    const ctx = this.ctx;
    const a = Math.atan2(y2 - y1, x2 - x1);
    const L = 10;
    ctx.save();
    ctx.setLineDash([]);
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.moveTo(x2, y2);
    ctx.lineTo(x2 - L * Math.cos(a - 0.4), y2 - L * Math.sin(a - 0.4));
    ctx.lineTo(x2 - L * Math.cos(a + 0.4), y2 - L * Math.sin(a + 0.4));
    ctx.closePath();
    ctx.fill();
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
    if ((a.confidence != null && a.confidence < 0.5) || a.status === "pending") {
      // low-confidence marker
      ctx.setLineDash([]);
      ctx.fillStyle = "#f59e0b";
      ctx.beginPath();
      ctx.arc(sx1 + 6, sy1 + 6, 3, 0, Math.PI * 2);
      ctx.fill();
    }
    if (selected) this.drawHandles(sx1, sy1, sx2, sy2);
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

  hitBox(sx, sy) {
    const [ix, iy] = this.toImage(sx, sy);
    // Prefer cards over sections, and topmost small boxes.
    const hits = this.state.annotations.filter((a) => {
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

      if (this.mode === "card" || this.mode === "section") {
        const [ix, iy] = this.toImage(sx, sy);
        this.drag = { type: "create", x1: ix, y1: iy, x2: ix, y2: iy };
        return;
      }
      if (this.mode === "link") {
        const hit = this.hitBox(sx, sy);
        if (hit) this.drag = { type: "link", source: hit.id, sx, sy };
        return;
      }
      // select mode: handle > box > pan
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
      } else {
        this.select(null);
        this.drag = { type: "pan", sx, sy, ox: this.view.x, oy: this.view.y };
      }
    });

    window.addEventListener("mousemove", (e) => {
      if (!this.drag) return;
      const [sx, sy] = pos(e);
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
        d.sx = sx; d.sy = sy; d.hover = this.hitBox(sx, sy);
      }
      this.render();
      if (d.type === "link" && d.sx != null) {
        const s = this.state.annotations.find((a) => a.id === d.source);
        if (s) {
          const [cx, cy] = this.center(s);
          this.ctx.save(); this.ctx.strokeStyle = "#111827"; this.ctx.setLineDash([4, 3]);
          this.ctx.beginPath(); this.ctx.moveTo(cx, cy); this.ctx.lineTo(d.sx, d.sy); this.ctx.stroke();
          this.ctx.restore();
        }
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
        const hit = this.hitBox(sx, sy);
        if (hit && hit.id !== d.source) {
          this.pushEvent("link:create", { source_id: d.source, target_id: hit.id });
        }
      }
      this.render();
    });

    this.el.addEventListener("keydown", (e) => {
      if ((e.key === "Delete" || e.key === "Backspace") && this.selectedId != null) {
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
    this.pushEvent("canvas:select", a ? { id: a.id, kind: a.type } : { id: null });
    this.render();
  },
};

export default FreskCanvas;
