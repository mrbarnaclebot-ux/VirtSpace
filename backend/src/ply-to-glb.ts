// PLY triangle mesh → glTF 2.0 binary (GLB), for the Echo-3 `mesh-simplified`
// collider (spec §5.3, R47). Reads ascii / binary_little_endian PLY, keeps only
// vertex x/y/z and face vertex-index lists (n-gons fan-triangulated), and writes
// one mesh: POSITION (float32 + min/max) and indices (uint16 when they fit).
//
// Frame decision (R47): the stored collider GLB is in exactly the stored
// splat.spz's frame — raw OpenCV RDF (+X right, +Y down, +Z forward), BEFORE the
// viewer's 180° X flip — so coordinates are copied verbatim and the viewer
// parents the collider under the splat's transform. Echo-3's raw SPZ is RDF and
// the mesh is extracted from it. Marble matches: World Labs worlds are "in
// OpenCV coordinate system (+y down, +z forward)" for splats and meshes alike.
// (Unverified until the first live run: SpAItial documents the mesh's frame
// nowhere. If its bounds match the floorplan's +Y-up `scene_bounds` rather than
// their Y/Z negation, negate y and z here to keep the splat frame.)

const TYPE_SIZE: Record<string, number> = {
  char: 1, int8: 1, uchar: 1, uint8: 1, short: 2, int16: 2, ushort: 2, uint16: 2,
  int: 4, int32: 4, uint: 4, uint32: 4, float: 4, float32: 4, double: 8, float64: 8,
};
const MAX_HEADER_BYTES = 64 * 1024;
// A "simplified" collider is far smaller; these just bound memory on bad input.
export const MAX_PLY_VERTICES = 10_000_000;
export const MAX_PLY_TRIANGLES = 20_000_000;

interface Prop {
  name: string;
  type: string;
  /** Set for `property list <countType> <type> <name>`. */
  countType?: string;
}
interface Element {
  name: string;
  count: number;
  props: Prop[];
}

function parseHeader(buf: Buffer): { ascii: boolean; elements: Element[]; bodyStart: number } {
  const head = buf.subarray(0, MAX_HEADER_BYTES).toString('latin1');
  const end = /(^|\n)end_header\r?\n/.exec(head);
  if (!head.startsWith('ply') || !end) throw new Error('not a PLY file (no ply/end_header)');
  const lines = head.slice(0, end.index).split(/\r?\n/).slice(1);
  let format: string | undefined;
  const elements: Element[] = [];
  for (const line of lines) {
    const t = line.trim().split(/\s+/);
    if (t[0] === 'format') format = t[1];
    else if (t[0] === 'element') {
      const count = Number(t[2]);
      if (!t[1] || !Number.isSafeInteger(count) || count < 0) throw new Error(`bad element line: ${line}`);
      elements.push({ name: t[1], count, props: [] });
    } else if (t[0] === 'property') {
      const el = elements.at(-1);
      const list = t[1] === 'list';
      const prop: Prop = list
        ? { countType: t[2]!, type: t[3]!, name: t[4]! }
        : { type: t[1]!, name: t[2]! };
      if (!el || !prop.name || !TYPE_SIZE[prop.type] || (list && !TYPE_SIZE[prop.countType!])) {
        throw new Error(`bad property line: ${line}`);
      }
      el.props.push(prop);
    }
  }
  if (format !== 'ascii' && format !== 'binary_little_endian') {
    throw new Error(`unsupported PLY format: ${format ?? 'none'}`);
  }
  return { ascii: format === 'ascii', elements, bodyStart: end.index + end[0].length };
}

