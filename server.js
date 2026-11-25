const express = require('express');
const multer = require('multer');
const AdmZip = require('adm-zip');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const app = express();
const port = 8080;

app.use(express.static('public'));

const upload = multer({ dest: '/tmp/uploads/' });
const activeSessions = {};

const PLATFORMS = ['whatsapp', 'wechat', 'telegram', 'signal', 'line'];
const PLATFORM_LIMITS = {
    whatsapp: 500 * 1024,
    wechat: 500 * 1024,
    telegram: 256 * 1024,
    signal: 300 * 1024,
    line: 300 * 1024,
};
const STATIC_SPECIALS = new Set(['tab.png', 'cover.png', 'icon.png']);
const SESSION_TTL_MS = 30 * 60 * 1000;

function sanitizeFilename(rawName) {
    const decoded = Buffer.from(rawName || 'sticker', 'latin1').toString('utf8');
    const base = path.basename(decoded).replace(/[\\/:*?"<>|\n\r]/g, '_');
    return base || 'sticker.gif';
}

function getUniquePath(dir, filename) {
    let target = path.join(dir, filename);
    if (!fs.existsSync(target)) return target;
    const ext = path.extname(filename);
    const stem = path.basename(filename, ext);
    let idx = 1;
    while (fs.existsSync(target)) {
        target = path.join(dir, `${stem}_${idx}${ext}`);
        idx += 1;
    }
    return target;
}

function buildManifest(sessionId, outputDir) {
    const manifest = {};
    const belowFloorSet = new Set();
    const belowFloorPath = path.join(outputDir, '.below_floor');
    if (fs.existsSync(belowFloorPath)) {
        fs.readFileSync(belowFloorPath, 'utf8')
            .split('\n')
            .map((l) => l.trim())
            .filter(Boolean)
            .forEach((rel) => belowFloorSet.add(rel));
    }

    for (const platform of PLATFORMS) {
        const pDir = path.join(outputDir, platform);
        const files = [];
        if (fs.existsSync(pDir)) {
            const entries = fs.readdirSync(pDir).sort();
            for (const name of entries) {
                const fullPath = path.join(pDir, name);
                const stat = fs.statSync(fullPath);
                if (!stat.isFile()) continue;

                const lower = name.toLowerCase();
                let limit = PLATFORM_LIMITS[platform];
                if (platform === 'line' && lower === 'main.png') {
                    limit = 1000 * 1024;
                } else if (STATIC_SPECIALS.has(lower)) {
                    limit = null;
                }

                const ext = path.extname(lower);
                const belowFloor = belowFloorSet.has(`${platform}/${name}`);
                files.push({
                    name,
                    size: stat.size,
                    limit,
                    belowFloor,
                    passed: (limit ? stat.size <= limit : true) && !belowFloor,
                    ext,
                    previewUrl: `/preview/${sessionId}/${platform}/${encodeURIComponent(name)}`,
                    downloadUrl: `/preview/${sessionId}/${platform}/${encodeURIComponent(name)}?download=1`,
                });
            }
        }
        manifest[platform] = files;
    }
    return manifest;
}

function cleanupSession(sessionId) {
    try {
        fs.rmSync(path.join('/tmp/processing', sessionId), { recursive: true, force: true });
    } catch (err) {
        console.error(`Cleanup error for session ${sessionId}:`, err);
    }
    delete activeSessions[sessionId];
}

setInterval(() => {
    const now = Date.now();
    for (const [sessionId, session] of Object.entries(activeSessions)) {
        if (now - session.lastAccessedAt > SESSION_TTL_MS) {
            cleanupSession(sessionId);
        }
    }
}, 5 * 60 * 1000).unref();

// 1. MULTI-FILE & ZIP UPLOAD ENDPOINT
app.post('/upload', upload.any(), async (req, res) => {
    const uploadedFiles = req.files || [];
    if (uploadedFiles.length === 0) {
        return res.status(400).json({ error: 'No files uploaded.' });
    }

    const sessionId = `${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
    const sessionDir = path.join('/tmp/processing', sessionId);
    const extractDir = path.join(sessionDir, 'input');
    const outputDir = path.join(sessionDir, 'output');
    const zipCacheDir = path.join(sessionDir, 'zips');
    const startedAt = Date.now();

    activeSessions[sessionId] = {
        clients: [],
        events: [],
        outputDir,
        zipCacheDir,
        lastAccessedAt: Date.now(),
        manifest: null,
    };

    try {
        fs.mkdirSync(extractDir, { recursive: true });
        fs.mkdirSync(outputDir, { recursive: true });
        fs.mkdirSync(zipCacheDir, { recursive: true });

        for (const file of uploadedFiles) {
            const safeName = sanitizeFilename(file.originalname);
            if (/\.(gif|png|svg)$/i.test(safeName)) {
                const destPath = getUniquePath(extractDir, safeName);
                fs.copyFileSync(file.path, destPath);
            } else if (/\.zip$/i.test(safeName)) {
                const zip = new AdmZip(file.path);
                zip.extractAllTo(extractDir, true);
            }
            fs.unlinkSync(file.path);
        }

        const whatsappFormat = req.body && req.body.whatsappFormat === 'gif' ? 'gif' : 'webp';
        const scriptPath = path.join(__dirname, 'process_stickers.sh');
        const processStickers = spawn('bash', [scriptPath, extractDir, outputDir], {
            env: { ...process.env, WHATSAPP_FORMAT: whatsappFormat },
        });

        const broadcast = (data) => {
            const session = activeSessions[sessionId];
            if (!session) return;
            session.events.push(data);
            session.clients.forEach((clientRes) => {
                clientRes.write(`data: ${JSON.stringify(data)}\n\n`);
            });
        };

        processStickers.stdout.on('data', (data) => {
            const lines = data.toString().split('\n').filter((l) => l.trim());
            lines.forEach((line) => broadcast({ type: 'log', message: line }));
        });

        processStickers.stderr.on('data', (data) => {
            const lines = data.toString().split('\n').filter((l) => l.trim());
            lines.forEach((line) => broadcast({ type: 'log', message: line }));
        });

        processStickers.on('close', (code) => {
            const session = activeSessions[sessionId];
            if (!session) return;
            session.lastAccessedAt = Date.now();

            if (code === 0) {
                try {
                    const manifest = buildManifest(sessionId, outputDir);
                    session.manifest = manifest;
                    const elapsedMs = Date.now() - startedAt;
                    broadcast({
                        type: 'done',
                        sessionId,
                        elapsedMs,
                        manifest,
                        downloadAllUrl: `/download/${sessionId}/all`,
                    });
                } catch (e) {
                    broadcast({ type: 'error', message: `Manifest generation failed: ${e.message}` });
                }
            } else {
                broadcast({ type: 'error', message: `Process exited with code ${code}` });
            }
        });

        res.json({ sessionId });
    } catch (err) {
        uploadedFiles.forEach((f) => {
            if (fs.existsSync(f.path)) fs.unlinkSync(f.path);
        });
        cleanupSession(sessionId);
        console.error(err);
        res.status(500).json({ error: 'Internal server error during upload.' });
    }
});

// 2. LOGS ENDPOINT (Server-Sent Events)
app.get('/logs/:sessionId', (req, res) => {
    const { sessionId } = req.params;
    const session = activeSessions[sessionId];
    if (!session) return res.status(404).send('Session not found');

    session.lastAccessedAt = Date.now();
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');

    res.write(`data: ${JSON.stringify({ type: 'log', message: 'Connected to fast conversion stream...' })}\n\n`);
    session.events.forEach((evt) => res.write(`data: ${JSON.stringify(evt)}\n\n`));
    session.clients.push(res);

    req.on('close', () => {
        if (activeSessions[sessionId]) {
            activeSessions[sessionId].clients = activeSessions[sessionId].clients.filter((c) => c !== res);
        }
    });
});

// 3. INLINE PREVIEW & SINGLE-FILE DOWNLOAD ENDPOINT
app.get('/preview/:sessionId/:platform/:filename', (req, res) => {
    const { sessionId, platform, filename } = req.params;
    const session = activeSessions[sessionId];
    if (!session || !PLATFORMS.includes(platform)) {
        return res.status(404).send('Not found');
    }

    const safeFile = path.basename(filename);
    const filePath = path.join(session.outputDir, platform, safeFile);
    if (!fs.existsSync(filePath)) {
        return res.status(404).send('File not found');
    }

    session.lastAccessedAt = Date.now();
    if (req.query.download === '1') {
        return res.download(filePath, safeFile);
    }

    const ext = path.extname(safeFile).toLowerCase();
    const mime =
        ext === '.gif' ? 'image/gif' :
        ext === '.webp' ? 'image/webp' :
        ext === '.png' ? 'image/png' :
        ext === '.webm' ? 'video/webm' : 'application/octet-stream';
    res.setHeader('Content-Type', mime);
    res.setHeader('Cache-Control', 'no-store');

    // LINE APNGs have finite plays (1-4 loops) which freeze in browser previews;
    // patch acTL num_plays=0 in memory for inline preview only (downloads stay spec-compliant).
    if (platform === 'line' && ext === '.png') {
        const buf = fs.readFileSync(filePath);
        if (buf.length > 8) {
            let i = 8;
            while (i + 12 <= buf.length) {
                const len = buf.readUInt32BE(i);
                const type = buf.toString('ascii', i + 4, i + 8);
                if (type === 'acTL' && len === 8 && i + 20 <= buf.length) {
                    buf.writeUInt32BE(0, i + 12);
                    const crc = zlib.crc32(buf.subarray(i + 4, i + 16));
                    buf.writeUInt32BE(crc >>> 0, i + 16);
                    break;
                }
                i += 12 + len;
            }
        }
        return res.send(buf);
    }

    res.sendFile(filePath);
});

// 4. SINGLE-PLATFORM ZIP DOWNLOAD ENDPOINT
app.get('/download/:sessionId/platform/:platform', (req, res) => {
    const { sessionId, platform } = req.params;
    const session = activeSessions[sessionId];
    if (!session || !PLATFORMS.includes(platform)) {
        return res.status(404).send('Session or platform not found');
    }

    const pDir = path.join(session.outputDir, platform);
    if (!fs.existsSync(pDir) || fs.readdirSync(pDir).length === 0) {
        return res.status(404).send('No files for this platform');
    }

    session.lastAccessedAt = Date.now();
    const zipPath = path.join(session.zipCacheDir, `${platform}_stickers.zip`);
    if (!fs.existsSync(zipPath)) {
        const zip = new AdmZip();
        zip.addLocalFolder(pDir);
        zip.writeZip(zipPath);
    }

    res.download(zipPath, `Stickers_${platform}.zip`);
});

// 5. ALL-PLATFORMS BATCH ZIP DOWNLOAD ENDPOINT (plus backward-compatible alias)
function handleDownloadAll(req, res) {
    const { sessionId } = req.params;
    const session = activeSessions[sessionId];
    if (!session || !fs.existsSync(session.outputDir)) {
        return res.status(404).send('Session not found');
    }

    session.lastAccessedAt = Date.now();
    const zipPath = path.join(session.zipCacheDir, 'all_platforms.zip');
    if (!fs.existsSync(zipPath)) {
        const zip = new AdmZip();
        for (const platform of PLATFORMS) {
            const pDir = path.join(session.outputDir, platform);
            if (fs.existsSync(pDir) && fs.readdirSync(pDir).length > 0) {
                zip.addLocalFolder(pDir, platform);
            }
        }
        zip.writeZip(zipPath);
    }

    res.download(zipPath, 'Optimized_Stickers_All_Platforms.zip');
}

app.get('/download/:sessionId/all', handleDownloadAll);
app.get('/download/:sessionId', handleDownloadAll);

// 6. OPTIONAL SESSION CLEANUP ENDPOINT
app.delete('/session/:sessionId', (req, res) => {
    const { sessionId } = req.params;
    if (activeSessions[sessionId]) {
        cleanupSession(sessionId);
    }
    res.json({ ok: true });
});

app.listen(port, () => console.log(`Server listening on port ${port}`));
