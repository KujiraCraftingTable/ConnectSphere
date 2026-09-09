const router = require('express').Router();
const { query } = require('../config/db');

/**
 * GET /api/wards/provinces
 * Returns list of all provinces (for first-level dropdown).
 */
router.get('/provinces', async (req, res, next) => {
  try {
    const { rows } = await query(
      `SELECT DISTINCT province_code, province_name, province_name_en
       FROM vn_wards
       ORDER BY province_name`
    );
    res.json({ data: rows });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/wards?province_code=79
 * Returns all wards in a province (for second-level dropdown).
 */
router.get('/', async (req, res, next) => {
  try {
    const { province_code } = req.query;
    if (!province_code) {
      return res.status(400).json({ status: 'error', message: 'province_code is required' });
    }
    const { rows } = await query(
      `SELECT id, code, name, name_en, full_name, full_name_en, unit_type, lat, lng
       FROM vn_wards
       WHERE province_code = $1
       ORDER BY name`,
      [province_code]
    );
    res.json({ data: rows });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