/** Returns a reader yielding the next scalar of a given PLY type. */
function binaryReader(buf: Buffer, start: number): (type: string) => number {
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let off = start;
  return (type) => {
    const size = TYPE_SIZE[type]!;
    if (off + size > buf.byteLength) throw new Error('PLY body truncated');
    const at = off;
    off += size;
    switch (type) {
      case 'char': case 'int8': return view.getInt8(at);
      case 'uchar': case 'uint8': return view.getUint8(at);
      case 'short': case 'int16': return view.getInt16(at, true);
      case 'ushort': case 'uint16': return view.getUint16(at, true);
      case 'int': case 'int32': return view.getInt32(at, true);
      case 'uint': case 'uint32': return view.getUint32(at, true);
      case 'float': case 'float32': return view.getFloat32(at, true);
      default: return view.getFloat64(at, true);
    }
  };
}

function asciiReader(buf: Buffer, start: number): () => number {
  const body = buf.subarray(start).toString('latin1');
  const re = /\S+/g;
  return () => {
    const m = re.exec(body);
    if (!m) throw new Error('PLY body truncated');
    const v = Number(m[0]);
    if (Number.isNaN(v)) throw new Error(`bad PLY number: ${m[0].slice(0, 32)}`);
    return v;
  };
}

export interface PlyMesh {
  positions: Float32Array;
  indices: Uint32Array;
}

/** Throws on anything malformed, unsupported or beyond the caps. */
export function parsePly(buf: Buffer): PlyMesh {
  const { ascii, elements, bodyStart } = parseHeader(buf);
  const vertexEl = elements.find((e) => e.name === 'vertex');
  const faceEl = elements.find((e) => e.name === 'face');
  if (!vertexEl || !faceEl) throw new Error('PLY needs vertex and face elements');
  const xyz = ['x', 'y', 'z'].map((n) => vertexEl.props.findIndex((p) => p.name === n && !p.countType));
  if (xyz.includes(-1)) throw new Error('PLY vertex lacks x/y/z');
  const faceProp = faceEl.props.findIndex(
    (p) => p.countType && (p.name === 'vertex_indices' || p.name === 'vertex_index'),
  );
  if (faceProp === -1) throw new Error('PLY face lacks vertex_indices');
  if (vertexEl.count === 0 || vertexEl.count > MAX_PLY_VERTICES) {
    throw new Error(`PLY vertex count ${vertexEl.count} out of range`);
  }
  if (faceEl.count === 0 || faceEl.count > MAX_PLY_TRIANGLES) {
    throw new Error(`PLY face count ${faceEl.count} out of range`);
  }
  // Every scalar (a list counts as at least its length) takes ≥ its binary size,
  // or ≥ 2 ascii chars ("0 "): rejects absurd counts before anything is allocated.
  let min = 0;
  for (const e of elements) {
    min += e.count * e.props.reduce((s, p) => s + (ascii ? 2 : TYPE_SIZE[p.countType ?? p.type]!), 0);
  }
  if (bodyStart + min > buf.byteLength + (ascii ? 1 : 0)) {
    throw new Error('PLY body shorter than its header declares');
  }

  const read = ascii ? asciiReader(buf, bodyStart) : binaryReader(buf, bodyStart);
  const positions = new Float32Array(vertexEl.count * 3);
  let indices = new Uint32Array(faceEl.count * 3);
  let n = 0;
  let seen = 0;
  const vertexCount = vertexEl.count;
  for (const el of elements) {
    for (let i = 0; i < el.count; i++) {
      for (let p = 0; p < el.props.length; p++) {
        const prop = el.props[p]!;
        if (!prop.countType) {
          const v = read(prop.type);
          const axis = el === vertexEl ? xyz.indexOf(p) : -1;
          if (axis !== -1) {
            if (!Number.isFinite(v)) throw new Error('PLY vertex coordinate is not finite');
            positions[i * 3 + axis] = v;
          }
          continue;
        }
        const len = read(prop.countType);
        if (!Number.isInteger(len) || len < 0) throw new Error(`bad PLY list length ${len}`);
        const keep = el === faceEl && p === faceProp;
        let first = 0;
        let prev = 0;
        for (let k = 0; k < len; k++) {
          const v = read(prop.type);
          if (!keep) continue;
          if (!Number.isInteger(v) || v < 0 || v >= vertexCount) throw new Error(`PLY face index ${v} out of range`);
          if (k === 0) first = v;
          else if (k >= 2) {
            // Fan: (v0, v[k-1], v[k]) — a triangle is just the k = 2 case.
            if (n + 3 > indices.length) {
              if (indices.length >= MAX_PLY_TRIANGLES * 3) throw new Error('PLY triangle count over cap');
              const grown = new Uint32Array(Math.min(indices.length * 2, MAX_PLY_TRIANGLES * 3));
              grown.set(indices);
              indices = grown;
            }
            indices[n++] = first;
            indices[n++] = prev;
            indices[n++] = v;
          }
          prev = v;
        }
      }
    }
    if (el === vertexEl || el === faceEl) seen++;
    if (seen === 2) break; // trailing elements (edges, materials…) are unused.
  }
  if (n === 0) throw new Error('PLY has no triangles');
  return { positions, indices: indices.subarray(0, n) };
}

