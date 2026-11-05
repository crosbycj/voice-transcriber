#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const CHUNKS = [
  ["icp4", "icon_16x16.png"],
  ["icp5", "icon_32x32.png"],
  ["icp6", "icon_32x32@2x.png"],
  ["ic07", "icon_128x128.png"],
  ["ic08", "icon_256x256.png"],
  ["ic09", "icon_512x512.png"],
  ["ic10", "icon_512x512@2x.png"],
];

function encodeChunk(type, data) {
  const chunk = Buffer.allocUnsafe(8 + data.length);
  chunk.write(type, 0, 4, "ascii");
  chunk.writeUInt32BE(chunk.length, 4);
  data.copy(chunk, 8);
  return chunk;
}

function main() {
  const iconsetDir = process.argv[2] ? path.resolve(process.argv[2]) : "";
  const outputPath = process.argv[3] ? path.resolve(process.argv[3]) : "";
  if (!iconsetDir || !outputPath) {
    throw new Error("Usage: create-icns.mjs /path/to/AppIcon.iconset /path/to/AppIcon.icns");
  }

  const chunks = CHUNKS.map(([type, filename]) => {
    const filePath = path.join(iconsetDir, filename);
    if (!fs.existsSync(filePath)) {
      throw new Error(`Missing icon representation: ${filePath}`);
    }
    return encodeChunk(type, fs.readFileSync(filePath));
  });
  const totalLength = 8 + chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const header = Buffer.allocUnsafe(8);
  header.write("icns", 0, 4, "ascii");
  header.writeUInt32BE(totalLength, 4);

  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, Buffer.concat([header, ...chunks], totalLength));
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
