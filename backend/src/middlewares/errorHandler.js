const logger = require('../utils/logger');

// Postgres error codes that are really a malformed client request, not a
// server fault — surface them as 4xx instead of a generic 500.
const PG_CLIENT_ERRORS = {
  '22P02': [404, 'Not found'],           // invalid_text_representation (e.g. non-UUID :id)
  '22003': [400, 'Value out of range'],  // numeric_value_out_of_range
  '22007': [400, 'Invalid date/time'],   // invalid_datetime_format
};

// Central error handler — must be registered last in Express
function errorHandler(err, req, res, next) {
  let status = err.status || err.statusCode || 500;
  let message = err.message || 'Internal Server Error';

  if (status === 500 && err.code && PG_CLIENT_ERRORS[err.code]) {
    [status, message] = PG_CLIENT_ERRORS[err.code];
  }

  logger.error({ err, method: req.method, url: req.url, status }, 'Request error');

  res.status(status).json({
    status: 'error',
    code: status,
    message: status < 500 ? message : 'Internal Server Error',
  });
}

module.exports = errorHandler;
