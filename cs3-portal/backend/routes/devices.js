const router = require('express').Router();
const { pool } = require('../db');
const { requireAdmin } = require('../middleware');
const {
  SSMClient,
  CreateActivationCommand,
  DeregisterManagedInstanceCommand,
  DescribeInstanceInformationCommand,
} = require('@aws-sdk/client-ssm');

const ssm = new SSMClient({ region: process.env.AWS_REGION || 'eu-central-1' });

// ── GET /v1/devices  — all devices (admin) ───────────────────────────────────
router.get('/', requireAdmin, async (req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT d.*, e.name AS employee_name, e.email AS employee_email
      FROM devices d
      LEFT JOIN employees e ON e.employee_id = d.employee_id
      ORDER BY d.created_at DESC
    `);
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ── GET /v1/devices/employee/:employeeId  — devices for one employee ─────────
router.get('/employee/:employeeId', requireAdmin, async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT * FROM devices WHERE employee_id = $1 ORDER BY created_at DESC`,
      [req.params.employeeId]
    );
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ── POST /v1/devices  — register a new device + create SSM activation ────────
// Body: { employee_id, device_name, device_type, serial_number, os }
router.post('/', requireAdmin, async (req, res) => {
  const { employee_id, device_name, device_type, serial_number, os } = req.body;
  if (!employee_id || !device_name || !device_type)
    return res.status(400).json({ error: 'employee_id, device_name and device_type are required' });

  try {
    // 1. Create SSM hybrid activation
    const activation = await ssm.send(new CreateActivationCommand({
      Description:        `Innovatech device: ${device_name}`,
      IamRole:            process.env.SSM_REGISTRATION_ROLE || 'SSMServiceRole',
      RegistrationLimit:  1,
      Tags: [
        { Key: 'Project',     Value: 'cs3-innovatech' },
        { Key: 'EmployeeId',  Value: employee_id },
        { Key: 'DeviceName',  Value: device_name },
      ],
    }));

    // 2. Save device to DB
    const { rows } = await pool.query(`
      INSERT INTO devices
        (employee_id, device_name, device_type, serial_number, os,
         ssm_activation_id, ssm_status)
      VALUES ($1, $2, $3, $4, $5, $6, 'pending_enrollment')
      RETURNING *
    `, [employee_id, device_name, device_type, serial_number || null, os || null,
        activation.ActivationId]);

    console.log(`[DEVICE] Registered ${device_name} — activation ${activation.ActivationId}`);

    res.status(201).json({
      device:          rows[0],
      ssm_activation:  {
        activation_id:   activation.ActivationId,
        activation_code: activation.ActivationCode,
        // IT Ops gives these two values to the employee to run on their machine:
        // aws ssm register-agent --activation-id <id> --activation-code <code> --region eu-central-1
      },
    });
  } catch (err) {
    console.error('[DEVICE] SSM activation error:', err);
    res.status(500).json({ error: 'Failed to create SSM activation', detail: err.message });
  }
});

// ── PATCH /v1/devices/:id/instance  — update SSM instance ID once enrolled ───
// Body: { ssm_instance_id }   (called by IT after device checks in)
router.patch('/:id/instance', requireAdmin, async (req, res) => {
  const { ssm_instance_id } = req.body;
  if (!ssm_instance_id)
    return res.status(400).json({ error: 'ssm_instance_id is required' });

  try {
    // Verify it actually exists in SSM
    const info = await ssm.send(new DescribeInstanceInformationCommand({
      Filters: [{ Key: 'InstanceIds', Values: [ssm_instance_id] }],
    }));

    const ssmStatus = info.InstanceInformationList?.[0]?.PingStatus === 'Online'
      ? 'online' : 'offline';

    const { rows } = await pool.query(`
      UPDATE devices
      SET ssm_instance_id = $1,
          ssm_status      = $2,
          enrolled_at     = NOW(),
          updated_at      = NOW()
      WHERE device_id = $3
      RETURNING *
    `, [ssm_instance_id, ssmStatus, req.params.id]);

    if (!rows[0]) return res.status(404).json({ error: 'Device not found' });
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ── DELETE /v1/devices/:id  — deregister device from SSM + remove from DB ────
router.delete('/:id', requireAdmin, async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT * FROM devices WHERE device_id = $1`, [req.params.id]
    );
    if (!rows[0]) return res.status(404).json({ error: 'Device not found' });

    const device = rows[0];

    // If enrolled, deregister from SSM
    if (device.ssm_instance_id) {
      try {
        await ssm.send(new DeregisterManagedInstanceCommand({
          InstanceId: device.ssm_instance_id,
        }));
        console.log(`[DEVICE] Deregistered SSM instance ${device.ssm_instance_id}`);
      } catch (ssmErr) {
        console.warn(`[DEVICE] SSM deregister warning: ${ssmErr.message}`);
        // Don't block DB deletion if SSM call fails
      }
    }

    await pool.query(`DELETE FROM devices WHERE device_id = $1`, [req.params.id]);
    res.json({ message: 'Device deregistered and removed' });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
