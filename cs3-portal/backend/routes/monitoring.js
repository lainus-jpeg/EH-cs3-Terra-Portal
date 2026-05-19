const router = require('express').Router();
const { requireAdmin } = require('../middleware');

// GET /v1/monitoring/grafana/url
// Returns the Grafana URL if configured — admin only
// When Grafana is deployed via Terraform, set GRAFANA_URL in backend .env
router.get('/grafana/url', requireAdmin, (req, res) => {
  const url = process.env.GRAFANA_URL;
  if (!url) {
    return res.status(404).json({ error: 'Grafana not configured yet' });
  }
  res.json({ url });
});

// GET /v1/monitoring/prometheus/url
// Returns the Prometheus URL if configured — admin only
router.get('/prometheus/url', requireAdmin, (req, res) => {
  const url = process.env.PROMETHEUS_URL;
  if (!url) {
    return res.status(404).json({ error: 'Prometheus not configured yet' });
  }
  res.json({ url });
});

module.exports = router;
