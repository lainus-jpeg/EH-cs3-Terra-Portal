const router = require('express').Router();
const { pool } = require('../db');
const { requireAuth, requireAdmin } = require('../middleware');

// GET /v1/requests  (admin only) — all requests
router.get('/', requireAdmin, async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT r.*, e.name AS employee_name, e.email AS employee_email
       FROM requests r
       JOIN employees e ON r.employee_id = e.employee_id
       ORDER BY r.created_at DESC`
    );
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /v1/requests/mine  (authenticated) — own requests only
router.get('/mine', requireAuth, async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT * FROM requests WHERE employee_id = $1 ORDER BY created_at DESC`,
      [req.user.employee_id]
    );
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /v1/requests  (authenticated) — submit a new request
// Body: { type, description }
router.post('/', requireAuth, async (req, res) => {
  const { type, description } = req.body;
  if (!type)
    return res.status(400).json({ error: 'Request type is required' });

  try {
    const { rows } = await pool.query(
      `INSERT INTO requests (employee_id, type, description)
       VALUES ($1, $2, $3)
       RETURNING *`,
      [req.user.employee_id, type, description || '']
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// PUT /v1/requests/:id  (admin only) — update request status
// Body: { status }
router.put('/:id', requireAdmin, async (req, res) => {
  const { status } = req.body;
  if (!status)
    return res.status(400).json({ error: 'Status is required' });

  try {
    const { rows } = await pool.query(
      `UPDATE requests SET status = $1, updated_at = NOW()
       WHERE request_id = $2
       RETURNING *`,
      [status, req.params.id]
    );
    if (!rows[0]) return res.status(404).json({ error: 'Request not found' });
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
