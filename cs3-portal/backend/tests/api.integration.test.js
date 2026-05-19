// Integration tests — spin up the Express app and hit real endpoints
// Uses an in-memory mock for the DB pool so no real database needed in CI
const request = require('supertest');

// ── Mock the DB module before requiring app ───────────────────────────────────
// This lets tests run in CI without a real PostgreSQL instance
const mockEmployees = [
  {
    employee_id: 'emp-001',
    name: 'Alice Smith',
    email: 'alice@innovatech.local',
    department: 'Engineering',
    role: 'developer',
    status: 'active',
    is_admin: false,
    password_hash: null, // set below
    created_at: new Date(),
    updated_at: new Date(),
  },
];

const mockRequests = [];

// Seed bcrypt hash for alice's password 'pass123'
beforeAll(async () => {
  const bcrypt = require('bcryptjs');
  mockEmployees[0].password_hash = await bcrypt.hash('pass123', 10);

  // Add default admin
  mockEmployees.push({
    employee_id: 'admin-001',
    name: 'Admin User',
    email: 'admin@innovatech.local',
    department: 'IT Operations',
    role: 'it_ops',
    status: 'active',
    is_admin: true,
    password_hash: await bcrypt.hash('admin123', 10),
    created_at: new Date(),
    updated_at: new Date(),
  });
});

jest.mock('../db', () => ({
  initDB: jest.fn().mockResolvedValue(undefined),
  pool: {
    query: jest.fn(async (sql, params) => {
      const s = sql.replace(/\s+/g, ' ').trim();

      // SELECT employee by email (login)
      if (s.includes('WHERE email = $1')) {
        const emp = mockEmployees.find(e => e.email === params[0]);
        return { rows: emp ? [emp] : [] };
      }
      // SELECT employee by id
      if (s.includes('WHERE employee_id = $1') && s.startsWith('SELECT')) {
        const emp = mockEmployees.find(e => e.employee_id === params[0]);
        return { rows: emp ? [emp] : [] };
      }
      // SELECT all employees
      if (s.startsWith('SELECT') && s.includes('FROM employees') && !params) {
        return { rows: mockEmployees };
      }
      // SELECT admin check
      if (s.includes('WHERE is_admin = TRUE')) {
        return { rows: [{ '1': 1 }] };
      }
      // INSERT employee
      if (s.startsWith('INSERT INTO employees')) {
        const newEmp = {
          employee_id: `emp-${Date.now()}`,
          name: params[0], email: params[1],
          department: params[2], role: params[3],
          status: 'active', created_at: new Date(),
        };
        mockEmployees.push(newEmp);
        return { rows: [newEmp] };
      }
      // onboard / offboard
      if (s.includes("SET status = 'active'") || s.includes("SET status = 'offboarded'")) {
        const emp = mockEmployees.find(e => e.employee_id === params[0]);
        if (!emp) return { rows: [] };
        emp.status = s.includes("'active'") ? 'active' : 'offboarded';
        return { rows: [{ employee_id: emp.employee_id, name: emp.name, email: emp.email, status: emp.status }] };
      }
      // INSERT request
      if (s.startsWith('INSERT INTO requests')) {
        const req = { request_id: `req-${Date.now()}`, employee_id: params[0], type: params[1], description: params[2], status: 'open', created_at: new Date() };
        mockRequests.push(req);
        return { rows: [req] };
      }
      // SELECT requests mine
      if (s.includes('FROM requests WHERE employee_id')) {
        return { rows: mockRequests.filter(r => r.employee_id === params[0]) };
      }
      return { rows: [], rowCount: 0 };
    }),
  },
}));

process.env.JWT_SECRET = 'test_secret';
process.env.PORT = '3001';

const app = require('../app');

// ── Helper ────────────────────────────────────────────────────────────────────
async function loginAs(email, password) {
  const res = await request(app).post('/v1/auth/login').send({ email, password });
  return res.body.token;
}

// ── Tests ─────────────────────────────────────────────────────────────────────
describe('GET /v1/health', () => {
  test('returns OK', async () => {
    const res = await request(app).get('/v1/health');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('OK');
  });
});

describe('POST /v1/auth/login', () => {
  test('valid employee credentials return token', async () => {
    const res = await request(app)
      .post('/v1/auth/login')
      .send({ email: 'alice@innovatech.local', password: 'pass123' });
    expect(res.status).toBe(200);
    expect(res.body.token).toBeDefined();
    expect(res.body.employee.email).toBe('alice@innovatech.local');
  });

  test('wrong password returns 401', async () => {
    const res = await request(app)
      .post('/v1/auth/login')
      .send({ email: 'alice@innovatech.local', password: 'wrongpass' });
    expect(res.status).toBe(401);
  });

  test('missing fields returns 400', async () => {
    const res = await request(app).post('/v1/auth/login').send({ email: 'alice@innovatech.local' });
    expect(res.status).toBe(400);
  });
});

describe('GET /v1/employees', () => {
  test('admin can list all employees', async () => {
    const token = await loginAs('admin@innovatech.local', 'admin123');
    const res = await request(app)
      .get('/v1/employees')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body)).toBe(true);
  });

  test('non-admin gets 403', async () => {
    const token = await loginAs('alice@innovatech.local', 'pass123');
    const res = await request(app)
      .get('/v1/employees')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(403);
  });

  test('unauthenticated gets 401', async () => {
    const res = await request(app).get('/v1/employees');
    expect(res.status).toBe(401);
  });
});

describe('GET /v1/employees/me', () => {
  test('returns own profile', async () => {
    const token = await loginAs('alice@innovatech.local', 'pass123');
    const res = await request(app)
      .get('/v1/employees/me')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.email).toBe('alice@innovatech.local');
  });
});

describe('POST /v1/employees (onboarding)', () => {
  test('admin can create a new employee', async () => {
    const token = await loginAs('admin@innovatech.local', 'admin123');
    const res = await request(app)
      .post('/v1/employees')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'Bob Jones', email: 'bob@innovatech.local', department: 'Sales', role: 'sales_rep', password: 'pass456' });
    expect(res.status).toBe(201);
    expect(res.body.email).toBe('bob@innovatech.local');
  });

  test('missing fields returns 400', async () => {
    const token = await loginAs('admin@innovatech.local', 'admin123');
    const res = await request(app)
      .post('/v1/employees')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'Incomplete' });
    expect(res.status).toBe(400);
  });
});

describe('POST /v1/requests', () => {
  test('employee can submit a request', async () => {
    const token = await loginAs('alice@innovatech.local', 'pass123');
    const res = await request(app)
      .post('/v1/requests')
      .set('Authorization', `Bearer ${token}`)
      .send({ type: 'password_reset', description: 'Forgot my password' });
    expect(res.status).toBe(201);
    expect(res.body.type).toBe('password_reset');
  });

  test('missing type returns 400', async () => {
    const token = await loginAs('alice@innovatech.local', 'pass123');
    const res = await request(app)
      .post('/v1/requests')
      .set('Authorization', `Bearer ${token}`)
      .send({ description: 'no type provided' });
    expect(res.status).toBe(400);
  });
});
