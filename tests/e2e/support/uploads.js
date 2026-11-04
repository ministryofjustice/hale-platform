// Uploading through the Media Library, and the synthetic files to upload.
// Shared by specs/all-sites/uploads.spec.js and specs/hale/upload-size.spec.js.
//
// Uploads go through wp-admin's Add New Media page (media-new.php), as an
// editor would. That page checks nothing but the size in the browser, so the
// file type is checked by WordPress on the server.

const zlib = require("node:zlib");
const { expect } = require("@playwright/test");

const MB = 1024 * 1024;

// The file types and size limit WordPress gives the uploader for this site and
// user. The Media Library prints them for its uploader in _wpPluploadSettings.
async function uploadSettings(page) {
  await page.goto("wp-admin/upload.php?mode=grid");
  return page.evaluate(() => {
    const { filters } = window._wpPluploadSettings.defaults;
    return {
      extensions: filters.mime_types[0].extensions.split(","),
      maxBytes: parseInt(filters.max_file_size, 10),
    };
  });
}

// Upload one file on media-new.php and wait for the uploader's answer:
// { uploaded: true, url } or { uploaded: false, message }. Each file gets its
// own .media-item: an Edit link and a Copy URL button once the attachment
// exists, or an error, from the server (.error-div) or from the browser's
// size check (.media-item.error).
async function uploadFile(page, file, { timeout = 30_000 } = {}) {
  if (!new URL(page.url()).pathname.endsWith("/wp-admin/media-new.php")) {
    await page.goto("wp-admin/media-new.php");
  }

  const items = page.locator("#media-items > .media-item");
  const item = items.nth(await items.count());

  const chooser = page.waitForEvent("filechooser");
  await page.locator("#plupload-browse-button").click();
  await (await chooser).setFiles(file);

  let result = null;
  await expect
    .poll(
      async () => {
        if (!(await item.count())) {
          return null;
        }
        result = await item.evaluate((el) => {
          if (el.querySelector(".edit-attachment")) {
            return { uploaded: true, url: el.querySelector(".copy-attachment-url")?.dataset.clipboardText };
          }
          if (el.matches(".error") || el.querySelector(".error-div")) {
            const message = el.innerText.replace(/^\s*Dismiss\s*/, "").replace(/\s+/g, " ").trim();
            return { uploaded: false, message };
          }
          return null;
        });
        return result;
      },
      { message: `the uploader to finish with ${file.name}`, timeout },
    )
    .not.toBeNull();

  return result;
}

// Bytes that PHP's fileinfo reads as plain binary (application/octet-stream).
// WordPress accepts that for any document, audio or video type, so these
// stand in for files it only stores and does not open. Pseudo-random, so
// nothing along the way can compress them smaller.
function fillerBytes(size) {
  const bytes = Buffer.alloc(size);
  let x = 0x2e2e;
  for (let i = 0; i < size; i++) {
    x = (Math.imul(x, 1103515245) + 12345) >>> 0;
    bytes[i] = x >>> 24;
  }
  return bytes;
}

// Images WordPress reads and resizes, so they must be real ones. The browser
// draws them; it has no GIF or AVIF encoder, so those are fixed small images:
// a 1x1 GIF, and an 8x8 AVIF made with PHP's imageavif().
const CANVAS_TYPES = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", jpe: "image/jpeg", webp: "image/webp" };
const FIXED_IMAGES = {
  gif: {
    mimeType: "image/gif",
    buffer: Buffer.from("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7", "base64"),
  },
  avif: {
    mimeType: "image/avif",
    buffer: Buffer.from(
      "AAAAIGZ0eXBhdmlmAAAAAGF2aWZtaWYxbWlhZk1BMUIAAADrbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAAAAAAAOcGl0bQAAAAAAAQAAAB5pbG9jAAAAAEQAAAEAAQAAAAEAAAETAAAAJQAAAChpaW5mAAAAAAABAAAAGmluZmUCAAAAAAEAAGF2MDFDb2xvcgAAAABqaXBycAAAAEtpcGNvAAAAFGlzcGUAAAAAAAAACAAAAAgAAAAQcGl4aQAAAAADCAgIAAAADGF2MUOBAAwAAAAAE2NvbHJuY2x4AAEADQABgAAAABdpcG1hAAAAAAAAAAEAAQQBAoMEAAAALW1kYXQSAAoIGAi/aICGgMIyFxsHh4XhzTTTQoSAAJA2IJvXzaNq5LEx",
      "base64",
    ),
  },
};

async function drawImage(page, mimeType) {
  const base64 = await page.evaluate((type) => {
    const canvas = document.createElement("canvas");
    canvas.width = 320;
    canvas.height = 200;
    const context = canvas.getContext("2d");
    context.fillStyle = "#1d70b8";
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.fillStyle = "#ffffff";
    context.font = "48px sans-serif";
    context.fillText("E2E", 110, 120);
    const url = canvas.toDataURL(type);
    // A browser that cannot encode the type falls back to PNG.
    if (!url.startsWith(`data:${type};`)) {
      throw new Error(`This browser cannot encode ${type}`);
    }
    return url.slice(url.indexOf(",") + 1);
  }, mimeType);
  return Buffer.from(base64, "base64");
}

const SVG = `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200" viewBox="0 0 320 200">
  <rect width="320" height="200" fill="#1d70b8"/>
  <text x="110" y="120" font-size="48" fill="#ffffff">E2E</text>
</svg>
`;

// A synthetic file of the given extension, as Playwright's setFiles takes it.
async function syntheticFile(page, ext) {
  const name = `e2e-synthetic-${ext}.${ext}`;
  if (CANVAS_TYPES[ext]) {
    return { name, mimeType: CANVAS_TYPES[ext], buffer: await drawImage(page, CANVAS_TYPES[ext]) };
  }
  if (FIXED_IMAGES[ext]) {
    return { name, ...FIXED_IMAGES[ext] };
  }
  if (ext === "svg") {
    return { name, mimeType: "image/svg+xml", buffer: Buffer.from(SVG) };
  }
  if (ext === "svgz") {
    return { name, mimeType: "image/svg+xml", buffer: zlib.gzipSync(SVG) };
  }
  if (ext === "json") {
    return { name, mimeType: "application/json", buffer: Buffer.from('{"e2e": true}\n') };
  }
  return { name, mimeType: "application/octet-stream", buffer: fillerBytes(2048) };
}

// A real PNG of exactly `size` bytes: the drawn image with a private chunk of
// filler before its end, which image readers skip. Chunk type "paDd":
// ancillary, private, safe to copy.
async function pngOfSize(page, size, name) {
  const png = await drawImage(page, "image/png");
  const iend = png.length - 12;
  const padding = size - png.length - 12;
  if (padding < 0) {
    throw new Error(`A PNG cannot be smaller than ${png.length + 12} bytes`);
  }

  const typeAndData = Buffer.concat([Buffer.from("paDd"), fillerBytes(padding)]);
  const length = Buffer.alloc(4);
  length.writeUInt32BE(padding);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(zlib.crc32(typeAndData));

  const buffer = Buffer.concat([png.subarray(0, iend), length, typeAndData, crc, png.subarray(iend)]);
  return { name, mimeType: "image/png", buffer };
}

module.exports = { MB, uploadSettings, uploadFile, syntheticFile, fillerBytes, pngOfSize };
