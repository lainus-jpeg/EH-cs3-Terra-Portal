// Unit tests — test pure logic without hitting the database
const bcrypt = require('bcryptjs');
const jwt    = require('jsonwebtoken');

const JWT_SECRET = 'test_secret';

describe('Auth — password hashing', () => {
  test('bcrypt hash is not equal to plaintext', async () => {
    const hash = await bcrypt.hash('mypassword', 10);
    expect(hash).not.toBe('mypassword');
  });

  test('bcrypt compare returns true for correct password', async () => {
    const hash = await bcrypt.hash('mypassword', 10);
    const result = await bcrypt.compare('mypassword', hash);
    expect(result).toBe(true);
  });

  test('bcrypt compare returns false for wrong password', async () => {
    const hash = await bcrypt.hash('mypassword', 10);
    const result = await bcrypt.compare('wrongpassword', hash);
    expect(result).toBe(false);
  });
});

describe('Auth — JWT tokens', () => {
  test('signed token contains expected fields', () => {
    const payload = { employee_id: 'abc-123', email: 'test@test.com', is_admin: false };
    const token = jwt.sign(payload, JWT_SECRET, { expiresIn: '1h' });
    const decoded = jwt.verify(token, JWT_SECRET);
    expect(decoded.employee_id).toBe('abc-123');
    expect(decoded.email).toBe('test@test.com');
    expect(decoded.is_admin).toBe(false);
  });

  test('verify throws on tampered token', () => {
    const token = jwt.sign({ employee_id: '1' }, JWT_SECRET);
    expect(() => jwt.verify(token + 'tampered', JWT_SECRET)).toThrow();
  });

  test('verify throws on expired token', async () => {
    const token = jwt.sign({ employee_id: '1' }, JWT_SECRET, { expiresIn: '1ms' });
    await new Promise(r => setTimeout(r, 10)); // wait for expiry
    expect(() => jwt.verify(token, JWT_SECRET)).toThrow();
  });
});