const pad4 = (n: number) => (n + 3) & ~3;

/** glTF 2.0 binary: header + JSON chunk (space-padded) + BIN chunk (zero-padded). */
export function meshToGlb({ positions, indices }: PlyMesh): Buffer {
  const vertexCount = positions.length / 3;
  const min = [Infinity, Infinity, Infinity];
  const max = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < positions.length; i++) {
    const a = i % 3;
    const v = positions[i]!;
    if (v < min[a]!) min[a] = v;
    if (v > max[a]!) max[a] = v;
  }
  // glTF forbids the type's max value as an index (primitive restart).
  const short = vertexCount <= 0xffff;
  const idx = short ? Uint16Array.from(indices) : indices;
  const posBytes = positions.byteLength; // 12·V, already 4-aligned.
  const binLength = pad4(posBytes + idx.byteLength);
  const json = {
    asset: { version: '2.0', generator: 'virtspace ply-to-glb' },
    scene: 0,
    scenes: [{ nodes: [0] }],
    nodes: [{ mesh: 0 }],
    meshes: [{ primitives: [{ attributes: { POSITION: 0 }, indices: 1, mode: 4 }] }],
    buffers: [{ byteLength: binLength }],
    bufferViews: [
      { buffer: 0, byteOffset: 0, byteLength: posBytes, target: 34962 },
      { buffer: 0, byteOffset: posBytes, byteLength: idx.byteLength, target: 34963 },
    ],
    accessors: [
      { bufferView: 0, componentType: 5126, count: vertexCount, type: 'VEC3', min, max },
      { bufferView: 1, componentType: short ? 5123 : 5125, count: idx.length, type: 'SCALAR' },
    ],
  };
  const jsonText = JSON.stringify(json);
  const jsonLength = pad4(Buffer.byteLength(jsonText));
  const total = 12 + 8 + jsonLength + 8 + binLength;
  const out = Buffer.alloc(total); // zero-filled: BIN padding comes free.
  out.write('glTF', 0, 'ascii');
  out.writeUInt32LE(2, 4);
  out.writeUInt32LE(total, 8);
  out.writeUInt32LE(jsonLength, 12);
  out.write('JSON', 16, 'ascii');
  out.fill(0x20, 20, 20 + jsonLength);
  out.write(jsonText, 20, 'utf8');
  const bin = 20 + jsonLength;
  out.writeUInt32LE(binLength, bin);
  out.write('BIN\0', bin + 4, 'ascii');
  // Typed arrays are host-endian; every host we run on is little-endian like GLB.
  Buffer.from(positions.buffer, positions.byteOffset, posBytes).copy(out, bin + 8);
  Buffer.from(idx.buffer, idx.byteOffset, idx.byteLength).copy(out, bin + 8 + posBytes);
  return out;
}

export const plyToGlb = (ply: Buffer): Buffer => meshToGlb(parsePly(ply));
