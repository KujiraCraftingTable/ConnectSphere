const logger = require('../utils/logger');

// Central error handler — must be registered last in Express
function errorHandler(err, req, res, next) {
  const status = err.status || err.statusCode || 500;
  const message = err.message || 'Internal Server Error';

  logger.error({ err, method: req.method, url: req.url, status }, 'Request error');

  res.status(status).json({
    status: 'error',
    code: status,
    message: status < 500 ? message : 'Internal Server Error',
  });
}

module.exports = errorHandler;
