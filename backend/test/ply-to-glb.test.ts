import { describe, it, expect } from 'vitest';
import { plyToGlb } from '../src/ply-to-glb.js';

// Echo-3 `mesh-simplified` PLY → collider GLB (spec §5.3, R47).

/** Parse a GLB back: header, JSON chunk, typed views of POSITION and indices. */
function readGlb(glb: Buffer) {
  expect(glb.toString('ascii', 0, 4)).toBe('glTF');
  expect(glb.readUInt32LE(4)).toBe(2);
  expect(glb.readUInt32LE(8)).toBe(glb.length);
  const jsonLen = glb.readUInt32LE(12);
  expect(glb.toString('ascii', 16, 20)).toBe('JSON');
  const binAt = 20 + jsonLen;
  const binLen = glb.readUInt32LE(binAt);
  expect(glb.toString('ascii', binAt + 4, binAt + 8)).toBe('BIN\0');
  expect([jsonLen % 4, binLen % 4, glb.length % 4]).toEqual([0, 0, 0]);
  expect(binAt + 8 + binLen).toBe(glb.length);
  const gltf = JSON.parse(glb.toString('utf8', 20, binAt));
  const bin = glb.subarray(binAt + 8);
  const view = (i: number) => gltf.bufferViews[gltf.accessors[i].bufferView];
  const pos = view(0);
  const positions = Array.from(new Float32Array(bin.buffer.slice(bin.byteOffset + pos.byteOffset, bin.byteOffset + pos.byteOffset + pos.byteLength)));
  const ix = view(1);
  const raw = bin.buffer.slice(bin.byteOffset + ix.byteOffset, bin.byteOffset + ix.byteOffset + ix.byteLength);
  const indices = Array.from(gltf.accessors[1].componentType === 5123 ? new Uint16Array(raw) : new Uint32Array(raw));
  return { gltf, positions, indices };
}

const header = (format: string, vertexProps: string, faceProp = 'property list uchar int vertex_indices') =>
  `ply\nformat ${format} 1.0\ncomment test\nelement vertex 4\n${vertexProps}element face 2\n${faceProp}\nend_header\n`;

const XYZ = [0, 0, 0, 1, 0, 0, 1, 2, 0, 0, -1, 3];

describe('plyToGlb', () => {
  it('ascii: quad fans to two triangles, extra properties ignored, min/max set', () => {
    const ply =
      header('ascii', 'property float x\nproperty float y\nproperty float z\nproperty uchar red\n') +
      '0 0 0 255\n1 0 0 255\n1 2 0 255\n0 -1 3 255\n4 0 1 2 3\n3 2 3 0\n';
    const { gltf, positions, indices } = readGlb(plyToGlb(Buffer.from(ply)));
    expect(positions).toEqual(XYZ);
    expect(indices).toEqual([0, 1, 2, 0, 2, 3, 2, 3, 0]);
    expect(gltf.accessors[0]).toMatchObject({ componentType: 5126, count: 4, type: 'VEC3', min: [0, -1, 0], max: [1, 2, 3] });
    expect(gltf.accessors[1]).toMatchObject({ componentType: 5123, count: 9, type: 'SCALAR' });
    expect(gltf.meshes[0].primitives[0]).toEqual({ attributes: { POSITION: 0 }, indices: 1, mode: 4 });
  });

  it('binary_little_endian with double coordinates and a trailing element', () => {
    const head = Buffer.from(
      header('binary_little_endian', 'property double x\nproperty double y\nproperty double z\n', 'property list uchar uint vertex_indices')
        .replace('end_header', 'element edge 1\nproperty int a\nend_header'),
    );
    const verts = Buffer.alloc(4 * 3 * 8);
    XYZ.forEach((v, i) => verts.writeDoubleLE(v, i * 8));
    const face = (ids: number[]) => {
      const b = Buffer.alloc(1 + ids.length * 4);
      b.writeUInt8(ids.length, 0);
      ids.forEach((id, i) => b.writeUInt32LE(id, 1 + i * 4));
      return b;
    };
    const edge = Buffer.alloc(4);
    const glb = plyToGlb(Buffer.concat([head, verts, face([0, 1, 2]), face([0, 2, 3]), edge]));
    const { positions, indices, gltf } = readGlb(glb);
    expect(positions).toEqual(XYZ);
    expect(indices).toEqual([0, 1, 2, 0, 2, 3]);
    expect(gltf.accessors[0].max).toEqual([1, 2, 3]);
  });

  it('rejects malformed input', () => {
    const good = header('ascii', 'property float x\nproperty float y\nproperty float z\n');
    const bad = [
      'not a ply at all',
      good.replace('end_header\n', ''), // no end_header
      good.replace('ascii', 'binary_big_endian') + '\0'.repeat(200),
      good.replace('property float z\n', ''), // no z
      good + '0 0 0\n1 0 0\n1 2 0\n0 -1 3\n3 0 1 9\n3 0 1 2\n', // index out of range
      good + '0 0 0\n1 0 0\n', // truncated
      good + '0 0 nan\n1 0 0\n1 2 0\n0 -1 3\n3 0 1 2\n3 0 1 2\n', // not a number
      good.replace('element face 2', 'element face 19999999') + '0 0 0\n', // absurd count
      good.replace('element vertex 4', 'element vertex 99999999999'),
    ];
    for (const ply of bad) expect(() => plyToGlb(Buffer.from(ply))).toThrow();
  });

  it('uses uint32 indices once vertices exceed uint16', () => {
    const n = 70_000;
    const head = Buffer.from(
      `ply\nformat binary_little_endian 1.0\nelement vertex ${n}\nproperty float x\nproperty float y\nproperty float z\n` +
        'element face 1\nproperty list uchar int vertex_indices\nend_header\n',
    );
    const verts = Buffer.alloc(n * 12);
    verts.writeFloatLE(5, (n - 1) * 12);
    const face = Buffer.alloc(13);
    face.writeUInt8(3, 0);
    face.writeInt32LE(0, 1);
    face.writeInt32LE(1, 5);
    face.writeInt32LE(n - 1, 9);
    const { gltf, indices } = readGlb(plyToGlb(Buffer.concat([head, verts, face])));
    expect(gltf.accessors[1].componentType).toBe(5125);
    expect(indices).toEqual([0, 1, n - 1]);
    expect(gltf.accessors[0].max).toEqual([5, 0, 0]);
  });
});
