const router  = require('express').Router();
const multer  = require('multer');
const path    = require('path');
const fs      = require('fs');
const { v4: uuidv4 } = require('uuid');
const { authMiddleware } = require('./authRoutes');

// File extension is derived from the whitelisted MIME type — never trust the
// original filename's extension (blocks uploading a .html/.svg with a spoofed
// mimetype that would then get served from /uploads).
const EXT_BY_MIME = {
  'image/jpeg':      '.jpg',
  'image/png':       '.png',
  'image/webp':      '.webp',
  'image/heic':      '.heic',
  'image/heif':      '.heif',
  'video/mp4':       '.mp4',
  'video/quicktime': '.mov',
};

const UPLOAD_DIR = path.join(__dirname, '../../uploads');
fs.mkdirSync(UPLOAD_DIR, { recursive: true });

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, UPLOAD_DIR),
  filename:    (req, file, cb) => cb(null, `${uuidv4()}${EXT_BY_MIME[file.mimetype]}`),
});

const upload = multer({
  storage,
  limits: { fileSize: 50 * 1024 * 1024 }, // 50MB max
  fileFilter: (req, file, cb) => {
    if (EXT_BY_MIME[file.mimetype]) {
      cb(null, true);
    } else {
      cb(new Error(`File type not allowed: ${file.mimetype}`));
    }
  },
});

// POST /api/uploads  (auth required)
// multipart/form-data, field name: "file"
router.post('/', authMiddleware, upload.single('file'), (req, res) => {
  if (!req.file) {
    return res.status(400).json({ error: 'No file uploaded' });
  }

  const isVideo = req.file.mimetype.startsWith('video/');

  res.json({
    url:      `/uploads/${req.file.filename}`,
    filename: req.file.filename,
    type:     isVideo ? 'video' : 'image',
    size:     req.file.size,
  });
});

module.exports = router;
