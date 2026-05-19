const router  = require('express').Router();
const bcrypt  = require('bcryptjs');
const { pool } = require('../db');
const { requireAuth, requireAdmin } = require('../middleware');
const { LambdaClient, InvokeCommand } = require('@aws-sdk/client-lambda');

const lambda = new LambdaClient({ region: process.env.AWS_REGION || 'eu-central-1' });

async function invokeLambda(functionName, payload) {
  const command = new InvokeCommand({
    FunctionName: functionName,
    Payload: JSON.stringify(payload),
  });
  const response = await lambda.send(command);
  return JSON.parse(Buffer.from(response.Payload).toString());
}

// GET /v1/employees  (admin only) — list all employees
router.get('/', requireAdmin, async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT employee_id, name, email, department, role, status, is_admin, created_at, updated_at
       FROM employees ORDER BY created_at DESC`
    );
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /v1/employees/me  (any authenticated user) — own profile
router.get('/me', requireAuth, async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT employee_id, name, email, department, role, status, is_admin, created_at
       FROM employees WHERE employee_id = $1`,
      [req.user.employee_id]
    );
    if (!rows[0]) return res.status(404).json({ error: 'Employee not found' });
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /v1/employees/:id  (admin only) — single employee
router.get('/:id', requireAdmin, async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT employee_id, name, email, department, role, status, is_admin, created_at, updated_at
       FROM employees WHERE employee_id = $1`,
      [req.params.id]
    );
    if (!rows[0]) return res.status(404).json({ error: 'Employee not found' });
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /v1/employees  (admin only) — create / onboard new employee
// Body: { name, email, department, role }
router.post('/', requireAdmin, async (req, res) => {
  const { name, email, department, role } = req.body;
  if (!name || !email || !department || !role)
    return res.status(400).json({ error: 'name, email, department and role are required' });

  // Auto-generate a random portal password — AWS issues its own temp password via Lambda
  const autoPassword = require('crypto').randomBytes(8).toString('hex');
  try {
    const hash = await bcrypt.hash(autoPassword, 10);
    const { rows } = await pool.query(
      `INSERT INTO employees (name, email, department, role, status, password_hash)
       VALUES ($1, $2, $3, $4, 'pending', $5)
       RETURNING employee_id, name, email, department, role, status, created_at`,
      [name, email, department, role, hash]
    );
    // Return temp password so IT Ops can hand it to the employee on onboard
    res.status(201).json({ ...rows[0], temp_portal_password: autoPassword });
  } catch (err) {
    if (err.code === '23505') // unique violation
      return res.status(409).json({ error: 'Email already exists' });
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// PUT /v1/employees/:id  (admin only) — update employee details
router.put('/:id', requireAdmin, async (req, res) => {
  const { name, department, role, status } = req.body;
  try {
    const { rows } = await pool.query(
      `UPDATE employees
       SET name       = COALESCE($1, name),
           department = COALESCE($2, department),
           role       = COALESCE($3, role),
           status     = COALESCE($4, status),
           updated_at = NOW()
       WHERE employee_id = $5
       RETURNING employee_id, name, email, department, role, status, updated_at`,
      [name, department, role, status, req.params.id]
    );
    if (!rows[0]) return res.status(404).json({ error: 'Employee not found' });
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /v1/employees/:id/reset-password  (admin only) — set a new portal password
router.post('/:id/reset-password', requireAdmin, async (req, res) => {
  const { new_password } = req.body;
  if (!new_password) return res.status(400).json({ error: 'new_password is required' });

  try {
    const { rows } = await pool.query(
      `SELECT employee_id, email FROM employees WHERE employee_id = $1`,
      [req.params.id]
    );
    if (!rows[0]) return res.status(404).json({ error: 'Employee not found' });

    const hash = await bcrypt.hash(new_password, 10);
    await pool.query(
      `UPDATE employees SET password_hash = $1, updated_at = NOW() WHERE employee_id = $2`,
      [hash, req.params.id]
    );

    console.log(`[LIFECYCLE] Portal password reset for: ${rows[0].email}`);
    res.json({ message: 'Password reset', email: rows[0].email });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /v1/employees/:id/onboard  (admin only) — set status to active + create IAM user
router.post('/:id/onboard', requireAdmin, async (req, res) => {
  try {
    const { rows } = await pool.query(
      `UPDATE employees SET status = 'active', updated_at = NOW()
       WHERE employee_id = $1
       RETURNING employee_id, name, email, role, department, status`,
      [req.params.id]
    );
    if (!rows[0]) return res.status(404).json({ error: 'Employee not found' });

    const employee = rows[0];
    console.log(`[LIFECYCLE] Onboarding: ${employee.email}`);

    // Invoke Lambda to create AWS IAM user
    let lambdaResult = null;
    let lambdaError  = null;
    try {
      if (!process.env.ONBOARDING_LAMBDA_NAME) throw new Error('ONBOARDING_LAMBDA_NAME env var not set');
      lambdaResult = await invokeLambda(
        process.env.ONBOARDING_LAMBDA_NAME,
        {
          employee_id: employee.employee_id,
          name:        employee.name,
          email:       employee.email,
          role:        employee.role,
          department:  employee.department,
        }
      );
      console.log(`[LIFECYCLE] Lambda result: ${JSON.stringify(lambdaResult)}`);
    } catch (lambdaErr) {
      lambdaError = lambdaErr.message || 'Lambda invocation failed';
      console.error(`[LIFECYCLE] Lambda error: ${lambdaError}`);
    }

    res.json({
      message:  'Employee onboarded',
      employee,
      iam: lambdaResult,
      iam_error: lambdaError,   // non-null means AWS step failed
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /v1/employees/:id/offboard  (admin only) — set status to offboarded + revoke IAM
router.post('/:id/offboard', requireAdmin, async (req, res) => {
  try {
    const { rows } = await pool.query(
      `UPDATE employees SET status = 'offboarded', updated_at = NOW()
       WHERE employee_id = $1
       RETURNING employee_id, name, email, role, department, status`,
      [req.params.id]
    );
    if (!rows[0]) return res.status(404).json({ error: 'Employee not found' });

    const employee = rows[0];
    console.log(`[LIFECYCLE] Offboarding: ${employee.email}`);

    // Invoke Lambda to revoke all AWS access
    let lambdaResult = null;
    let lambdaError  = null;
    try {
      if (!process.env.OFFBOARDING_LAMBDA_NAME) throw new Error('OFFBOARDING_LAMBDA_NAME env var not set');
      lambdaResult = await invokeLambda(
        process.env.OFFBOARDING_LAMBDA_NAME,
        {
          employee_id: employee.employee_id,
          email:       employee.email,
        }
      );
      console.log(`[LIFECYCLE] Lambda result: ${JSON.stringify(lambdaResult)}`);
    } catch (lambdaErr) {
      lambdaError = lambdaErr.message || 'Lambda invocation failed';
      console.error(`[LIFECYCLE] Lambda error: ${lambdaError}`);
    }

    res.json({
      message:  'Employee offboarded',
      employee,
      iam: lambdaResult,
      iam_error: lambdaError,
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// DELETE /v1/employees/:id  (admin only) — hard delete
router.delete('/:id', requireAdmin, async (req, res) => {
  try {
    const { rowCount } = await pool.query(
      `DELETE FROM employees WHERE employee_id = $1`, [req.params.id]
    );
    if (rowCount === 0) return res.status(404).json({ error: 'Employee not found' });
    res.json({ message: 'Employee deleted' });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
