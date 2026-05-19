const { Pool } = require('pg');

const pool = new Pool({
  host:     process.env.DB_HOST,
  port:     process.env.DB_PORT || 5432,
  database: process.env.DB_NAME,
  user:     process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : false,
});

// Create tables if they don't exist — runs on startup
async function initDB() {
  const client = await pool.connect();
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS employees (
        employee_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        name          VARCHAR(255) NOT NULL,
        email         VARCHAR(255) UNIQUE NOT NULL,
        department    VARCHAR(100),
        role          VARCHAR(100),
        status        VARCHAR(20) DEFAULT 'pending'
                        CHECK (status IN ('active','pending','suspended','offboarded')),
        is_admin      BOOLEAN DEFAULT FALSE,
        password_hash VARCHAR(255),
        created_at    TIMESTAMP DEFAULT NOW(),
        updated_at    TIMESTAMP DEFAULT NOW()
      );
    `);

    await client.query(`
      CREATE TABLE IF NOT EXISTS requests (
        request_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        employee_id   UUID REFERENCES employees(employee_id) ON DELETE CASCADE,
        type          VARCHAR(50) NOT NULL
                        CHECK (type IN ('password_reset','software_install','access_request','other')),
        description   TEXT,
        status        VARCHAR(20) DEFAULT 'open'
                        CHECK (status IN ('open','in_progress','resolved','rejected')),
        created_at    TIMESTAMP DEFAULT NOW(),
        updated_at    TIMESTAMP DEFAULT NOW()
      );
    `);

    await client.query(`
      CREATE TABLE IF NOT EXISTS devices (
        device_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        employee_id         UUID REFERENCES employees(employee_id) ON DELETE SET NULL,
        device_name         VARCHAR(255) NOT NULL,
        device_type         VARCHAR(50) NOT NULL
                              CHECK (device_type IN ('laptop','desktop','workstation','other')),
        serial_number       VARCHAR(255) UNIQUE,
        os                  VARCHAR(100),
        ssm_activation_id   VARCHAR(255),
        ssm_instance_id     VARCHAR(255),
        ssm_status          VARCHAR(20) DEFAULT 'pending_enrollment'
                              CHECK (ssm_status IN ('pending_enrollment','online','offline','deregistered')),
        enrolled_at         TIMESTAMP,
        created_at          TIMESTAMP DEFAULT NOW(),
        updated_at          TIMESTAMP DEFAULT NOW()
      );
    `);

    // Seed a default admin account if none exists
    const { rows } = await client.query(
      `SELECT 1 FROM employees WHERE is_admin = TRUE LIMIT 1`
    );
    if (rows.length === 0) {
      const bcrypt = require('bcryptjs');
      const hash = await bcrypt.hash('admin123', 10);
      await client.query(`
        INSERT INTO employees (name, email, department, role, status, is_admin, password_hash)
        VALUES ('Admin User', 'admin@innovatech.local', 'IT Operations', 'it_ops', 'active', TRUE, $1)
      `, [hash]);
      console.log('[DB] Default admin seeded — email: admin@innovatech.local / pw: admin123');
    }

    console.log('[DB] Tables ready');
  } finally {
    client.release();
  }
}

module.exports = { pool, initDB };
