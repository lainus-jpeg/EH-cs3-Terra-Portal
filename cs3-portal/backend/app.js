require('dotenv').config();
const express = require('express');
const cors    = require('cors');
const { initDB } = require('./db');

const app  = express();
const PORT = process.env.PORT || 3000;

app.use(cors({
  origin: process.env.FRONTEND_URL || '*',
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'PATCH'],
  allowedHeaders: ['Content-Type', 'Authorization'],
}));
app.use(express.json());

app.use((req, _res, next) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.path}`);
  next();
});

app.use('/v1/auth',       require('./routes/auth'));
app.use('/v1/employees',  require('./routes/employees'));
app.use('/v1/requests',   require('./routes/requests'));
app.use('/v1/monitoring', require('./routes/monitoring'));
app.use('/v1/devices',    require('./routes/devices'));   // ← NEW

app.get('/v1/health', (_req, res) => {
  res.json({ status: 'OK', timestamp: new Date().toISOString() });
});

app.use((_req, res) => {
  res.status(404).json({ error: 'Route not found' });
});

async function start() {
  try {
    await initDB();
    app.listen(PORT, () => {
      console.log(`[SERVER] Running on port ${PORT}`);
    });
  } catch (err) {
    console.error('[SERVER] Failed to start:', err);
    process.exit(1);
  }
}

if (require.main === module) start();

module.exports = app;
