const router  = require('express').Router();
const bcrypt  = require('bcryptjs');
const jwt     = require('jsonwebtoken');
const { pool } = require('../db');

// POST /v1/auth/login
// Body: { email, password }
router.post('/login', async (req, res) => {
  const { email, password } = req.body;
  if (!email || !password)
    return res.status(400).json({ error: 'Email and password required' });

  try {
    const { rows } = await pool.query(
      `SELECT * FROM employees WHERE email = $1`, [email]
    );
    const employee = rows[0];

    if (!employee || !employee.password_hash)
      return res.status(401).json({ error: 'Invalid credentials' });

    if (employee.status === 'offboarded' || employee.status === 'suspended')
      return res.status(403).json({ error: 'Account is not active' });

    const valid = await bcrypt.compare(password, employee.password_hash);
    if (!valid)
      return res.status(401).json({ error: 'Invalid credentials' });

    const token = jwt.sign(
      {
        employee_id: employee.employee_id,
        email:       employee.email,
        role:        employee.role,
        is_admin:    employee.is_admin,
      },
      process.env.JWT_SECRET,
      { expiresIn: '8h' }
    );

    res.json({
      token,
      employee: {
        employee_id: employee.employee_id,
        name:        employee.name,
        email:       employee.email,
        department:  employee.department,
        role:        employee.role,
        status:      employee.status,
        is_admin:    employee.is_admin,
      }
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /v1/auth/change-password  (authenticated)
// Body: { current_password, new_password }
const { requireAuth } = require('../middleware');
router.post('/change-password', requireAuth, async (req, res) => {
  const { current_password, new_password } = req.body;
  if (!current_password || !new_password)
    return res.status(400).json({ error: 'Both passwords required' });

  try {
    const { rows } = await pool.query(
      `SELECT * FROM employees WHERE employee_id = $1`, [req.user.employee_id]
    );
    const employee = rows[0];

    const valid = await bcrypt.compare(current_password, employee.password_hash);
    if (!valid)
      return res.status(401).json({ error: 'Current password incorrect' });

    const hash = await bcrypt.hash(new_password, 10);
    await pool.query(
      `UPDATE employees SET password_hash = $1, updated_at = NOW() WHERE employee_id = $2`,
      [hash, req.user.employee_id]
    );

    res.json({ message: 'Password updated' });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
