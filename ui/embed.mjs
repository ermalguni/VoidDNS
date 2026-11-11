import { readdir, readFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const mimeTypes = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.mjs', 'text/javascript; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.map', 'application/json; charset=utf-8'],
  ['.txt', 'text/plain; charset=utf-8'],
  ['.xml', 'application/xml; charset=utf-8'],
  ['.svg', 'image/svg+xml'],
  ['.ico', 'image/x-icon'],
  ['.png', 'image/png'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.gif', 'image/gif'],
  ['.webp', 'image/webp'],
  ['.avif', 'image/avif'],
  ['.woff', 'font/woff'],
  ['.woff2', 'font/woff2'],
  ['.ttf', 'font/ttf'],
  ['.otf', 'font/otf'],
  ['.wasm', 'application/wasm'],
  ['.webmanifest', 'application/manifest+json'],
]);

// Byte strings preserve every production byte, including arbitrary binary files.
function zigString(bytes) {
  const parts = ['"'];
  for (const byte of bytes) {
    if (byte === 34 || byte === 92) parts.push(`\\${String.fromCharCode(byte)}`);
    else if (byte >= 32 && byte <= 126) parts.push(String.fromCharCode(byte));
    else parts.push(`\\x${byte.toString(16).padStart(2, '0')}`);
  }
  parts.push('"');
  return parts.join('');
}

export async function generateAssetModule(dist) {
  const files = [];
  async function visit(directory, prefix = '') {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const relative = `${prefix}${entry.name}`;
      if (entry.isDirectory()) await visit(path.join(directory, entry.name), `${relative}/`);
      else if (entry.isFile()) files.push(relative);
      else throw new Error(`ui/dist contains a non-regular file: ${relative}`);
    }
  }
  await visit(dist);
  files.sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)));
  if (!files.includes('index.html')) throw new Error('ui/dist/index.html is missing');
  const lines = [
    '// Generated from the complete production ui/dist tree. Do not edit.',
    'pub const Asset = struct { path: []const u8, body: []const u8, mime: []const u8, cache_control: []const u8, content_length: []const u8 };',
    'pub const assets = [_]Asset{',
  ];
  for (const file of files) {
    const bytes = await readFile(path.join(dist, file));
    if (file === 'index.html' && bytes.length === 0) throw new Error('ui/dist/index.html is empty');
    // Vite's production assets contain a content hash in their basename.
    const immutable = file.startsWith('assets/') && /-[A-Za-z0-9_-]{8,}\.[^.]+$/.test(path.posix.basename(file));
    const cache = immutable ? 'public, max-age=31536000, immutable' : 'no-cache';
    const text = (value) => zigString(Buffer.from(value));
    lines.push(`    .{ .path = ${text(`/${file}`)}, .body = ${zigString(bytes)}, .mime = ${text(mimeTypes.get(path.posix.extname(file).toLowerCase()) ?? 'application/octet-stream')}, .cache_control = ${text(cache)}, .content_length = "${bytes.length}" },`);
  }
  lines.push('};', '');
  return lines.join('\n');
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    if (Number(process.versions.node.split('.')[0]) < 22) throw new Error('Node.js 22 or newer is required');
    const [dist, output] = process.argv.slice(2);
    if (!dist || !output) throw new Error('usage: node ui/embed.mjs <ui/dist> <output.zig>');
    const source = await generateAssetModule(dist);
    await mkdir(path.dirname(output), { recursive: true });
    await writeFile(output, source);
  } catch (error) {
    console.error(`Cannot embed production UI: ${error.message}. Run npm --prefix ui ci && npm --prefix ui run build before zig build.`);
    process.exitCode = 1;
  }
}
