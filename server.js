const express = require('express');
const multer = require('multer');
const AdmZip = require('adm-zip');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const app = express();
const port = 8080;

app.use(express.static('public'));

const upload = multer({ dest: '/tmp/uploads/' });
const activeSessions = {};

// 1. UPLOAD ENDPOINT
app.post('/upload', upload.single('stickerZip'), async (req, res) => {
    if (!req.file) return res.status(400).json({ error: 'No file uploaded.' });

    const sessionId = Date.now().toString();
    const uploadedZipPath = req.file.path;
    const extractDir = path.join('/tmp/processing', sessionId, 'input');
    const outputDir = path.join('/tmp/processing', sessionId, 'output');

    activeSessions[sessionId] = { clients: [], events: [] };

    try {
        fs.mkdirSync(extractDir, { recursive: true });
        fs.mkdirSync(outputDir, { recursive: true });

        const originalName = path.basename(Buffer.from(req.file.originalname || '', 'latin1').toString('utf8'));
        if (/\.(gif|png)$/i.test(originalName)) {
            // Single image: place it directly in the input folder
            fs.copyFileSync(uploadedZipPath, path.join(extractDir, originalName.replace(/[\\/:*?"<>|\n\r]/g, '_')));
        } else {
            const zip = new AdmZip(uploadedZipPath);
            zip.extractAllTo(extractDir, true);
        }
        fs.unlinkSync(uploadedZipPath);

        // Start processing asynchronously
        const scriptPath = path.join(__dirname, 'process_stickers.sh');
        const processStickers = spawn('bash', [scriptPath, extractDir, outputDir]);

        const broadcast = (data) => {
            if (activeSessions[sessionId]) {
                activeSessions[sessionId].events.push(data);
                activeSessions[sessionId].clients.forEach(clientRes => {
                    clientRes.write(`data: ${JSON.stringify(data)}\n\n`);
                });
            }
        };

        processStickers.stdout.on('data', (data) => {
            const lines = data.toString().split('\n').filter(l => l.trim());
            lines.forEach(line => broadcast({ type: 'log', message: line }));
        });

        processStickers.stderr.on('data', (data) => {
            // FFmpeg logs to stderr natively, so we treat it as standard logs for the UI
            const lines = data.toString().split('\n').filter(l => l.trim());
            lines.forEach(line => broadcast({ type: 'log', message: line }));
        });

        processStickers.on('close', (code) => {
            if (code === 0) {
                try {
                    const outputZipPath = path.join('/tmp', `optimized_stickers_${sessionId}.zip`);
                    const outputZip = new AdmZip();
                    outputZip.addLocalFolder(outputDir);
                    outputZip.writeZip(outputZipPath);

                    broadcast({ type: 'done', url: `/download/${sessionId}` });
                } catch (e) {
                    broadcast({ type: 'error', message: `Zipping failed: ${e.message}` });
                }
            } else {
                broadcast({ type: 'error', message: `Process exited with code ${code}` });
            }
        });

        // Respond immediately so frontend can open SSE connection
        res.json({ sessionId });

    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'Internal server error during upload.' });
    }
});

// 2. LOGS ENDPOINT (Server-Sent Events)
app.get('/logs/:sessionId', (req, res) => {
    const { sessionId } = req.params;
    if (!activeSessions[sessionId]) return res.status(404).send('Session not found');

    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');

    // Send an initial connected message so the client stream starts
    res.write(`data: ${JSON.stringify({ type: 'log', message: 'Connected to log stream...' })}\n\n`);

    // Replay anything emitted before this client connected (fast single-file runs)
    activeSessions[sessionId].events.forEach(evt => res.write(`data: ${JSON.stringify(evt)}\n\n`));
    activeSessions[sessionId].clients.push(res);

    req.on('close', () => {
        if (activeSessions[sessionId]) {
            activeSessions[sessionId].clients = activeSessions[sessionId].clients.filter(c => c !== res);
        }
    });
});

// 3. DOWNLOAD ENDPOINT
app.get('/download/:sessionId', (req, res) => {
    const { sessionId } = req.params;
    const outputZipPath = path.join('/tmp', `optimized_stickers_${sessionId}.zip`);
    
    if (!fs.existsSync(outputZipPath)) {
        return res.status(404).send('File not found');
    }

    res.download(outputZipPath, 'Optimized_Stickers.zip', (err) => {
        // Cleanup after download
        try {
            fs.rmSync(path.join('/tmp/processing', sessionId), { recursive: true, force: true });
            fs.unlinkSync(outputZipPath);
            delete activeSessions[sessionId];
        } catch (cleanupErr) {
            console.error('Cleanup error:', cleanupErr);
        }
    });
});

app.listen(port, () => console.log(`Server listening on port ${port}`));